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
---@field known_view_wins table<integer, boolean>  -- see `reap_stray_windows`
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

--- Build a `difit.View` factory that also records every window the resulting view ever
--- opens into `known_view_wins` -- not only at the next `session:refresh()`/
--- `toggle_viewed()`/`set_mode()` notification, because `session:open_file()` (how the
--- panel's own navigation, and the very first file, get opened) never notifies
--- subscribers at all. Without recording here, a mode switch away from a view whose
--- windows were opened purely through `open_file()` would leave `reap_stray_windows`
--- with no way to recognize them as difit's own once they're orphaned. Per-entry (rather
--- than module-level) because two concurrent reviews' views must never be confused with
--- each other's windows.
---@param known_view_wins table<integer, boolean>
---@return fun(mode: "sidebyside"|"unified"): difit.View
local function make_view_factory(known_view_wins)
  return function(mode)
    local view = mode == "unified" and unified.new() or sidebyside.new()

    local real_open = view.open
    view.open = function(self, file_entry, spec)
      real_open(self, file_entry, spec)
      -- NB: deliberately not `ipairs({ self.win, self.left_win, self.right_win })` --
      -- the side-by-side view never sets `self.win` (it uses `left_win`/`right_win`
      -- instead), so that table literal's first element is nil, and `ipairs` stops
      -- before ever visiting the later, non-nil elements.
      if self.win then
        known_view_wins[self.win] = true
      end
      if self.left_win then
        known_view_wins[self.left_win] = true
      end
      if self.right_win then
        known_view_wins[self.right_win] = true
      end
    end

    return view
  end
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

--- Seam for the views' `_on_toggle_viewed` slot: resolves the CURRENT tabpage's entry at
--- call time (never at wiring time), so this one wired-once seam keeps working correctly
--- regardless of how many reviews are open simultaneously.
---@param path string
local function toggle_viewed_and_advance_seam(path)
  local entry = current_entry()
  if entry then
    toggle_viewed_and_advance(entry, path)
  end
end

-- Wire the views' `_on_toggle_viewed` seams once, at require-time: both fields are plain
-- module-level function slots (see sidebyside.lua/unified.lua), and the closure above
-- only ever reads the current tabpage's entry at call time, so there is nothing to
-- re-wire per `:Difit` call.
sidebyside._on_toggle_viewed = toggle_viewed_and_advance_seam
unified._on_toggle_viewed = toggle_viewed_and_advance_seam

-- Same pattern for the `toggle_mode`/`focus_panel`/`close` seams (config.keymaps.diff and
-- .file): both views delegate to the same `M.*` entry points a user's own <Plug> mapping
-- or `:Difit` subcommand would call -- which themselves resolve the current tabpage's
-- entry -- so there is exactly one implementation of "what toggling mode/focusing the
-- panel/closing the review means" regardless of which buffer the key was pressed in.
local function on_toggle_mode_seam()
  M.toggle_mode()
end
local function on_focus_panel_seam()
  M.focus()
end
local function on_close_seam()
  M.close()
end

sidebyside._on_toggle_mode = on_toggle_mode_seam
unified._on_toggle_mode = on_toggle_mode_seam
sidebyside._on_focus_panel = on_focus_panel_seam
unified._on_focus_panel = on_focus_panel_seam
sidebyside._on_close = on_close_seam
unified._on_close = on_close_seam

--- `session:set_mode()` always builds a brand-new `difit.View` via the factory (see
--- session.lua), and neither view module closes its *windows* on `close()` -- only its
--- owned buffers (by design: the same view instance normally reuses its windows across
--- repeated `open()` calls). Across a mode switch there is no "same instance" to reuse,
--- so the outgoing view's windows would otherwise pile up showing blank scratch buffers
--- forever. `left_win`/`right_win` (sidebyside) and `win` (unified) aren't part of the
--- documented `difit.View` contract, but sidebyside.lua itself documents them as
--- "exposed for tests" -- reading them here, purely to know which windows are still in
--- use, is the same kind of reach-through, not a modification of either view module.
---@param sess difit.Session?
---@return table<integer, boolean>
local function live_view_windows(sess)
  local view = sess and sess._view
  local wins = {}
  if not view then
    return wins
  end
  if view.win then
    wins[view.win] = true
  end
  if view.left_win then
    wins[view.left_win] = true
  end
  if view.right_win then
    wins[view.right_win] = true
  end
  return wins
end

--- Subscribed to `entry.session` (see `open_new`): closes windows in `tab` that used to
--- belong to a difit view but no longer do -- e.g. a `difit://unified/...` or blob window
--- orphaned by a mode switch, or a sidebyside pane still showing a real worktree file
--- after the view moved on (see `entry.known_view_wins`). A no-op whenever the live view
--- hasn't opened anything yet (an empty `keep` means "nothing to protect", not "close
--- everything") -- notably the placeholder window `open_new` leaves showing before the
--- first file opens.
---
--- Never closes a window that isn't (or never was) part of some difit view: this plugin
--- has no business closing a window the *user* opened in its own tabpage (`:vsplit`,
--- `:help`, ...) just because it happens not to be the panel or the current live view --
--- doing so used to nuke arbitrary user splits on every single refresh/toggle
--- notification. A window is only ever reaped when it is either recognized via
--- `entry.known_view_wins`, or -- as a belt-and-suspenders fallback -- still shows a
--- `difit://`-named buffer.
---@param tab integer
local function reap_stray_windows(tab)
  local entry = entries[tab]
  if not entry then
    return
  end
  if not vim.api.nvim_tabpage_is_valid(tab) then
    return
  end

  local keep = live_view_windows(entry.session)
  if not next(keep) then
    return
  end
  for win in pairs(keep) do
    entry.known_view_wins[win] = true
  end
  if entry.panel then
    keep[entry.panel.win] = true
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if
      not keep[win]
      and vim.api.nvim_win_is_valid(win)
      and #vim.api.nvim_tabpage_list_wins(tab) > 1
    then
      local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      if entry.known_view_wins[win] or vim.startswith(bufname, "difit://") then
        pcall(vim.api.nvim_win_close, win, true)
        entry.known_view_wins[win] = nil
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
--- (via the seams above), the `TabClosed` reconciler, and the `WinClosed` panel-gone
--- detector all end up here. Removing `tab` from the registry FIRST makes every step
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

  -- Only try to close/navigate away from a tabpage that is still actually there: when
  -- this runs from the `TabClosed` reconciler the tabpage is already gone, and there is
  -- nothing left to close or to move focus away from -- just the session/panel state
  -- cleanup above.
  if vim.api.nvim_tabpage_is_valid(tab) then
    close_tabpage_safe(tab)
    if entry.origin_tab and vim.api.nvim_tabpage_is_valid(entry.origin_tab) then
      vim.api.nvim_set_current_tabpage(entry.origin_tab)
    end
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

--- Build the dedicated review tabpage: a fresh tab (so the origin layout is untouched),
--- the panel split off to the left, and -- if there is an un-viewed file -- its diff
--- opened on the right. `sidebyside`/`unified` both split relative to "the current
--- window" (see their own module docs), so the diff area must be current when
--- `session:open_file` runs; `panel.open` steals focus for its own split, hence the
--- explicit refocus below before opening a file, and the final refocus back onto the
--- panel afterwards.
---
--- The session is built BEFORE any tabpage exists: `session.new()` never depends on which
--- tabpage is current (repo identity comes from `vim.fn.getcwd()`), so this lets a
--- same-review-key match (below) or a resolution failure both bail out without ever
--- flashing a throwaway tabpage into existence.
---@param base string?
local function open_new(base)
  local origin_tab = vim.api.nvim_get_current_tabpage()

  hl.setup()

  local known_view_wins = {}
  local sess, err = session.new({ base = base, view_factory = make_view_factory(known_view_wins) })
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
  -- stays a bare placeholder (a review with no entries at all) or gets claimed as the
  -- view's own window by `ensure_windows` (window-scoped variables survive a buffer swap
  -- in the same window), so marking it here covers both cases. Views will set this on
  -- every window they own themselves starting in R2.
  vim.w[diff_win].difit = true

  local pnl = panel.open(sess)

  ---@type difit.init.Entry
  local entry = {
    session = sess,
    panel = pnl,
    origin_tab = origin_tab,
    known_view_wins = known_view_wins,
    refresh_timer = nil,
  }
  entries[viewer_tab] = entry
  sess:subscribe(function()
    reap_stray_windows(viewer_tab)
  end)

  if vim.api.nvim_win_is_valid(diff_win) then
    vim.api.nvim_set_current_win(diff_win)
  end

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
