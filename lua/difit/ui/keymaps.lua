-- Shared buffer-local keymap plumbing for the diff views. Both `ui/sidebyside.lua` and
-- `ui/unified.lua` need to apply the same shaped config (`keymaps.diff`/`keymaps.file`) to
-- a buffer and later peel it off again (sidebyside's real right-hand buffer moves between
-- files across the same view instance's lifetime) -- this module is the one place that
-- logic lives, instead of each view re-deriving it.

local M = {}

---@class difit.ui.KeymapAction
---@field key string|false|nil  -- falsy disables the mapping (config.lua convention)
---@field callback fun()

--- docs/refactor-v1.md R3: the seam both diff views (`ui/sidebyside.lua`, `ui/unified.lua`)
--- call into for `config.keymaps.diff`/`keymaps.file`, replacing the old module-level
--- `_on_toggle_viewed`/`_on_toggle_mode`/`_on_focus_panel`/`_on_close` slots. Built once per
--- session entry in `init.lua` (see `build_actions` there): every field resolves the LIVE
--- entry through the R1 tabpage registry at call time (never by holding a reference to a
--- `difit.Session`), so a stale closure surviving past `close_entry` degrades to a no-op
--- notify instead of erroring.
---@class difit.ui.Actions
---@field toggle_viewed fun(path: string)
---@field toggle_mode fun()
---@field focus_panel fun()
---@field close fun()

--- docs/refactor-v1.md R2: the explicit window-ownership contract both diff views' `M.new`
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
---@class difit.ui.ViewCtx
---@field anchor integer      -- winid to split rightward from (the panel window)
---@field claim integer?      -- a window this view may absorb as its own; consumed once
---@field actions difit.ui.Actions

--- Apply every action in `spec` to `bufnr`, skipping falsy keys. Returns the list of keys
--- actually mapped so callers can hand it straight to `M.remove` later -- callers would
--- otherwise have to re-derive "which of these were actually enabled" themselves.
---
--- `nowait = true` matters here, not just as a nicety: without it, a LONGER mapping that
--- shares our key as a prefix -- most commonly a user's own global mapping, e.g.
--- `<leader>vs` defined globally while difit maps buffer-local `<leader>v` -- makes Neovim
--- wait out 'timeoutlen' for a possible continuation instead of firing our (shorter)
--- mapping immediately, and the global one wins once the user finishes typing it. This is
--- the same reason diffview.nvim's `File:attach_buffer` always sets `nowait = true`
--- alongside `silent`/`buffer`.
---@param bufnr integer
---@param spec table<string, difit.ui.KeymapAction>
---@return string[] applied_keys
function M.apply(bufnr, spec)
  local applied = {}
  for action, def in pairs(spec) do
    if def.key then
      vim.keymap.set(
        "n",
        def.key,
        def.callback,
        { buffer = bufnr, silent = true, nowait = true, desc = "difit: " .. action }
      )
      table.insert(applied, def.key)
    end
  end
  return applied
end

--- Delete buffer-local mappings for `keys` from `bufnr`. Guards buffer validity itself
--- (callers track bufnrs across `open()` calls; by the time cleanup runs the buffer may
--- already be gone, e.g. wiped by `:bwipeout` from outside difit).
---@param bufnr integer
---@param keys string[]
function M.remove(bufnr, keys)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, key in ipairs(keys) do
    pcall(vim.keymap.del, "n", key, { buffer = bufnr })
  end
end

return M
