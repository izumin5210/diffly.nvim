-- Integration layer (WP-I): wires the pure `session`/`state`/`git` core and the two view
-- modules into the single `:Difit` user command experience described in docs/design.md.
-- Nothing here re-implements domain logic already owned by another module -- this file's
-- entire job is lifecycle (tabpage/window layout, autocmds, command dispatch) around the
-- documented `difit.Session`/`difit.View`/`difit.Panel` interfaces.
--
-- R1 (docs/refactor-v1.md): a module-local registry replaces what used to be a single
-- `M._session`/`M._panel`/`M._viewer_tab` triple, so more than one review can be open at
-- once (different repos/branches/PRs each get their own dedicated tabpage). Every public
-- entry point resolves "the" session by asking `current_entry()` which tabpage it was
-- called from, instead of reading a singleton.
--
-- R2/R3 (docs/refactor-v1.md): views no longer read "the current window" or reach for
-- module-level `_on_*` seam slots. Each session gets one `difit.ui.ViewCtx` table (see
-- `ui/keymaps.lua`), built here and passed BY REFERENCE into every view the session's
-- `view_factory` closure ever constructs (including across `set_mode`). `ctx.anchor`/
-- `ctx.claim` are filled in once the viewer tabpage/panel exist (session.new() runs
-- before either does -- see `open_new`); `ctx.actions` is `build_actions(tab)`, whose
-- closures resolve the live registry entry by tabpage handle on every call, so a stale
-- action surviving past `close_entry` degrades to a no-op notify instead of an error.

local config = require("difit.config")
local session = require("difit.session")
local state = require("difit.state")
local panel = require("difit.ui.panel")
local hl = require("difit.ui.hl")
local sidebyside = require("difit.ui.sidebyside")
local unified = require("difit.ui.unified")

local M = {}

---@class difit.init.Entry
---@field session difit.Session
---@field panel difit.Panel
---@field origin_tab integer  -- tabpage handle the user was on before this review opened
---@field refresh_timer uv.uv_timer_t?             -- BufWritePost/FocusGained debounce

--- The session registry itself: one entry per open review, keyed by the dedicated
--- viewer tabpage's handle. Underscore-prefixed, in the same spirit as
--- `difit.state._dir`: a plain field on the returned module table (Lua has no real
--- privacy), kept internal by convention but reachable for tests/introspection rather
--- than hidden behind a closure.
---@type table<integer, difit.init.Entry>
M._entries = {}
local entries = M._entries

local REFRESH_DEBOUNCE_MS = 200
local GLOBAL_AUGROUP = "difit_global"

---@return difit.init.Entry?
local function current_entry()
  return entries[vim.api.nvim_get_current_tabpage()]
end

--- Review keys are only ever compared field-by-field, never with plain `==` (a fresh
--- table from a fresh `session.new()` call is never `==` to one built earlier even when
--- every field matches).
---@param a difit.ReviewKey
---@param b difit.ReviewKey
---@return boolean
local function same_review_key(a, b)
  if a.kind ~= b.kind or a.repo ~= b.repo then
    return false
  end
  if a.kind == "pr" then
    return a.pr_number == b.pr_number
  end
  return a.base == b.base and a.head == b.head
end

--- Find a live entry already reviewing `key` -- "live" meaning its tabpage hasn't been
--- torn down out from under the registry yet (see `reconcile_registry`; in the steady
--- state this is always true, `TabClosed` reconciles synchronously).
---@param key difit.ReviewKey
---@return integer? tab
local function find_entry_by_review_key(key)
  for tab, entry in pairs(entries) do
    if
      vim.api.nvim_tabpage_is_valid(tab) and same_review_key(entry.session.spec.review_key, key)
    then
      return tab
    end
  end
  return nil
end

