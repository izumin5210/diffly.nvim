-- Integration layer (WP-I): wires the pure `session`/`state`/`git` core and the two view
-- modules into the single `:Difit` user command experience described in docs/design.md.
-- Nothing here re-implements domain logic already owned by another module -- this file's
-- entire job is lifecycle (tabpage/window layout, autocmds, command dispatch) around the
-- documented `difit.Session`/`difit.View`/`difit.Panel` interfaces.

local config = require("difit.config")
local session = require("difit.session")
local state = require("difit.state")
local panel = require("difit.ui.panel")
local hl = require("difit.ui.hl")
local sidebyside = require("difit.ui.sidebyside")
local unified = require("difit.ui.unified")

local M = {}

-- Module-level session state. Underscore-prefixed, in the same spirit as
-- `difit.state._dir` / `difit.ui.sidebyside._on_toggle_viewed`: these are plain fields on
-- the returned module table (Lua has no real privacy), kept internal by convention but
-- reachable for tests/introspection rather than hidden behind a closure.
---@type difit.Session?
M._session = nil
---@type difit.Panel?
M._panel = nil
---@type integer? -- tabpage handle the user was on before `:Difit` opened the viewer
M._origin_tab = nil
---@type integer? -- tabpage handle of the dedicated review tabpage
M._viewer_tab = nil
---@type uv.uv_timer_t?
M._refresh_timer = nil

local AUGROUP = "difit"
local REFRESH_DEBOUNCE_MS = 200

---@param mode "sidebyside"|"unified"
---@return difit.View
local function view_factory(mode)
  if mode == "unified" then
    return unified.new()
  end
  return sidebyside.new()
end

--- Mark `path` viewed/unviewed and, per `config.auto_advance`, open the next un-viewed
--- file -- the same policy `lua/difit/ui/panel.lua`'s own `toggle_viewed` keymap applies,
--- reimplemented here because it is invoked from two different places (the diff-buffer
--- seams below, and `M.toggle_viewed_current` for real file buffers) that have no access
--- to panel.lua's private row/cursor bookkeeping. The panel itself re-renders on its own:
--- `session:toggle_viewed` notifies subscribers, and `panel.open` already subscribed a
--- re-render callback, so this function only owns the auto-advance decision.
---@param path string
local function toggle_viewed_and_advance(path)
  if not M._session then
    return
  end
  M._session:toggle_viewed(path)
  if config.get().auto_advance then
    local nxt = M._session:next_unviewed(path)
    if nxt then
      M._session:open_file(nxt)
    end
  end
end

-- Wire the views' `_on_toggle_viewed` seams once, at require-time: both fields are plain
-- module-level function slots (see sidebyside.lua/unified.lua), and the closure below only
-- ever reads `M._session` at call time, so there is nothing to re-wire per `:Difit` call.
sidebyside._on_toggle_viewed = toggle_viewed_and_advance
unified._on_toggle_viewed = toggle_viewed_and_advance

--- `session:set_mode()` always builds a brand-new `difit.View` via the factory (see
--- session.lua), and neither view module closes its *windows* on `close()` -- only its
--- owned buffers (by design: the same view instance normally reuses its windows across
--- repeated `open()` calls). Across a mode switch there is no "same instance" to reuse,
--- so the outgoing view's windows would otherwise pile up showing blank scratch buffers
--- forever. `left_win`/`right_win` (sidebyside) and `win` (unified) aren't part of the
--- documented `difit.View` contract, but sidebyside.lua itself documents them as
--- "exposed for tests" -- reading them here, purely to know which windows are still in
--- use, is the same kind of reach-through, not a modification of either view module.
---@return table<integer, boolean>
local function live_view_windows()
  local view = M._session and M._session._view
  local wins = {}
  if not view then
    return wins
  end
  for _, w in ipairs({ view.win, view.left_win, view.right_win }) do
    if w then
      wins[w] = true
    end
  end
  return wins
end

--- Subscribed to the session (see `open_new`): closes any window in the viewer tabpage
--- that belongs to neither the panel nor the live view. A no-op whenever the live view
--- hasn't opened anything yet (an empty `wins` means "nothing to protect", not "close
--- everything") -- notably the placeholder window `open_new` leaves showing before the
--- first file opens.
local function reap_stray_windows()
  if not (M._session and M._panel and M._viewer_tab) then
    return
  end
  if not vim.api.nvim_tabpage_is_valid(M._viewer_tab) then
    return
  end

  local keep = live_view_windows()
  if not next(keep) then
    return
  end
  keep[M._panel.win] = true

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(M._viewer_tab)) do
    if
      not keep[win]
      and vim.api.nvim_win_is_valid(win)
      and #vim.api.nvim_tabpage_list_wins(M._viewer_tab) > 1
    then
      pcall(vim.api.nvim_win_close, win, true)
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

local function stop_refresh_timer()
  if not M._refresh_timer then
    return
  end
  pcall(function()
    M._refresh_timer:stop()
  end)
  pcall(function()
    M._refresh_timer:close()
  end)
  M._refresh_timer = nil
end

