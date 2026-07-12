-- Integration layer (WP-I): wires the pure `session`/`state`/`git` core and the two view
-- modules into the single `:Diffly` user command experience described in docs/design.md.
-- Nothing here re-implements domain logic already owned by another module -- this file's
-- entire job is lifecycle (tabpage/window layout, autocmds, command dispatch) around the
-- documented `diffly.Session`/`diffly.View`/`diffly.Panel` interfaces.
--
-- Session registry (docs/architecture.md "Session lifecycle"): a module-local registry replaces what used to be a single
-- `M._session`/`M._panel`/`M._viewer_tab` triple, so more than one review can be open at
-- once (different repos/branches/PRs each get their own dedicated tabpage). Every public
-- entry point resolves "the" session by asking `current_entry()` which tabpage it was
-- called from, instead of reading a singleton.
--
-- View contract (docs/architecture.md "View contract"): views no longer read "the current window" or reach for
-- module-level `_on_*` seam slots. Each session gets one `diffly.ui.ViewCtx` table (see
-- `ui/keymaps.lua`), built here and passed BY REFERENCE into every view the session's
-- `view_factory` closure ever constructs (including across `set_mode`). `ctx.anchor`/
-- `ctx.claim` are filled in once the viewer tabpage/panel exist (session.new() runs
-- before either does -- see `open_new`); `ctx.actions` is `build_actions(tab)`, whose
-- closures resolve the live registry entry by tabpage handle on every call, so a stale
-- action surviving past `close_entry` degrades to a no-op notify instead of an error.

local comments = require("diffly.comments")
local config = require("diffly.config")
local github = require("diffly.github")
local session = require("diffly.session")
local state = require("diffly.state")
local panel = require("diffly.ui.panel")
local hl = require("diffly.ui.hl")
local sidebyside = require("diffly.ui.sidebyside")
local ui_comments = require("diffly.ui.comments")
local unified = require("diffly.ui.unified")

local M = {}

---@class diffly.init.Entry
---@field session diffly.Session
---@field panel diffly.Panel
---@field origin_tab integer  -- tabpage handle the user was on before this review opened
---@field refresh_timer uv.uv_timer_t?             -- BufWritePost/FocusGained debounce
---@field remote_fetch diffly.FetchHandle?         -- in-flight review-thread fetch, if any;
--- cancelled in `close_entry` right after the timer, same teardown discipline

--- The session registry itself: one entry per open review, keyed by the dedicated
--- viewer tabpage's handle. Underscore-prefixed, in the same spirit as
--- `diffly.state._dir`: a plain field on the returned module table (Lua has no real
--- privacy), kept internal by convention but reachable for tests/introspection rather
--- than hidden behind a closure.
---@type table<integer, diffly.init.Entry>
M._entries = {}
local entries = M._entries

local REFRESH_DEBOUNCE_MS = 200
local GLOBAL_AUGROUP = "diffly_global"

---@return diffly.init.Entry?
local function current_entry()
  return entries[vim.api.nvim_get_current_tabpage()]
end

--- Review keys are only ever compared field-by-field, never with plain `==` (a fresh
--- table from a fresh `session.new()` call is never `==` to one built earlier even when
--- every field matches).
---@param a diffly.ReviewKey
---@param b diffly.ReviewKey
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
---@param key diffly.ReviewKey
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
--- the next un-viewed file -- the same policy `lua/diffly/ui/panel.lua`'s own
--- `toggle_viewed` keymap applies, reimplemented here because it is invoked from two
--- different places (the diff-buffer seams below, and `M.toggle_viewed_current` for real
--- file buffers) that have no access to panel.lua's private row/cursor bookkeeping. The
--- panel itself re-renders on its own: `session:toggle_viewed` notifies subscribers, and
--- `panel.open` already subscribed a re-render callback, so this function only owns the
--- auto-advance decision.
---@param entry diffly.init.Entry
---@param path string
local function toggle_viewed_and_advance(entry, path)
  local became_viewed = entry.session:toggle_viewed(path)
  -- Auto-advance only on MARKING a file viewed, never on un-marking it (design.md:
  -- "Marking advances to the next un-viewed file") -- mirrors the same rule in
  -- `lua/diffly/ui/panel.lua`'s own `toggle_viewed` keymap.
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

--- Open `target` (if any) through `entry`'s session and sync the panel's cursor to it --
--- the shared tail `build_actions`' `next_file`/`prev_file` and the top-level
--- `M.next_file`/`M.prev_file` (the `<Plug>(diffly-next-file)`/`<Plug>(diffly-prev-file)`
--- backing functions) both need once `session:next_file`/`prev_file` has resolved a
--- target: `session:open_file` moves the view, and `Panel:set_cursor` keeps the panel in
--- sync without stealing focus, mirroring `toggle_viewed_and_advance`'s own auto-advance
--- tail below. A no-op when `target` is nil (no files in the review at all).
---@param entry diffly.init.Entry
---@param target string?
local function open_and_sync_cursor(entry, target)
  if not target then
    return
  end
  entry.session:open_file(target)
  if entry.panel then
    entry.panel:set_cursor(target)
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

