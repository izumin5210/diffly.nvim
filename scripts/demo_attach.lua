-- Injects the LOCAL difit checkout into an already-running Neovim for the README demo
-- (scripts/demo.tape). Unlike a `-u` init this runs AFTER the user's own config (dofile'd
-- via `+lua`), so plugin managers that reset 'runtimepath' on startup (lazy.nvim) can't
-- drop it — the recording shows difit inside the user's real setup: their colorscheme,
-- statusline, and LSP config, which is the point (gopls hover in the diff views).
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.runtimepath:prepend(root)

-- Keep each demo run pristine: viewed state goes to a throwaway dir instead of the real
-- stdpath('data'), so no marks leak in from (or into) actual reviews.
require("difit.state")._dir = vim.fn.tempname()

require("difit").setup({
  viewed_patterns = {
    { name = "generated", patterns = { "*_gen.go" } },
  },
})

-- The normal plugin phase already ran before this file; source the :Difit command
-- definition explicitly (idempotent via vim.g.loaded_difit).
vim.cmd("runtime! plugin/difit.lua")
