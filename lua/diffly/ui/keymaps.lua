-- Shared buffer-local keymap plumbing for the diff views. Both `ui/sidebyside.lua` and
-- `ui/unified.lua` need to apply the same shaped config (`keymaps.diff`/`keymaps.universal`)
-- to a buffer and later peel it off again (a real worktree buffer moves between files
-- across the same view instance's lifetime, in both views now that `ui/unified.lua` also
-- shows the real file in worktree mode -- the inline-overlay model (docs/architecture.md "Rendering")) --
-- this module is the one place that logic lives, instead of each view re-deriving it.

local config = require("diffly.config")

local M = {}

---@class diffly.ui.KeymapAction
---@field key string|false|nil  -- falsy disables the mapping (config.lua convention)
---@field modes string[]?       -- map modes, default {"n"}; "x" enables visual-range
--- actions (comment_add over a selection)
---@field callback fun()

--- docs/architecture.md "View contract": the seam both diff views (`ui/sidebyside.lua`, `ui/unified.lua`)
--- call into for `config.keymaps.diff`/`keymaps.universal`, replacing the old module-level
--- `_on_toggle_viewed`/`_on_toggle_mode`/`_on_focus_panel`/`_on_close` slots. Built once per
--- session entry in `init.lua` (see `build_actions` there): every field resolves the LIVE
--- entry through the R1 tabpage registry at call time (never by holding a reference to a
--- `diffly.Session`), so a stale closure surviving past `close_entry` degrades to a no-op
--- notify instead of erroring.
---@class diffly.ui.Actions
---@field toggle_viewed fun(path: string)
---@field toggle_mode fun()
---@field focus_panel fun()
---@field close fun()
---@field next_file fun(path: string)
---@field prev_file fun(path: string)
---@field comments_for fun(path: string): diffly.CommentThread[]  -- render-time read the
--- views' comment repaint pulls threads through (views never hold a session); stale ->
--- `{}` silently, since a render is not a user action worth a notify
---@field comments_collapsed fun(): boolean  -- ditto; stale -> false