---@param entry diffly.init.Entry
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
---@param entry diffly.init.Entry
local function debounced_refresh(entry)
  stop_entry_timer(entry)
  entry.refresh_timer = assert(vim.uv.new_timer())
  entry.refresh_timer:start(REFRESH_DEBOUNCE_MS, 0, function()
    stop_entry_timer(entry)
    vim.schedule(function()
      -- Local diff only, DELIBERATELY: this debounced path fires on every save and
      -- focus change, and must never turn into network traffic. Remote-thread refetches
      -- belong exclusively to explicit user actions (`manual_refresh` below).
      entry.session:refresh()
    end)
  end)
end

-- One-time notice when the overlay can't even start (e.g. a repo identity with no
-- parsable remote): the review still works fully locally, so a single INFO per Neovim
-- session -- same rationale as session.lua's gh-missing notice.
local overlay_degraded_notified = false

--- Kick off (or restart) the async review-thread fetch for `tab`'s review -- the
--- codebase's one async subprocess (github.fetch_threads). Captures the tabpage int,
--- never the entry/session: the completion re-resolves `entries[tab]` and degrades to a
--- silent no-op when the review closed mid-flight, mirroring the render getters. A
--- silent no-op too for branch-keyed sessions (no PR is the normal case).
---@param tab integer
local function start_remote_fetch(tab)
  local entry = entries[tab]
  if not entry then
    return
  end
  local sess = entry.session
  if not sess.pr then
    return
  end

  -- Manual-refresh spam: the last request wins, anything still in flight is cancelled.
  if entry.remote_fetch then
    entry.remote_fetch.cancel()
    entry.remote_fetch = nil
  end

  local handle, err = github.fetch_threads(sess.spec.repo, sess.pr, function(by_path, fetch_err)
    local live = entries[tab]
    if not live then
      return
    end
    live.remote_fetch = nil
    if not by_path then
      vim.notify(
        "diffly: failed to fetch PR review threads: " .. (fetch_err or "unknown error"),
        vim.log.levels.WARN
      )
      return
    end
    live.session:set_remote_threads(by_path)
  end)

  if not handle then
    if not overlay_degraded_notified then
      overlay_degraded_notified = true
      vim.notify(
        "diffly: PR review-thread overlay unavailable: " .. (err or "unknown error"),
        vim.log.levels.INFO
      )
    end
    return
  end
  entry.remote_fetch = handle
end