--- Mark `path` viewed/unviewed on `entry`'s session and, per `config.auto_advance`, open
--- the next un-viewed file -- the same policy `lua/difit/ui/panel.lua`'s own
--- `toggle_viewed` keymap applies, reimplemented here because it is invoked from two
--- different places (the diff-buffer seams below, and `M.toggle_viewed_current` for real
--- file buffers) that have no access to panel.lua's private row/cursor bookkeeping. The
--- panel itself re-renders on its own: `session:toggle_viewed` notifies subscribers, and
--- `panel.open` already subscribed a re-render callback, so this function only owns the
--- auto-advance decision.
---@param entry difit.init.Entry
---@param path string
local function toggle_viewed_and_advance(entry, path)
  local became_viewed = entry.session:toggle_viewed(path)
  -- Auto-advance only on MARKING a file viewed, never on un-marking it (design.md:
  -- "Marking advances to the next un-viewed file") -- mirrors the same rule in
  -- `lua/difit/ui/panel.lua`'s own `toggle_viewed` keymap.
  if became_viewed and config.get().auto_advance then
    local nxt = entry.session:next_unviewed(path)
    if nxt then
      entry.session:open_file(nxt)
      -- `session:open_file` only moves the *view*; unlike the panel's own toggle_viewed
      -- keymap (which manages its own cursor directly), this call originates from a
      -- diff/file buffer, so the panel's cursor would otherwise keep sitting on whatever
      -- row it was on before the advance. `Panel:set_cursor` only moves the cursor,
      -- never focus, so it can't steal focus away from wherever the user actually is.
      if entry.panel then
        entry.panel:set_cursor(nxt)
      end
    end
  end
end

---@param tab integer
local function close_tabpage_safe(tab)
  if not vim.api.nvim_tabpage_is_valid(tab) then
    return
  end
  -- `:tabclose` refuses to close the last tab page outright; open a throwaway empty tab
  -- first so the close always succeeds instead of erroring (or, worse, quitting Neovim).
  if #vim.api.nvim_list_tabpages() <= 1 then
    vim.cmd("tabnew")
  end
  vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tab))
end

---@param entry difit.init.Entry
local function stop_entry_timer(entry)
  if not entry.refresh_timer then
    return
  end
  pcall(function()
    entry.refresh_timer:stop()
  end)
  pcall(function()
    entry.refresh_timer:close()
  end)
  entry.refresh_timer = nil
end

--- Debounce concurrent `BufWritePost`/`FocusGained` refresh triggers into a single
--- `session:refresh()` call ~200ms after the last one. Timer callbacks run in a fast
--- event context where most of the API is off-limits, hence the `vim.schedule`.
--- `entry` is captured directly (not re-looked-up via the registry): `close_entry` stops
--- and closes this exact timer object before ever removing `entry` from the registry, so
--- a stale closure can never fire `entry.session:refresh()` after the review closed --
--- the same guarantee the old singleton implementation had.
---@param entry difit.init.Entry
local function debounced_refresh(entry)
  stop_entry_timer(entry)
  entry.refresh_timer = assert(vim.uv.new_timer())
  entry.refresh_timer:start(REFRESH_DEBOUNCE_MS, 0, function()
    stop_entry_timer(entry)
    vim.schedule(function()
      entry.session:refresh()
    end)
  end)
end

---@param tab integer
---@return string
local function entry_augroup_name(tab)
  return string.format("difit_entry_%d", tab)
end

--- Per-entry augroup for the BufWritePost/FocusGained refresh triggers (docs/
--- refactor-v1.md R1: these move off the old single global augroup so each concurrent
--- review gets its own, torn down independently in `close_entry`).
---@param tab integer
---@param entry difit.init.Entry
local function setup_entry_autocmds(tab, entry)
  local group = vim.api.nvim_create_augroup(entry_augroup_name(tab), { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    desc = "difit: refresh on writes inside the reviewed repo",
    callback = function(ev)
      local toplevel = entry.session.spec.repo.toplevel
      local full = vim.fn.fnamemodify(ev.file, ":p")
      if full == toplevel or vim.startswith(full, toplevel .. "/") then
        debounced_refresh(entry)
      end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    desc = "difit: refresh on regaining focus",
    callback = function()
      debounced_refresh(entry)
    end,
  })
