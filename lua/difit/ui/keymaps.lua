-- Shared buffer-local keymap plumbing for the diff views. Both `ui/sidebyside.lua` and
-- `ui/unified.lua` need to apply the same shaped config (`keymaps.diff`/`keymaps.file`) to
-- a buffer and later peel it off again (sidebyside's real right-hand buffer moves between
-- files across the same view instance's lifetime) -- this module is the one place that
-- logic lives, instead of each view re-deriving it.

local M = {}

---@class difit.ui.KeymapAction
---@field key string|false|nil  -- falsy disables the mapping (config.lua convention)
---@field callback fun()

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