--- docs/architecture.md "View contract": the explicit window-ownership contract both diff views' `M.new`
--- takes in place of ever reading "the current window". `anchor` is the window to split
--- rightward from (`init.lua` passes the panel window); `claim` is an optional window a
--- view may absorb as one of its own instead of splitting a fresh one (`init.lua` passes
--- the placeholder window created alongside the viewer tabpage, but only for the very
--- first view -- see `ensure_windows`/`ensure_window` in the two view modules, which clear
--- it once consumed so a later mode switch never mistakes some other window for a fresh
--- claim). Built once per session entry and passed BY REFERENCE to every view the
--- session's `view_factory` ever constructs (including across `set_mode`), so `anchor`
--- stays valid for the entry's whole lifetime even though it is filled in AFTER the
--- session itself is constructed (see `init.lua`'s `open_new`: the tabpage/panel don't
--- exist yet at `session.new()` time, only by the time a view's windows actually get built).
---@class diffly.ui.ViewCtx
---@field anchor integer      -- winid to split rightward from (the panel window)
---@field claim integer?      -- a window this view may absorb as its own; consumed once
---@field actions diffly.ui.Actions

--- Apply every action in `spec` to `bufnr`, skipping falsy keys. Returns the list of keys
--- actually mapped so callers can hand it straight to `M.remove` later -- callers would
--- otherwise have to re-derive "which of these were actually enabled" themselves.
---
--- `nowait = true` matters here, not just as a nicety: without it, a LONGER mapping that
--- shares our key as a prefix -- most commonly a user's own global mapping, e.g.
--- `<leader>vs` defined globally while diffly maps buffer-local `<leader>v` -- makes Neovim
--- wait out 'timeoutlen' for a possible continuation instead of firing our (shorter)
--- mapping immediately, and the global one wins once the user finishes typing it. This is
--- the same reason diffview.nvim's `File:attach_buffer` always sets `nowait = true`
--- alongside `silent`/`buffer`.
---@param bufnr integer
---@param spec table<string, diffly.ui.KeymapAction>
---@return string[] applied_keys
function M.apply(bufnr, spec)
  local applied = {}
  for action, def in pairs(spec) do
    if def.key then
      vim.keymap.set(
        def.modes or { "n" },
        def.key,
        def.callback,
        { buffer = bufnr, silent = true, nowait = true, desc = "diffly: " .. action }
      )
      table.insert(applied, def.key)
    end
  end
  return applied
end

--- Delete buffer-local mappings for `keys` from `bufnr`. Guards buffer validity itself
--- (callers track bufnrs across `open()` calls; by the time cleanup runs the buffer may
--- already be gone, e.g. wiped by `:bwipeout` from outside diffly). Deletion tries every
--- mode `apply` can set rather than tracking (key, mode) pairs -- the pcall already
--- tolerates keys that were never mapped in a given mode, so the applied-keys list keeps
--- its simple flat shape.
---@param bufnr integer
---@param keys string[]
function M.remove(bufnr, keys)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, key in ipairs(keys) do
    for _, mode in ipairs({ "n", "x" }) do
      pcall(vim.keymap.del, mode, key, { buffer = bufnr })
    end
  end
end

-- Monotonic counter backing `M.attach_universal`'s ownership stamp (see below) -- module-
-- level rather than per-buffer-var-initialized, so every stamp handed out for the whole
-- Neovim session is unique regardless of how many buffers/views come and go.
local next_universal_token = 0

--- Full `config.keymaps.diff` action set for a diffly-owned buffer showing `path` --
--- applied to every diffly-owned diff buffer both views ever create (the side-by-side
--- blob windows; the unified view's owned blob/binary buffers), never to a real file
--- buffer (design.md: real buffers only ever get `M.universal_spec` below).
---@param actions diffly.ui.Actions
---@param path string
---@return table<string, diffly.ui.KeymapAction>
function M.diff_spec(actions, path)
  local cfg = config.get().keymaps.diff
  return {
    toggle_viewed = {
      key = cfg.toggle_viewed,
      callback = function()
        actions.toggle_viewed(path)
      end,
    },
    toggle_mode = {
      key = cfg.toggle_mode,
      callback = function()
        actions.toggle_mode()
      end,
    },
    focus_panel = {
      key = cfg.focus_panel,
      callback = function()
        actions.focus_panel()
      end,
    },
    close = {
      key = cfg.close,
      callback = function()
        actions.close()
      end,
    },
  }
end

--- `config.keymaps.universal` action set: applied ALONE to whichever real worktree buffer
--- a view currently shows (see `M.attach_universal` below), and a second time, IN ADDITION
--- to `M.diff_spec`, to every diffly-owned buffer either view creates -- the universal layer
--- must work everywhere. No `close` entry: `keymaps.universal` never includes one (real
--- buffers never get a diffly-mapped `close`; an owned buffer still gets it from
--- `M.diff_spec`).
---@param actions diffly.ui.Actions
---@param path string
---@return table<string, diffly.ui.KeymapAction>
function M.universal_spec(actions, path)
  local cfg = config.get().keymaps.universal
  return {
    toggle_viewed = {
      key = cfg.toggle_viewed,
      callback = function()
        actions.toggle_viewed(path)
      end,
    },
    toggle_mode = {
      key = cfg.toggle_mode,
      callback = function()
        actions.toggle_mode()
      end,
    },
    focus_panel = {
      key = cfg.focus_panel,
      callback = function()
        actions.focus_panel()
      end,
    },
    -- `path` is this buffer's own file -- for a diffly-owned diff buffer or the real
    -- worktree/HEAD buffer alike, that's exactly `session.current_path` (see
    -- `init.lua`'s `build_actions`), so no extra "what am I looking at" lookup is needed
    -- here the way the panel's own `]f`/`[f` handlers need one (see ui/panel.lua).
    next_file = {
      key = cfg.next_file,
      callback = function()
        actions.next_file(path)
      end,
    },
    prev_file = {
      key = cfg.prev_file,
      callback = function()
        actions.prev_file(path)
      end,
    },
  }
end

--- Delete `keys` from `bufnr`, but ONLY if `bufnr`'s current ownership stamp still equals
--- `token` -- guards against a cross-view race: `session.lua`'s mode switch builds the new
--- view and opens it BEFORE closing the old one (docs/architecture.md "View contract", so the diff area
--- never flashes empty), so when both sidebyside and unified can show the SAME real
--- worktree buffer, the NEW view's `attach_universal` can run and re-stamp `bufnr` BEFORE
--- the OLD view's `close()`/file-switch cleanup gets around to detaching it. Without this
--- check, the old view's cleanup would blindly delete `keymaps.universal`'s lhs set again
--- -- which, by then, belongs to the NEW view -- leaving the real buffer with none of
--- diffly's keymaps at all. The stamp lives in `vim.b[bufnr]` (survives independently of
--- any one view instance) rather than solely in `state`, precisely so a STALE `state` can
--- tell its own attach has since been superseded.
---@param bufnr integer
---@param token integer?
---@param keys string[]
local function remove_if_still_owner(bufnr, token, keys)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.b[bufnr].diffly_universal_token ~= token then
    return
  end
  M.remove(bufnr, keys)
end

--- Apply `keymaps.universal` to the real buffer `bufnr` (showing `path`), first peeling
--- the same keys off whatever buffer `state.universal_buf` held them before -- otherwise a
--- real file buffer that stops being "the current file" (the view moved on to a different
--- one) would keep responding to diffly's keymaps forever, since nothing else ever touches
--- a real file buffer's own keymaps.
---
--- `state` is any plain table the caller (a View) owns for its whole lifetime, with
--- `universal_buf`/`universal_keys`/`universal_token` fields this function reads and
--- writes -- both `ui/sidebyside.lua` and `ui/unified.lua` just pass `self`, so the two
--- views share this exact attach/detach lifecycle instead of each re-implementing it.
---@param state { universal_buf: integer?, universal_keys: string[]?, universal_token: integer? }
---@param bufnr integer
---@param path string
---@param actions diffly.ui.Actions
function M.attach_universal(state, bufnr, path, actions)
  if state.universal_buf and state.universal_buf ~= bufnr then
    remove_if_still_owner(state.universal_buf, state.universal_token, state.universal_keys or {})
  end
  next_universal_token = next_universal_token + 1
  vim.b[bufnr].diffly_universal_token = next_universal_token
  state.universal_token = next_universal_token
  state.universal_keys = M.apply(bufnr, M.universal_spec(actions, path))
  state.universal_buf = bufnr
end

--- Peel `keymaps.universal` off whatever real buffer currently holds them, if any --
--- UNLESS a newer `attach_universal` call has since re-claimed that same buffer (see
--- `remove_if_still_owner`). Called whenever a view stops showing that buffer (a different
--- file, a diffly-owned buffer, or `close()`) -- the previous real buffer is left alone
--- otherwise (design.md: editing/`:w` on it must keep working normally), it just must not
--- keep diffly's keymaps.
---@param state { universal_buf: integer?, universal_keys: string[]?, universal_token: integer? }
function M.detach_universal(state)
  if state.universal_buf then
    remove_if_still_owner(state.universal_buf, state.universal_token, state.universal_keys or {})
  end
  state.universal_buf = nil
  state.universal_keys = nil
  state.universal_token = nil
end

return M