end

---@param tab integer
local function clear_entry_autocmds(tab)
  pcall(vim.api.nvim_del_augroup_by_name, entry_augroup_name(tab))
end

--- The single idempotent teardown every close path funnels through: `:Difit close`/`q`
--- (via the `close` action -- see `build_actions`), the `TabClosed` reconciler, and the
--- `WinClosed` panel-gone detector all end up here. Removing `tab` from the registry FIRST
--- makes every step
--- below safe to run twice (e.g. `WinClosed` firing as a side effect of the
--- `close_tabpage_safe` call further down): a second call finds nothing to do.
---@param tab integer
local function close_entry(tab)
  local entry = entries[tab]
  if not entry then
    return
  end
  entries[tab] = nil

  stop_entry_timer(entry)
  clear_entry_autocmds(tab)

  entry.session:close()
  if entry.panel then
    entry.panel:close()
  end

  -- `session:close()`/`panel:close()` may already have closed every window `tab` had
  -- (docs/refactor-v1.md R2: a view's own `close()` destroys its owned windows now, not
  -- just its buffers) -- closing a tabpage's last window makes Neovim remove the tabpage
  -- itself as a side effect, so `tab` can legitimately already be gone by the time we get
  -- here, same as when this runs from the `TabClosed` reconciler. Only ask to close it
  -- explicitly when it's still actually there.
  if vim.api.nvim_tabpage_is_valid(tab) then
    close_tabpage_safe(tab)
  end

  -- Restore focus to wherever the user was before this review opened UNCONDITIONALLY on
  -- `tab` itself still existing: whether `tab` needed an explicit `close_tabpage_safe`
  -- above or had already vanished on its own, Neovim's own choice of which tab to land on
  -- next (typically whatever is adjacent) is not necessarily `entry.origin_tab` once more
  -- than one other tabpage exists (docs/refactor-v1.md R1: concurrent reviews).
  if entry.origin_tab and vim.api.nvim_tabpage_is_valid(entry.origin_tab) then
    vim.api.nvim_set_current_tabpage(entry.origin_tab)
  end
end

---@param tab integer
---@return boolean
local function tabpage_alive(tab)
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    if t == tab then
      return true
    end
  end
  return false
end

--- `TabClosed` handler: drop every registry entry whose tabpage is no longer among
--- `nvim_list_tabpages()` -- covers a manual `:tabclose`/`:tabonly`/etc. on the viewer
--- tabpage that never went through `M.close()` at all. `close_entry` itself detects the
--- tabpage is already gone and skips the close-tabpage/restore-origin steps, so this is
--- purely session/panel state cleanup, never a second attempt to close what already
--- closed itself.
local function reconcile_registry()
  for tab in pairs(entries) do
    if not tabpage_alive(tab) then
      close_entry(tab)
    end
  end
end

--- `WinClosed` handler body, deferred via `vim.schedule` from the autocmd callback below.
--- Tears `tab`'s review down once its panel window -- the sole navigational anchor of the
--- whole viewer -- is gone: a review with diff panes but no tree is not meaningfully
--- usable, and closing the panel is this plugin's closest equivalent to the user saying
--- "I'm done reviewing" without having gone through `:Difit close`/the diff buffers' own
--- `close` keymap (`lua/difit/ui/panel.lua`'s own `q` mapping closes the session/panel
--- directly but never the tabpage -- this is what actually finishes that job).
---@param tab integer
local function maybe_teardown_on_win_closed(tab)
  local entry = entries[tab]
  if not entry then
    return
  end
  if not vim.api.nvim_tabpage_is_valid(tab) then
    -- The whole tabpage is gone too (e.g. the panel was its last window) --
    -- `reconcile_registry` (fired by the accompanying `TabClosed`) owns this case.
    return
  end
  local panel_alive = entry.panel and entry.panel.win and vim.api.nvim_win_is_valid(entry.panel.win)
  if not panel_alive then
    close_entry(tab)
  end
end