--- An EXPLICIT user refresh (`:Diffly refresh`, a bare `:Diffly` on the viewer tab, the
--- panel's `R`): recompute the local diff AND refetch the remote overlay. The debounced
--- auto-refresh above never comes here.
---@param tab integer
local function manual_refresh(tab)
  local entry = entries[tab]
  if not entry then
    return
  end
  entry.session:refresh()
  start_remote_fetch(tab)
end

---@param tab integer
---@return string
local function entry_augroup_name(tab)
  return string.format("diffly_entry_%d", tab)
end

--- Per-entry augroup for the BufWritePost/FocusGained refresh triggers (docs/architecture.md "Session lifecycle": these move off the old single global augroup so each concurrent
--- review gets its own, torn down independently in `close_entry`).
---@param tab integer
---@param entry diffly.init.Entry
local function setup_entry_autocmds(tab, entry)
  local group = vim.api.nvim_create_augroup(entry_augroup_name(tab), { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    desc = "diffly: refresh on writes inside the reviewed repo",
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
    desc = "diffly: refresh on regaining focus",
    callback = function()
      debounced_refresh(entry)
    end,
  })
end

---@param tab integer
local function clear_entry_autocmds(tab)
  pcall(vim.api.nvim_del_augroup_by_name, entry_augroup_name(tab))
end

--- The single idempotent teardown every close path funnels through: `:Diffly close`/`q`
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
  -- An in-flight thread fetch dies with the review; its completion re-resolves the
  -- registry anyway (already emptied above), so this is belt and suspenders.
  if entry.remote_fetch then
    entry.remote_fetch.cancel()
    entry.remote_fetch = nil
  end
  clear_entry_autocmds(tab)

  entry.session:close()
  if entry.panel then
    entry.panel:close()
  end

  -- `session:close()`/`panel:close()` may already have closed every window `tab` had
  -- (docs/architecture.md "View contract": a view's own `close()` destroys its owned windows now, not
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
  -- than one other tabpage exists (docs/architecture.md "Session lifecycle": concurrent reviews).
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
--- "I'm done reviewing" without having gone through `:Diffly close`/the diff buffers' own
--- `close` keymap (`lua/diffly/ui/panel.lua`'s own `q` mapping closes the session/panel
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

--- Registered once behind this guard (docs/architecture.md "Session lifecycle"), regardless of how many
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
    desc = "diffly: reconcile the session registry when a viewer tabpage closes",
    callback = reconcile_registry,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    desc = "diffly: tear a review down once its panel window is gone",
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
--- `diffly.ui.Actions` closure (see `build_actions`) goes through this instead of holding a
--- `diffly.Session`/`diffly.init.Entry` reference directly -- the entry a buffer-local
--- keymap was wired against can always outlive the review itself (a real file buffer, or a
--- `diffly://` scratch buffer some other window still shows), and a stale action firing
--- after `close_entry` must degrade to a harmless no-op, never an error (docs/architecture.md "View contract").
---@param tab integer
---@param what string  -- action name, folded into the notify message
---@return diffly.init.Entry?
local function resolve_live_entry(tab, what)
  local entry = entries[tab]
  if not entry then
    vim.notify(
      string.format("diffly: review already closed; %s ignored", what),
      vim.log.levels.WARN
    )
  end
  return entry
end

---@param path string
---@param start_line integer
---@param end_line integer
---@return string @difit-style location: "path:L42" / "path:L42-L48"
local function comment_location(path, start_line, end_line)
  local location = string.format("%s:L%d", path, start_line)
  if end_line ~= start_line then
    location = location .. string.format("-L%d", end_line)
  end
  return location
end

--- Resolve which thread a cursor action targets: 0 -> notify; 1 -> act immediately;
--- 2+ -> `vim.ui.select` (so telescope/fzf-lua/etc. pickers apply), following
--- `run_sweep_selector`'s `{value..., display}` item shape.
---@param threads diffly.CommentThread[]
---@param what string  -- verb for the prompt
---@param on_pick fun(thread: diffly.CommentThread)
local function pick_thread(threads, what, on_pick)
  if #threads == 0 then
    vim.notify("diffly: no comment on this line", vim.log.levels.INFO)
    return
  end
  if #threads == 1 then
    on_pick(threads[1])
    return
  end

  local choices = {}
  for _, thread in ipairs(threads) do
    local first = vim.split(thread.messages[1].body, "\n", { plain = true })[1]
    table.insert(choices, {
      thread = thread,
      display = string.format("L%d: %s", thread.anchor.start_line, first),
    })
  end
  vim.ui.select(choices, {
    prompt = "diffly: which comment to " .. what .. "?",
    format_item = function(choice)
      return choice.display
    end,
  }, function(choice)
    if choice then
      on_pick(choice.thread)
    end
  end)
end

--- Unnamed register unconditionally (works everywhere, including headless); system
--- clipboard best-effort only -- a clipboard provider may legitimately be absent.
---@param text string
local function copy_to_registers(text)
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
end

--- Build the `diffly.ui.Actions` table (see `ui/keymaps.lua`) for the review at `tab`:
--- the single implementation of "what toggling viewed/mode, focusing the panel, or
--- closing the review means" that both views' buffer-local keymaps call into, regardless
--- of which buffer/window the key was pressed in. Captures `tab`, a plain tabpage handle,
--- rather than `sess`/`entry` themselves (codediff pattern) -- so every call re-resolves
--- the CURRENT live entry for that tabpage rather than risking acting on a torn-down
--- session.
---@param tab integer
---@return diffly.ui.Actions
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
    -- `path` is the reference point (the file the buffer this key was pressed in is
    -- currently showing, i.e. `session.current_path` in practice -- see
    -- `ui/keymaps.lua`'s `universal_spec`); `session:next_file`/`prev_file` already treat
    -- a stale/missing reference as "from the start/end", so no extra fallback is needed
    -- here the way the panel's own `]f`/`[f` handlers need one (ui/panel.lua).
    next_file = function(path)
      local entry = resolve_live_entry(tab, "next_file")
      if entry then
        open_and_sync_cursor(entry, entry.session:next_file(path))
      end
    end,
    prev_file = function(path)
      local entry = resolve_live_entry(tab, "prev_file")
      if entry then
        open_and_sync_cursor(entry, entry.session:prev_file(path))
      end
    end,
    comment_add = function(path, side, start_line, end_line)
      local entry = resolve_live_entry(tab, "comment_add")
      if not entry then
        return
      end
      -- Snapshot captured NOW, from the buffer the key was pressed in: what the user is
      -- looking at is exactly what the comment anchors to -- even mid-edit, before `:w`
      -- (the next refresh re-anchors against disk, see session.lua).
      local snapshot = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
      ui_comments.compose({
        title = comment_location(path, start_line, end_line),
        on_submit = function(lines)
          -- Re-resolve at submit time: the float can outlive the review.
          local live = resolve_live_entry(tab, "comment_add")
          if not live then
            return
          end
          local _, err = live.session:add_comment(path, {
            side = side,
            start_line = start_line,
            end_line = end_line,
            body = table.concat(lines, "\n"),
            snapshot = snapshot,
          })
          if err then
            vim.notify(err, vim.log.levels.WARN)
          end
        end,
      })
    end,
    comment_edit = function(path, side, line)
      local entry = resolve_live_entry(tab, "comment_edit")
      if not entry then
        return
      end
      local found = comments.find_at(entry.session.state, path, side, line)
      pick_thread(found, "edit", function(thread)
        ui_comments.compose({
          title = comment_location(path, thread.anchor.start_line, thread.anchor.end_line),
          initial = vim.split(thread.messages[1].body, "\n", { plain = true }),
          on_submit = function(lines)
            local live = resolve_live_entry(tab, "comment_edit")
            if live then
              live.session:update_comment(path, thread.id, table.concat(lines, "\n"))
            end
          end,
        })
      end)
    end,
    comment_delete = function(path, side, line)
      local entry = resolve_live_entry(tab, "comment_delete")
      if not entry then
        return
      end
      local found = comments.find_at(entry.session.state, path, side, line)
      pick_thread(found, "delete", function(thread)
        -- A written comment is real user work: confirm before destroying it. Goes
        -- through `vim.ui.select` (not `vim.fn.confirm`) so picker replacements apply
        -- and the flow stays drivable in tests, same as every other menu here.
        vim.ui.select({
          { confirm = true, display = "Delete" },
          { confirm = false, display = "Keep" },
        }, {
          prompt = "diffly: delete this comment?",
          format_item = function(choice)
            return choice.display
          end,
        }, function(choice)
          if not choice or not choice.confirm then
            return
          end
          local live = resolve_live_entry(tab, "comment_delete")
          if live then
            live.session:delete_comment(path, thread.id)
          end
        end)
      end)
    end,
    comment_toggle = function()
      local entry = resolve_live_entry(tab, "comment_toggle")
      if entry then
        entry.session:toggle_comments_collapsed()
      end
    end,
    comment_toggle_resolved = function()
      local entry = resolve_live_entry(tab, "comment_toggle_resolved")
      if entry then
        entry.session:toggle_remote_resolved()
      end
    end,
    comment_copy = function(path, side, line)
      local entry = resolve_live_entry(tab, "comment_copy")
      if not entry then
        return
      end
      local found = comments.find_at(entry.session.state, path, side, line)
      pick_thread(found, "copy", function(thread)
        copy_to_registers(comments.format_prompt(thread))
        vim.notify("diffly: copied 1 comment as prompt", vim.log.levels.INFO)
      end)
    end,
    comment_copy_all = function()
      local entry = resolve_live_entry(tab, "comment_copy_all")
      if not entry then
        return
      end
      local threads = entry.session:all_comments()
      if #threads == 0 then
        vim.notify("diffly: no comments to copy", vim.log.levels.INFO)
        return
      end
      copy_to_registers(comments.format_prompt_all(threads))
      vim.notify(
        string.format("diffly: copied %d comment(s) as prompt", #threads),
        vim.log.levels.INFO
      )
    end,
    -- Render-time reads (the views' comment repaint), not user actions: a stale call
    -- degrades to empty data SILENTLY -- `resolve_live_entry`'s notify is for ignored
    -- keypresses, and a repaint racing teardown is not something to warn about.
    -- `threads_for_render`, not `comments_for`: the render feed carries local drafts
    -- PLUS the displayable remote overlay; cursor actions above keep operating on the
    -- local store only.
    comments_for = function(path)
      local entry = entries[tab]
      if not entry then
        return {}
      end
      return entry.session:threads_for_render(path)
    end,
    comments_collapsed = function()
      local entry = entries[tab]
      if not entry then
        return false
      end
      return entry.session.comments_collapsed
    end,
  }
end

--- Every group's own matched-file/un-viewed count, deduplicated across ALL groups by path
--- (a file matched by more than one group must not be double-counted) -- backs the "all
--- groups" choice in `run_sweep_selector`'s menu, mirroring the exact union
--- `Session:sweep_patterns(nil)` itself performs when actually sweeping it (see its own
--- docs), so the menu's count can never promise something the sweep it triggers doesn't
--- deliver.
---@param session diffly.Session
---@param groups diffly.PatternGroupInfo[]
---@return integer matched, integer unviewed
local function union_counts(session, groups)
  local seen, matched, unviewed = {}, 0, 0
  for _, group in ipairs(groups) do
    for _, path in ipairs(group.matched) do
      if not seen[path] then
        seen[path] = true
        matched = matched + 1
        if not session:is_viewed(path) then
          unviewed = unviewed + 1
        end
      end
    end
  end
  return matched, unviewed
end

--- `"<name> (<N> files, <M> unviewed)"` -- deliberately never pluralizes "file(s)" down to
--- "file" for N==1, matching this plugin's existing sweep-result wording elsewhere (e.g.
--- `ui/panel.lua`'s own batch notice says "unmarked 1 files"): one predictable format
--- regardless of count, rather than two subtly different ones.
---@param name string
---@param matched integer
---@param unviewed integer
---@return string
local function format_group_choice(name, matched, unviewed)
  return string.format("%s (%d files, %d unviewed)", name, matched, unviewed)
end

---@class diffly.init.SweepChoice
---@field group_name string?  -- nil = the "all groups" union
---@field display string

--- `vim.ui.select` items for `run_sweep_selector`'s menu: "all groups" (the union, see
--- `union_counts`) always first, then each configured group in `pattern_groups()` order.
--- Items are small tables rather than pre-formatted strings, with `display` handed to
--- `vim.ui.select`'s `format_item` (see `run_sweep_selector`) -- so a picker UI (telescope/
--- fzf-lua/etc., any of which may replace the builtin `vim.ui.select`) gets the real
--- `group_name` as the selected value and only uses `display` for rendering, instead of
--- having to parse a group's name back out of a formatted string.
---@param session diffly.Session
---@param groups diffly.PatternGroupInfo[]
---@return diffly.init.SweepChoice[]
local function sweep_choices(session, groups)
  local all_matched, all_unviewed = union_counts(session, groups)
  local choices = {
    { group_name = nil, display = format_group_choice("all groups", all_matched, all_unviewed) },
  }
  for _, group in ipairs(groups) do
    table.insert(choices, {
      group_name = group.name,
      display = format_group_choice(group.name, #group.matched, group.unviewed),
    })
  end
  return choices
end

--- Sweep `group_name` (nil = every group's union -- see `Session:sweep_patterns`) and
--- report a compact result scoped to whichever group actually got swept. The shared tail
--- both `run_sweep_selector` (0/1/N-group picking) and `M.sweep`'s explicit-name path
--- funnel into once a group is settled on, so the notification wording and auto-advance
--- policy can never drift apart between the panel's `S` key and `:Diffly sweep [name]`.
---@param entry diffly.init.Entry
---@param group_name string?
local function perform_sweep(entry, group_name)
  local result, scope = entry.session:sweep_patterns(group_name)
  if not result then
    -- `scope` holds the "unknown group" error message in this branch -- see
    -- `Session:sweep_patterns`'s own doc for its dual-purpose second return. Unreachable
    -- from `run_sweep_selector` (every `group_name` it passes came from `pattern_groups()`
    -- itself); reachable from `M.sweep` only if the review's groups changed between
    -- `resolve_group_name` resolving the name and this call, e.g. a concurrent `refresh()`
    -- -- vanishingly rare, but still reported rather than silently dropped.
    vim.notify(scope, vim.log.levels.WARN)
    return
  end

  if result.matched == 0 then
    vim.notify(
      string.format("diffly: no files matched viewed_patterns (%s)", scope),
      vim.log.levels.INFO
    )
    return
  end

  if result.marked > 0 then
    vim.notify(
      string.format("diffly: marked %d files as viewed (%s)", result.marked, scope),
      vim.log.levels.INFO
    )
    -- Auto-advance only after a MARKING batch, mirroring `toggle_viewed_and_advance`'s own
    -- rule for a single file (design.md: "Marking advances to the next un-viewed file").
    -- `after_path = nil`: a sweep can touch files scattered across the tree, so there is no
    -- single "after" file to resume from -- start over from the beginning of file_order.
    if config.get().auto_advance then
      open_and_sync_cursor(entry, entry.session:next_unviewed(nil))
    end
  else
    vim.notify(
      string.format("diffly: unmarked %d files (%s)", result.unmarked, scope),
      vim.log.levels.INFO
    )
  end
end

--- The shared "which group to sweep" flow behind BOTH the panel's `S` key and a bare
--- `:Diffly sweep` (no explicit name) -- `perform_sweep` above is the actual sweep+notify
--- tail once a group is chosen. 0 groups -> nothing to sweep; exactly 1 -> sweep it
--- immediately, no menu (the whole point of a picker is choosing among options, and there
--- is exactly one); 2+ -> `vim.ui.select` (so telescope/fzf-lua/etc. pickers apply when a
--- user has replaced the builtin one), cancelling out of it is a silent no-op -- same "no
--- side effect" contract as cancelling any other `vim.ui.select` prompt in this plugin.
---@param entry diffly.init.Entry
local function run_sweep_selector(entry)
  local groups = entry.session:pattern_groups()

  if #groups == 0 then
    vim.notify("diffly: viewed_patterns is not configured", vim.log.levels.INFO)
    return
  end

  if #groups == 1 then
    perform_sweep(entry, groups[1].name)
    return
  end

  vim.ui.select(sweep_choices(entry.session, groups), {
    prompt = "Sweep pattern group:",
    format_item = function(choice)
      return choice.display
    end,
  }, function(choice)
    if choice then
      perform_sweep(entry, choice.group_name)
    end
  end)
end

--- Exact match first, then a UNIQUE prefix match (typical CLI-subcommand resolution) --
--- backs `:Diffly sweep {name}` so e.g. `:Diffly sweep lock` works when "lock files" is the
--- only configured group starting with "lock", without requiring the whole name (or its
--- backslash-escaped spaces, see `M.sweep_group_names`) to be typed out. Returns nil, not
--- an error, on anything else (no match, or an ambiguous prefix matching more than one
--- group) -- `M.sweep` turns that into a message listing what IS available.
---@param groups diffly.PatternGroupInfo[]
---@param requested string
---@return string|nil
local function resolve_group_name(groups, requested)
  for _, group in ipairs(groups) do
    if group.name == requested then
      return group.name
    end
  end

  local prefix_matches = {}
  for _, group in ipairs(groups) do
    if vim.startswith(group.name, requested) then
      table.insert(prefix_matches, group.name)
    end
  end
  if #prefix_matches == 1 then
    return prefix_matches[1]
  end
  return nil
end

--- Build the dedicated review tabpage: a fresh tab (so the origin layout is untouched),
--- the panel split off to the left, and -- if there is an un-viewed file -- its diff
--- opened on the right.
---
--- The session is built BEFORE any tabpage exists: `session.new()` never depends on which
--- tabpage is current (repo identity comes from `vim.fn.getcwd()`), so this lets a
--- same-review-key match (below) or a resolution failure both bail out without ever
--- flashing a throwaway tabpage into existence. That means the view factory closure below
--- must close over a `ctx` table (docs/architecture.md "View contract") BEFORE its `anchor`/`claim`/
--- `actions` fields are actually known: `session.new()` calls it once immediately (just to
--- construct the initial, window-less `diffly.View` instance), well before the tabpage,
--- panel, or diff placeholder window exist. Because `ctx` is a plain table passed BY
--- REFERENCE into every view the factory ever builds, filling its fields in further down
--- -- once the tabpage/panel genuinely exist -- is enough: no view actually reads
--- `ctx.anchor`/`ctx.claim`/`ctx.actions` until its own `ensure_windows`/`ensure_window`
--- first runs, which never happens before `sess:open_file()` below.
---@param base string?
local function open_new(base)
  local origin_tab = vim.api.nvim_get_current_tabpage()

  hl.setup()

  ---@type diffly.ui.ViewCtx
  local ctx = { anchor = nil, claim = nil, actions = nil }
  local function view_factory(mode)
    return mode == "unified" and unified.new(ctx) or sidebyside.new(ctx)
  end

  local sess, err = session.new({ base = base, view_factory = view_factory })
  if not sess then
    vim.notify("diffly: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  -- Multiple concurrent reviews are allowed (different repos/branches/PRs), but the same
  -- review must never get a second tabpage (docs/architecture.md "Session lifecycle"): focus the existing
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
  vim.w[diff_win].diffly = true

  -- Injected into the panel below so its own `S` key runs the EXACT SAME selector flow as
  -- `:Diffly sweep` (`run_sweep_selector`) without `ui/panel.lua` ever `require`ing this
  -- module -- mirrors `build_actions(tab)`'s closures just above/below, which the diff
  -- views' `ctx.actions` already reach init.lua-owned behavior through the same way: a
  -- closure captures `viewer_tab` (not `entry`/`sess` themselves) and re-resolves the LIVE
  -- registry entry at call time via `resolve_live_entry`, so it degrades to a no-op notify
  -- instead of erroring if it ever somehow fired after this review closed.
  local function sweep_action()
    local live = resolve_live_entry(viewer_tab, "sweep")
    if live then
      run_sweep_selector(live)
    end
  end

  -- Same injection shape as `sweep_action`: the panel's `R` must behave exactly like
  -- `:Diffly refresh` (an EXPLICIT refresh, overlay refetch included) without
  -- `ui/panel.lua` ever requiring this module.
  local function refresh_action()
    manual_refresh(viewer_tab)
  end

  local pnl = panel.open(sess, { sweep = sweep_action, refresh = refresh_action })

  -- Now that the tabpage/panel exist, the view factory closure's `ctx` can be filled in:
  -- `ctx.anchor` is the panel window every view splits rightward from; `ctx.claim` is the
  -- placeholder window above, offered ONCE to whichever view opens the very first file.
  ctx.anchor = pnl.win
  ctx.claim = diff_win
  ctx.actions = build_actions(viewer_tab)

  ---@type diffly.init.Entry
  local entry = {
    session = sess,
    panel = pnl,
    origin_tab = origin_tab,
    refresh_timer = nil,
    remote_fetch = nil,
  }
  entries[viewer_tab] = entry

  -- The overlay kickoff -- async, AFTER the registry entry exists so the completion can
  -- find it. Opening never waits on the network; the panel/views repaint when it lands.
  start_remote_fetch(viewer_tab)

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
--- isn't itself a registered viewer (including a second `:Diffly close` from the origin
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
    -- An explicit user action: local diff AND the remote-thread overlay.
    manual_refresh(vim.api.nvim_get_current_tabpage())
  end
end

--- Focus the panel window: the backing function for `:Diffly focus`,
--- `<Plug>(diffly-focus-panel)`, and both views' `focus_panel` seam (problem 1 in the bug
--- report this shipped with -- pressing <CR> in the panel had no discoverable way back to
--- it). `Panel:focus()` itself calls `nvim_set_current_win`, which also switches to the
--- panel's tabpage when called from a different one, so there is nothing tabpage-specific
--- to do here beyond resolving which review the current tabpage belongs to.
function M.focus()
  local entry = current_entry()
  if not entry then
    vim.notify("diffly: no review is open", vim.log.levels.WARN)
    return
  end
  if entry.panel then
    entry.panel:focus()
  end
end

--- Flip between side-by-side and unified: the backing function for both views'
--- `toggle_mode` seam (`keymaps.diff`/`keymaps.universal`), mirroring
--- `lua/diffly/ui/panel.lua`'s own `s` keymap.
function M.toggle_mode()
  local entry = current_entry()
  if not entry then
    return
  end
  local next_mode = entry.session.mode == "sidebyside" and "unified" or "sidebyside"
  entry.session:set_mode(next_mode)
end

--- Open the next file (ALL files, not just un-viewed ones -- see `Session:next_file`):
--- the backing function for `<Plug>(diffly-next-file)` and `keymaps.universal.next_file`
--- (via `build_actions`, for buffers that already have a `path` reference to hand it).
--- Reference point is `session.current_path` -- there is no buffer-local "which file is
--- this" to resolve here, unlike `M.toggle_viewed_current`, since a `<Plug>` mapping isn't
--- tied to any one diffly buffer.
function M.next_file()
  local entry = current_entry()
  if entry then
    open_and_sync_cursor(entry, entry.session:next_file(entry.session.current_path))
  end
end

--- Open the previous file, mirroring `M.next_file` in the opposite direction: the backing
--- function for `<Plug>(diffly-prev-file)` and `keymaps.universal.prev_file`.
function M.prev_file()
  local entry = current_entry()
  if entry then
    open_and_sync_cursor(entry, entry.session:prev_file(entry.session.current_path))
  end
end

--- Backing function for `:Diffly sweep [{name}]`: with no name, runs the same 0/1/N-group
--- selector the panel's `S` key uses (`run_sweep_selector`, wired to it via the injected
--- `sweep` action -- see `open_new`); with a name (`fargs` joined with spaces -- see
--- plugin/diffly.lua's completion, which offers group names with embedded spaces
--- backslash-escaped so `nargs="*"` still hands them here as separate fargs tokens,
--- rejoining with " " undoes exactly that split), resolves it against the live review's
--- groups (`resolve_group_name`) and sweeps just that one; an unresolved name reports the
--- groups that ARE available instead of silently doing nothing.
---@param fargs string[]?  -- args after "sweep" (see `M.open`)
function M.sweep(fargs)
  local entry = current_entry()
  if not entry then
    vim.notify("diffly: no review is open", vim.log.levels.WARN)
    return
  end

  local requested = fargs and #fargs > 0 and table.concat(fargs, " ") or nil
  if not requested then
    run_sweep_selector(entry)
    return
  end

  local groups = entry.session:pattern_groups()
  local resolved = resolve_group_name(groups, requested)
  if not resolved then
    local names = {}
    for _, group in ipairs(groups) do
      table.insert(names, group.name)
    end
    vim.notify(
      string.format(
        "diffly: unknown pattern group %q; available: %s",
        requested,
        #names > 0 and table.concat(names, ", ") or "(none configured)"
      ),
      vim.log.levels.WARN
    )
    return
  end

  perform_sweep(entry, resolved)
end

--- `:Diffly sweep <Tab>` completion candidates: the live review's pattern-group names (see
--- `Session:pattern_groups()`), with embedded spaces backslash-escaped so a multi-word
--- group name round-trips through `nargs="*"`'s space-based arg splitting as ONE token
--- (mirrors how e.g. `:edit`'s own filename completion escapes spaces -- see `:help
--- f-args` for the matching unescape-on-parse side that `M.sweep` above relies on). Empty
--- outside a viewer tabpage -- unlike `M.sweep()` itself, a completion function never
--- notifies; no candidates is the correct "nothing to offer" UX here (mirrors
--- plugin/diffly.lua's own `local_branches()` degrading to `{}` when `git branch` fails).
---@return string[]
function M.sweep_group_names()
  local entry = current_entry()
  if not entry then
    return {}
  end
  local names = {}
  for _, group in ipairs(entry.session:pattern_groups()) do
    table.insert(names, (group.name:gsub(" ", "\\ ")))
  end
  return names
end

--- Remove persisted viewed-state: `all=true` wipes every review's file, otherwise just
--- the current review's (the current tabpage's open session's key, or -- when the
--- current tabpage isn't a viewer -- a throwaway session built only to resolve that key;
--- see the comment below).
---@param all boolean?
function M.clean(all)
  if all then
    if vim.fn.confirm("diffly: remove ALL viewed-state files?", "&Yes\n&No", 2) ~= 1 then
      return
    end
    local removed = state.clean({ all = true })
    vim.notify(string.format("diffly: removed %d state file(s)", removed), vim.log.levels.INFO)
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
      vim.notify("diffly: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    key = sess.spec.review_key
  end

  if vim.fn.confirm("diffly: remove viewed state for the current review?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  local removed = state.clean({ key = key })
  vim.notify(string.format("diffly: removed %d state file(s)", removed), vim.log.levels.INFO)
end

--- Entry point for `:Diffly [subcommand|base]`. `args[1]` is either one of the recognized
--- subcommands or a base-branch override. A bare `:Diffly` (or one with an unrecognized
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
  elseif first == "sweep" then
    return M.sweep(vim.list_slice(args, 2))
  elseif first == "comments" then
    return M.comments()
  elseif first == "submit" then
    return M.submit()
  end

  local entry = current_entry()
  if entry then
    -- A bare `:Diffly` on an already-open viewer tab is an explicit refresh.
    manual_refresh(vim.api.nvim_get_current_tabpage())
    return
  end

  open_new(first)
end

--- `:Diffly comments`: every comment thread in the current review into the quickfix
--- list -- the review-wide overview and the discoverability channel for outdated threads
--- (which never render inline; see ui/comments.lua). One item per thread at its
--- last-known start line, first body line only, with `[outdated]`/`[base]` markers. A
--- base-side item's line number references BASE content while quickfix jumps into the
--- worktree file -- an accepted approximation, which is exactly what the `[base]` marker
--- flags. No dedicated comment-list UI: quickfix already does navigation, persistence
--- across the review, and :cdo-style batching for free.
function M.comments()
  local entry = current_entry()
  if not entry then
    vim.notify("diffly: no review is open on this tabpage", vim.log.levels.INFO)
    return
  end

  local locals = entry.session:all_comments()
  local remotes = entry.session:remote_thread_list()
  if #locals == 0 and #remotes == 0 then
    vim.notify("diffly: no comments in this review", vim.log.levels.INFO)
    return
  end

  -- Both layers merged into one (path, line) ordering; the seq tiebreak keeps the merge
  -- deterministic (table.sort is not stable) with local drafts before remote threads on
  -- the exact same line.
  local rows = {}
  for _, thread in ipairs(locals) do
    local first_line = vim.split(thread.messages[1].body, "\n", { plain = true })[1]
    table.insert(rows, {
      path = thread.path,
      lnum = thread.anchor.start_line,
      seq = #rows,
      text = (thread.anchor.outdated and "[outdated] " or "")
        .. (thread.anchor.side == "base" and "[base] " or "")
        .. first_line,
    })
  end
  for _, thread in ipairs(remotes) do
    local first_line = vim.split(thread.messages[1].body, "\n", { plain = true })[1]
    table.insert(rows, {
      path = thread.path,
      lnum = thread.anchor.start_line,
      seq = #rows,
      text = "[@"
        .. thread.messages[1].author
        .. "] "
        .. (thread.resolved and "[resolved] " or "")
        .. (thread.anchor.outdated and "[outdated] " or "")
        .. (thread.anchor.side == "base" and "[base] " or "")
        .. first_line,
    })
  end
  table.sort(rows, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.seq < b.seq
  end)

  local toplevel = entry.session.spec.repo.toplevel
  local items = {}
  for _, row in ipairs(rows) do
    table.insert(items, {
      filename = vim.fs.joinpath(toplevel, row.path),
      lnum = row.lnum,
      text = row.text,
    })
  end

  vim.fn.setqflist({}, " ", { title = "diffly comments", items = items })
  -- Full-width at the very bottom of the viewer tab; the panel's winfixwidth/height keep
  -- its geometry intact.
  vim.cmd("botright copen")
end

--- `:Diffly submit`: every mappable local draft into ONE review on the PR
--- (docs/design.md "Comments"). Flow: validate/map against the PR's real diff
--- (`Session:prepare_submission`) -> report what stays local -> pick the review event
--- (`vim.ui.select`, COMMENT first as the safe default -- APPROVE/REQUEST_CHANGES are
--- rejected by the forge on one's own PR) -> optional summary via the compose float
--- (`allow_empty`) -> POST. Only a SUCCESSFUL post mutates the local store (the endpoint
--- is atomic: on a 422 nothing landed and every draft is intact, with the forge's reason
--- notified verbatim); submitted drafts then reappear through the overlay refetch.
function M.submit()
  local entry = current_entry()
  if not entry then
    vim.notify("diffly: no review is open on this tabpage", vim.log.levels.INFO)
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()

  local plan, err = entry.session:prepare_submission()
  if not plan then
    vim.notify(err or "diffly: cannot submit", vim.log.levels.WARN)
    return
  end

  if #plan.skipped > 0 then
    local lines = { string.format("diffly: %d draft(s) stay local:", #plan.skipped) }
    for _, skip in ipairs(plan.skipped) do
      table.insert(
        lines,
        string.format(
          "  %s:L%d — %s",
          skip.thread.path,
          skip.thread.anchor.start_line,
          skip.reason
        )
      )
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
  end
  if #plan.items == 0 then
    vim.notify("diffly: nothing to submit", vim.log.levels.INFO)
    return
  end

  vim.ui.select({
    { event = "COMMENT", display = "Comment" },
    { event = "APPROVE", display = "Approve" },
    { event = "REQUEST_CHANGES", display = "Request changes" },
  }, {
    prompt = string.format("diffly: submit %d comment(s) as:", #plan.items),
    format_item = function(choice)
      return choice.display
    end,
  }, function(choice)
    if not choice then
      return -- cancelling any diffly menu is always consequence-free
    end

    ui_comments.compose({
      title = "review summary (optional)",
      allow_empty = true,
      on_submit = function(lines)
        -- Re-resolve at submit time: the float can outlive the review.
        local live = resolve_live_entry(tab, "submit")
        if not live or not live.session.pr then
          return
        end

        local payloads = {}
        for _, item in ipairs(plan.items) do
          table.insert(payloads, item.payload)
        end
        local body = vim.trim(table.concat(lines, "\n"))

        local ok, submit_err = github.submit_review(live.session.spec.repo, live.session.pr, {
          commit_id = live.session.pr.head_oid,
          event = choice.event,
          body = body ~= "" and body or nil,
          comments = payloads,
        })
        if not ok then
          vim.notify(
            "diffly: review submission failed: " .. (submit_err or "unknown error"),
            vim.log.levels.ERROR
          )
          return
        end

        live.session:remove_submitted(plan.items)
        start_remote_fetch(tab)
        vim.notify(
          string.format(
            "diffly: submitted %d comment(s)%s",
            #plan.items,
            #plan.skipped > 0 and string.format(" (%d kept locally)", #plan.skipped) or ""
          ),
          vim.log.levels.INFO
        )
      end,
    })
  end)
end

--- Backing function for `<Plug>(diffly-toggle-viewed)` (see plugin/diffly.lua): toggles the
--- viewed mark for the current buffer's file when that buffer is a real worktree/HEAD file
--- belonging to the current tabpage's session. diffly-owned buffers (`diffly://...`) already
--- get their own `config.keymaps.diff.toggle_viewed` mapping straight from the view
--- modules, so this is specifically for real file buffers (worktree mode's real buffer in
--- either the side-by-side right window or the unified window alike).
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
