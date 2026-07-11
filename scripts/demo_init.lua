-- Minimal init for the README demo (scripts/demo.tape): loads ONLY difit on top of
-- `nvim --clean` so the recording shows stock Neovim + this plugin, nothing else.
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.runtimepath:prepend(root)

vim.o.termguicolors = true
-- Recording hygiene: the tabline and default statusline leak tempdir paths into the
-- capture; show just filenames instead.
vim.o.showtabline = 0
vim.o.statusline = " %t %m"

-- Keep each demo run pristine: viewed state goes to a throwaway dir instead of the
-- real stdpath('data'), so no marks leak in from (or into) actual reviews.
require("difit.state")._dir = vim.fn.tempname()

require("difit").setup({
  viewed_patterns = {
    { name = "lock files", patterns = { "*.lock" } },
    { name = "generated", patterns = { "gen/**" } },
  },
})

-- --clean skips the normal plugin phase for rtp entries added this late, so source the
-- command definition explicitly (idempotent via vim.g.loaded_difit).
vim.cmd("runtime! plugin/difit.lua")