--- Debounce concurrent `BufWritePost`/`FocusGained` refresh triggers into a single
--- `session:refresh()` call ~200ms after the last one. Timer callbacks run in a fast
--- event context where most of the API is off-limits, hence the `vim.schedule`.
local function debounced_refresh()
  stop_refresh_timer()
  M._refresh_timer = assert(vim.uv.new_timer())
  M._refresh_timer:start(REFRESH_DEBOUNCE_MS, 0, function()
    stop_refresh_timer()
    vim.schedule(function()
      if M._session then
        M._session:refresh()
      end
    end)
  end)
end

---@param path string @absolute or `<afile>`-relative path from an autocmd event
---@return boolean
local function under_toplevel(path)
  if not M._session then
    return false
  end
  local toplevel = M._session.spec.repo.toplevel
  local full = vim.fn.fnamemodify(path, ":p")
  return full == toplevel or vim.startswith(full, toplevel .. "/")
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    desc = "difit: refresh on writes inside the reviewed repo",
    callback = function(ev)
      if under_toplevel(ev.file) then
        debounced_refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    desc = "difit: refresh on regaining focus",
    callback = function()
      debounced_refresh()
    end,
  })
end

local function clear_autocmds()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
end

local function focus_viewer_tab()
  if M._viewer_tab and vim.api.nvim_tabpage_is_valid(M._viewer_tab) then
    vim.api.nvim_set_current_tabpage(M._viewer_tab)
  end
end

--- Build the dedicated review tabpage: a fresh tab (so the origin layout is untouched),
--- the panel split off to the left, and -- if there is an un-viewed file -- its diff
--- opened on the right. `sidebyside`/`unified` both split relative to "the current
--- window" (see their own module docs), so the diff area must be current when
--- `session:open_file` runs; `panel.open` steals focus for its own split, hence the
--- explicit refocus below before opening a file, and the final refocus back onto the
--- panel afterwards.
---@param base string?
local function open_new(base)
  local origin_tab = vim.api.nvim_get_current_tabpage()

  vim.cmd("tab split")
  local viewer_tab = vim.api.nvim_get_current_tabpage()
  local diff_win = vim.api.nvim_get_current_win()

  hl.setup()

  local sess, err = session.new({ base = base, view_factory = view_factory })
  if not sess then
    vim.api.nvim_set_current_tabpage(origin_tab)
    close_tabpage_safe(viewer_tab)
    vim.notify("difit: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  M._session = sess
  M._origin_tab = origin_tab
  M._viewer_tab = viewer_tab
  M._panel = panel.open(sess)
  sess:subscribe(reap_stray_windows)

  if vim.api.nvim_win_is_valid(diff_win) then
    vim.api.nvim_set_current_win(diff_win)
  end

  local first_unviewed = sess:next_unviewed(nil)
  if first_unviewed then
    sess:open_file(first_unviewed)
  end

  M._panel:focus()
  setup_autocmds()
end

--- `setup()` is optional (see config.lua); calling it only overrides the defaults.
---@param opts table?
function M.setup(opts)
  config.setup(opts)
end

function M.close()
  if not M._session then
    return
  end

  stop_refresh_timer()
  clear_autocmds()

  M._session:close()
  if M._panel then
    M._panel:close()
  end

  local viewer_tab = M._viewer_tab
  local origin_tab = M._origin_tab

  M._session = nil
  M._panel = nil
  M._viewer_tab = nil
  M._origin_tab = nil

  if viewer_tab then
    close_tabpage_safe(viewer_tab)
  end
  if origin_tab and vim.api.nvim_tabpage_is_valid(origin_tab) then
    vim.api.nvim_set_current_tabpage(origin_tab)
  end
end

function M.toggle()
  if M._session then
    M.close()
  else
    open_new(nil)
  end
end

function M.refresh()
  if M._session then
    M._session:refresh()
  end
end

--- Remove persisted viewed-state: `all=true` wipes every review's file, otherwise just
--- the current review's (the open session's key, or -- when nothing is open -- a
--- throwaway session built only to resolve that key; see the comment below).
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
  if M._session then
    key = M._session.spec.review_key
  else
    -- No open session to read a key off of: resolve one the same way `session.new` would,
    -- via a throwaway session (never `:close()`d, so nothing gets saved/rendered). This
    -- reuses the single source of truth for base/PR/review-key resolution instead of
    -- duplicating it here.
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
--- subcommands or a base-branch override; a bare `:Difit` (or one with an unrecognized
--- first argument) while a session is already open just focuses the viewer tabpage rather
--- than starting a second one.
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
  end

  if M._session then
    focus_viewer_tab()
    return
  end

  open_new(first)
end

--- Backing function for `<Plug>(difit-toggle-viewed)` (see plugin/difit.lua): toggles the
--- viewed mark for the current buffer's file when that buffer is a real worktree/HEAD file
--- belonging to the open session. difit-owned buffers (`difit://...`) already get their
--- own `config.keymaps.diff.toggle_viewed` mapping straight from the view modules, so this
--- is specifically for real file buffers (e.g. the side-by-side right window, or a file
--- opened via the unified view's jump-to-file).
function M.toggle_viewed_current()
  if not M._session then
    return
  end
  local toplevel = M._session.spec.repo.toplevel
  local prefix = toplevel .. "/"
  local bufname = vim.api.nvim_buf_get_name(0)
  if not vim.startswith(bufname, prefix) then
    return
  end
  toggle_viewed_and_advance(bufname:sub(#prefix + 1))
end

return M