local global_autocmds_ready = false

--- Registered once behind this guard (docs/refactor-v1.md R1), regardless of how many
--- reviews get opened/closed over the plugin's lifetime -- unlike the per-entry
--- augroups, these two watch every tabpage, not just one review's.
local function setup_global_autocmds()
  if global_autocmds_ready then
    return
  end
  global_autocmds_ready = true

  local group = vim.api.nvim_create_augroup(GLOBAL_AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    desc = "difit: reconcile the session registry when a viewer tabpage closes",
    callback = reconcile_registry,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    desc = "difit: tear a review down once its panel window is gone",
    callback = function(ev)
      local win = tonumber(ev.match)
      if not win then
        return
      end
      -- Resolve the tabpage NOW, synchronously, while `win` is still a valid handle
      -- (Neovim fires `WinClosed` just before actually removing the window, so
      -- `nvim_win_get_tabpage` still works here even for a tab's last window) -- the
      -- decision itself is deferred so the closed window has fully finished going away
      -- by the time `maybe_teardown_on_win_closed` inspects what's left of the tabpage.
      local ok, tab = pcall(vim.api.nvim_win_get_tabpage, win)
      if not ok or not entries[tab] then
        return
      end
      vim.schedule(function()
        maybe_teardown_on_win_closed(tab)
      end)
    end,
  })
end

--- Resolve tab's live registry entry, or notify (once, per call) that it's gone. Every
--- `difit.ui.Actions` closure (see `build_actions`) goes through this instead of holding a
--- `difit.Session`/`difit.init.Entry` reference directly -- the entry a buffer-local
--- keymap was wired against can always outlive the review itself (a real file buffer, or a
--- `difit://` scratch buffer some other window still shows), and a stale action firing
--- after `close_entry` must degrade to a harmless no-op, never an error (docs/
--- refactor-v1.md R3).
---@param tab integer
---@param what string  -- action name, folded into the notify message
---@return difit.init.Entry?
local function resolve_live_entry(tab, what)
  local entry = entries[tab]
  if not entry then
    vim.notify(string.format("difit: review already closed; %s ignored", what), vim.log.levels.WARN)
  end
  return entry
end

--- Build the `difit.ui.Actions` table (see `ui/keymaps.lua`) for the review at `tab`:
--- the single implementation of "what toggling viewed/mode, focusing the panel, or
--- closing the review means" that both views' buffer-local keymaps call into, regardless
--- of which buffer/window the key was pressed in. Captures `tab`, a plain tabpage handle,
--- rather than `sess`/`entry` themselves (codediff pattern) -- so every call re-resolves
--- the CURRENT live entry for that tabpage rather than risking acting on a torn-down
--- session.
---@param tab integer
---@return difit.ui.Actions
local function build_actions(tab)
  return {
    toggle_viewed = function(path)
      local entry = resolve_live_entry(tab, "toggle_viewed")
      if entry then
        toggle_viewed_and_advance(entry, path)
      end
    end,
    toggle_mode = function()
      local entry = resolve_live_entry(tab, "toggle_mode")
      if entry then
        local next_mode = entry.session.mode == "sidebyside" and "unified" or "sidebyside"
        entry.session:set_mode(next_mode)
      end
    end,
    focus_panel = function()
      local entry = resolve_live_entry(tab, "focus_panel")
      if entry and entry.panel then
        entry.panel:focus()
      end
    end,
    close = function()
      local entry = resolve_live_entry(tab, "close")
      if entry then
        close_entry(tab)
      end
    end,
  }
end

