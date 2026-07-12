-- Tests for lua/diffly/ui/keymaps.lua's mode handling: `apply` maps each action in every
-- mode its spec asks for (default: normal only) and `remove` peels all of them off again.
-- In-process (no child): plain scratch buffers in the runner Neovim are enough to observe
-- buffer-local keymaps. The attach/detach/ownership lifecycle is covered by the view and
-- e2e suites; this file pins just the spec-level mode plumbing.

local keymaps = require("diffly.ui.keymaps")

local eq = MiniTest.expect.equality

---@param buf integer
---@param mode string
---@param lhs string
---@return boolean
local function has_map(buf, mode, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if map.lhs == lhs then
      return true
    end
  end
  return false
end

local T = MiniTest.new_set()

T["apply(): maps in normal mode only by default"] = function()
  local buf = vim.api.nvim_create_buf(false, true)

  local applied = keymaps.apply(buf, {
    act = { key = "gz", callback = function() end },
  })

  eq(applied, { "gz" })
  eq(has_map(buf, "n", "gz"), true)
  eq(has_map(buf, "x", "gz"), false)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["apply(): a spec's modes list maps every listed mode; remove() peels them all"] = function()
  local buf = vim.api.nvim_create_buf(false, true)

  local applied = keymaps.apply(buf, {
    act = { key = "gz", modes = { "n", "x" }, callback = function() end },
  })

  eq(applied, { "gz" })
  eq(has_map(buf, "n", "gz"), true)
  eq(has_map(buf, "x", "gz"), true)

  keymaps.remove(buf, applied)
  eq(has_map(buf, "n", "gz"), false)
  eq(has_map(buf, "x", "gz"), false)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["apply(): falsy keys are skipped in every mode"] = function()
  local buf = vim.api.nvim_create_buf(false, true)

  local applied = keymaps.apply(buf, {
    act = { key = false, modes = { "n", "x" }, callback = function() end },
  })

  eq(applied, {})
  eq(#vim.api.nvim_buf_get_keymap(buf, "n"), 0)
  eq(#vim.api.nvim_buf_get_keymap(buf, "x"), 0)

  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
