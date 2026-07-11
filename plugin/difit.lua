-- Auto-loaded plugin entry point. Defines the `:Difit` command and the `<Plug>` mapping
-- without ever `require`ing `difit` itself until one of them actually fires, so simply
-- having this plugin on 'runtimepath' costs nothing until the user invokes it.

if vim.g.loaded_difit then
  return
end
vim.g.loaded_difit = true

local SUBCOMMANDS = { "close", "toggle", "clean", "refresh", "focus", "sweep" }

---@return string[]
local function local_branches()
  local ok, out = pcall(vim.fn.systemlist, { "git", "branch", "--format=%(refname:short)" })
  if not ok or vim.v.shell_error ~= 0 then
    return {}
  end
  return out
end

--- `:command-completion-customlist`-style completion: unlike `:command-completion-custom`,
-- Neovim does not filter these candidates against `arg_lead` on our behalf.
---@param arg_lead string
---@return string[]
local function complete(arg_lead)
  local candidates = vim.list_extend(vim.deepcopy(SUBCOMMANDS), local_branches())
  return vim.tbl_filter(function(candidate)
    return vim.startswith(candidate, arg_lead)
  end, candidates)
end

vim.api.nvim_create_user_command("Difit", function(cmd_opts)
  require("difit").open(cmd_opts.fargs)
end, {
  nargs = "*",
  complete = complete,
  desc = "Open/control the difit review UI (subcommands: close, toggle, clean, refresh, focus, sweep)",
})

vim.keymap.set("n", "<Plug>(difit-toggle-viewed)", function()
  require("difit").toggle_viewed_current()
end, { desc = "difit: toggle viewed for the current buffer's file" })

vim.keymap.set("n", "<Plug>(difit-toggle-mode)", function()
  require("difit").toggle_mode()
end, { desc = "difit: toggle side-by-side/unified" })

vim.keymap.set("n", "<Plug>(difit-focus-panel)", function()
  require("difit").focus()
end, { desc = "difit: focus the panel" })

vim.keymap.set("n", "<Plug>(difit-next-file)", function()
  require("difit").next_file()
end, { desc = "difit: open the next file" })

vim.keymap.set("n", "<Plug>(difit-prev-file)", function()
  require("difit").prev_file()
end, { desc = "difit: open the previous file" })