--- Build the dedicated review tabpage: a fresh tab (so the origin layout is untouched),
--- the panel split off to the left, and -- if there is an un-viewed file -- its diff
--- opened on the right.
---
--- The session is built BEFORE any tabpage exists: `session.new()` never depends on which
--- tabpage is current (repo identity comes from `vim.fn.getcwd()`), so this lets a
--- same-review-key match (below) or a resolution failure both bail out without ever
--- flashing a throwaway tabpage into existence. That means the view factory closure below
--- must close over a `ctx` table (docs/refactor-v1.md R2) BEFORE its `anchor`/`claim`/
--- `actions` fields are actually known: `session.new()` calls it once immediately (just to
--- construct the initial, window-less `difit.View` instance), well before the tabpage,
--- panel, or diff placeholder window exist. Because `ctx` is a plain table passed BY
--- REFERENCE into every view the factory ever builds, filling its fields in further down
--- -- once the tabpage/panel genuinely exist -- is enough: no view actually reads
--- `ctx.anchor`/`ctx.claim`/`ctx.actions` until its own `ensure_windows`/`ensure_window`
--- first runs, which never happens before `sess:open_file()` below.
---@param base string?
local function open_new(base)
  local origin_tab = vim.api.nvim_get_current_tabpage()

  hl.setup()

  ---@type difit.ui.ViewCtx
  local ctx = { anchor = nil, claim = nil, actions = nil }
  local function view_factory(mode)
    return mode == "unified" and unified.new(ctx) or sidebyside.new(ctx)
  end

  local sess, err = session.new({ base = base, view_factory = view_factory })
  if not sess then
    vim.notify("difit: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  -- Multiple concurrent reviews are allowed (different repos/branches/PRs), but the same
  -- review must never get a second tabpage (docs/refactor-v1.md R1): focus the existing
  -- one instead of duplicating it.
  local existing_tab = find_entry_by_review_key(sess.spec.review_key)
  if existing_tab then
    vim.api.nvim_set_current_tabpage(existing_tab)
    return
  end

  vim.cmd("tab split")
  local viewer_tab = vim.api.nvim_get_current_tabpage()
  local diff_win = vim.api.nvim_get_current_win()
  -- R1 sentinel groundwork for the `WinClosed` teardown funnel above: this window either
  -- stays a bare placeholder (a review with no entries at all) or gets claimed as
  -- `ctx.claim` by whichever view opens the first file below (R2's `ensure_windows`/
  -- `ensure_window` set this sentinel again themselves once that happens; harmless to
  -- set it twice).
  vim.w[diff_win].difit = true

  local pnl = panel.open(sess)

  -- Now that the tabpage/panel exist, the view factory closure's `ctx` can be filled in:
  -- `ctx.anchor` is the panel window every view splits rightward from; `ctx.claim` is the
  -- placeholder window above, offered ONCE to whichever view opens the very first file.
  ctx.anchor = pnl.win
  ctx.claim = diff_win
  ctx.actions = build_actions(viewer_tab)

  ---@type difit.init.Entry
  local entry = {
    session = sess,
    panel = pnl,
    origin_tab = origin_tab,
    refresh_timer = nil,
  }
  entries[viewer_tab] = entry

  local first_unviewed = sess:next_unviewed(nil)
  if first_unviewed then
    sess:open_file(first_unviewed)
  end

  pnl:focus()
  setup_entry_autocmds(viewer_tab, entry)
  setup_global_autocmds()
end

--- `setup()` is optional (see config.lua); calling it only overrides the defaults.
---@param opts table?
function M.setup(opts)
  config.setup(opts)
end

--- Close the review open on the CURRENT tabpage, if any. A no-op from any tabpage that
--- isn't itself a registered viewer (including a second `:Difit close` from the origin
--- tabpage right after the first one already returned there).
function M.close()
  close_entry(vim.api.nvim_get_current_tabpage())
end

function M.toggle()
  if current_entry() then
    M.close()
  else
    open_new(nil)
  end
end

function M.refresh()
  local entry = current_entry()
  if entry then
    entry.session:refresh()
  end
end

--- Focus the panel window: the backing function for `:Difit focus`,
--- `<Plug>(difit-focus-panel)`, and both views' `focus_panel` seam (problem 1 in the bug
--- report this shipped with -- pressing <CR> in the panel had no discoverable way back to
--- it). `Panel:focus()` itself calls `nvim_set_current_win`, which also switches to the
--- panel's tabpage when called from a different one, so there is nothing tabpage-specific
--- to do here beyond resolving which review the current tabpage belongs to.
function M.focus()
  local entry = current_entry()
  if not entry then
    vim.notify("difit: no review is open", vim.log.levels.WARN)
    return
  end
  if entry.panel then
    entry.panel:focus()
  end
