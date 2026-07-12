-- Auto-loaded plugin entry point. Defines the `:Diffly` command and the `<Plug>` mapping
-- without ever `require`ing `diffly` itself until one of them actually fires, so simply
-- having this plugin on 'runtimepath' costs nothing until the user invokes it.

if vim.g.loaded_diffly then
  return
end
vim.g.loaded_diffly = true

local SUBCOMMANDS =
  { "close", "toggle", "clean", "refresh", "focus", "sweep", "comments", "submit" }

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
---@param cmd_line string
---@return string[]
local function complete(arg_lead, cmd_line)
  -- Once the first argument is literally "sweep", every later one is a pattern-group
  -- name, not a subcommand/branch -- `:Diffly sweep <Tab>` should only ever offer
  -- `require("diffly").sweep_group_names()` (see its own doc: empty outside a viewer
  -- tabpage, never a subcommand/branch name in that position).
  -- Matches the command name loosely (not hardcoded to "Diffly") since Vim allows a
  -- unique command-name abbreviation (e.g. ":Dif sweep <Tab>") to reach the very same
  -- completion function with that shorter spelling still in `cmd_line`.
  if cmd_line:match("^%s*%S+%s+sweep%s") then
    local candidates = require("diffly").sweep_group_names()
    return vim.tbl_filter(function(candidate)
      return vim.startswith(candidate, arg_lead)
    end, candidates)
  end

  local candidates = vim.list_extend(vim.deepcopy(SUBCOMMANDS), local_branches())
  return vim.tbl_filter(function(candidate)
    return vim.startswith(candidate, arg_lead)
  end, candidates)
end

vim.api.nvim_create_user_command("Diffly", function(cmd_opts)
  require("diffly").open(cmd_opts.fargs)
end, {
  nargs = "*",
  complete = complete,
  desc = "Open/control the diffly review UI (subcommands: close, toggle, clean, refresh, "
    .. "focus, sweep [group], comments, submit)",
})

vim.keymap.set("n", "<Plug>(diffly-toggle-viewed)", function()
  require("diffly").toggle_viewed_current()
end, { desc = "diffly: toggle viewed for the current buffer's file" })

vim.keymap.set("n", "<Plug>(diffly-toggle-mode)", function()
  require("diffly").toggle_mode()
end, { desc = "diffly: toggle side-by-side/unified" })

vim.keymap.set("n", "<Plug>(diffly-focus-panel)", function()
  require("diffly").focus()
end, { desc = "diffly: focus the panel" })

vim.keymap.set("n", "<Plug>(diffly-next-file)", function()
  require("diffly").next_file()
end, { desc = "diffly: open the next file" })

vim.keymap.set("n", "<Plug>(diffly-prev-file)", function()
  require("diffly").prev_file()
end, { desc = "diffly: open the previous file" })
