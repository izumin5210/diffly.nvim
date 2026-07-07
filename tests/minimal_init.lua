-- Minimal init used by `make test` / `make test FILE=...`. Keeps the test runtime
-- isolated from the user's own Neovim config so CI and local runs behave identically.

-- Resolve paths relative to this file rather than the invocation cwd, so both the
-- top-level `nvim -u tests/minimal_init.lua` and child processes restarted with the
-- same script (from a different cwd, see helpers.new_child) find the right runtime.
local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = vim.fn.fnamemodify(source, ":p:h")
local repo_root = vim.fn.fnamemodify(tests_dir, ":h")
local mini_path = repo_root .. "/deps/mini.nvim"

vim.opt.runtimepath:prepend(repo_root)
vim.opt.runtimepath:prepend(mini_path)

require("mini.test").setup()