end

--- Flip between side-by-side and unified: the backing function for both views'
--- `toggle_mode` seam (`keymaps.diff`/`keymaps.file`), mirroring
--- `lua/difit/ui/panel.lua`'s own `s` keymap.
function M.toggle_mode()
  local entry = current_entry()
  if not entry then
    return
  end
  local next_mode = entry.session.mode == "sidebyside" and "unified" or "sidebyside"
  entry.session:set_mode(next_mode)
end

--- Remove persisted viewed-state: `all=true` wipes every review's file, otherwise just
--- the current review's (the current tabpage's open session's key, or -- when the
--- current tabpage isn't a viewer -- a throwaway session built only to resolve that key;
--- see the comment below).
---@param all boolean?
function M.clean(all)
  if all then
    if vim.fn.confirm("difit: remove ALL viewed-state files?", "&Yes\n&No", 2) ~= 1 then
      return
    end
    local removed = state.clean({ all = true })
    vim.notify(string.format("difit: removed %d state file(s)", removed), vim.log.levels.INFO)
    return
  end

  local key
  local entry = current_entry()
  if entry then
    key = entry.session.spec.review_key
  else
    -- No open session on this tabpage to read a key off of: resolve one the same way
    -- `session.new` would, via a throwaway session (never `:close()`d, so nothing gets
    -- saved/rendered). This reuses the single source of truth for base/PR/review-key
    -- resolution instead of duplicating it here.
    local noop_view = { open = function() end, close = function() end }
    local sess, err = session.new({
      view_factory = function()
        return noop_view
      end,
    })
    if not sess then
      vim.notify("difit: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    key = sess.spec.review_key
  end

  if vim.fn.confirm("difit: remove viewed state for the current review?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  local removed = state.clean({ key = key })
  vim.notify(string.format("difit: removed %d state file(s)", removed), vim.log.levels.INFO)
end

--- Entry point for `:Difit [subcommand|base]`. `args[1]` is either one of the recognized
--- subcommands or a base-branch override. A bare `:Difit` (or one with an unrecognized
--- first argument):
--- - from a tabpage that already IS a registered viewer, refreshes that review in place
---   rather than nesting a second viewer inside the first;
--- - otherwise, focuses a live review with the same review key if one exists anywhere,
---   or opens a new one (see `open_new`).
---@param args string[]?
function M.open(args)
  args = args or {}
  local first = args[1]

  if first == "close" then
    return M.close()
  elseif first == "toggle" then
    return M.toggle()
  elseif first == "refresh" then
    return M.refresh()
  elseif first == "clean" then
    return M.clean(args[2] == "all")
  elseif first == "focus" then
    return M.focus()
  end

  local entry = current_entry()
  if entry then
    entry.session:refresh()
    return
  end

  open_new(first)
end

--- Backing function for `<Plug>(difit-toggle-viewed)` (see plugin/difit.lua): toggles the
--- viewed mark for the current buffer's file when that buffer is a real worktree/HEAD file
--- belonging to the current tabpage's session. difit-owned buffers (`difit://...`) already
--- get their own `config.keymaps.diff.toggle_viewed` mapping straight from the view
--- modules, so this is specifically for real file buffers (e.g. the side-by-side right
--- window, or a file opened via the unified view's jump-to-file).
function M.toggle_viewed_current()
  local entry = current_entry()
  if not entry then
    return
  end
  local toplevel = entry.session.spec.repo.toplevel
  local prefix = toplevel .. "/"
  local bufname = vim.api.nvim_buf_get_name(0)
  if not vim.startswith(bufname, prefix) then
    return
  end
  toggle_viewed_and_advance(entry, bufname:sub(#prefix + 1))
end

return M
