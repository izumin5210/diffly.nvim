-- Injects the LOCAL diffly checkout into an already-running Neovim for the README demo
-- (scripts/demo.tape). Unlike a `-u` init this runs AFTER the user's own config (dofile'd
-- via `+lua`), so plugin managers that reset 'runtimepath' on startup (lazy.nvim) can't
-- drop it — the recording shows diffly inside the user's real setup: their colorscheme,
-- statusline, and LSP config, which is the point (gopls hover in the diff views).
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.runtimepath:prepend(root)

-- Keep each demo run pristine: viewed state goes to a throwaway dir instead of the real
-- stdpath('data'), so no marks leak in from (or into) actual reviews. Also pin the
-- legacy-dir migration seam to a throwaway (never-created) path: left at its default, the
-- one-time difit.nvim -> diffly.nvim migration would find this machine's real pre-rename
-- `stdpath('data')/difit` (this plugin's own former name) and rename it away into the
-- demo's temp dir, permanently losing real viewed-marks history the next time the plugin
-- is used for an actual review.
local state = require("diffly.state")
state._dir = vim.fn.tempname()
state._legacy_dir = vim.fn.tempname()

-- Window-dimming plugins that swap other windows' highlight namespaces break the
-- side-by-side palette on camera: vimade replaces each unfocused pane's namespace with
-- a dim copy computed from the GLOBAL groups (so the base pane reads native green the
-- moment the comment compose float takes focus) and restores namespace 0 -- not the
-- previous namespace -- afterwards, leaving the panes native for the rest of the
-- recording. The demos exist to show diffly's own rendering, so force the dimmer off
-- for the take; a no-op on machines without vimade/lazy.nvim. (Deliberately NOT worked
-- around in diffly itself -- out-fighting plugins that stomp `w_ns_hl` per redraw isn't
-- worth the arms race.)
pcall(function()
  require("lazy").load({ plugins = { "vimade" } })
  vim.cmd("VimadeDisable")
end)

require("diffly").setup({
  viewed_patterns = {
    { name = "generated", patterns = { "*_gen.go" } },
  },
})

-- The normal plugin phase already ran before this file; source the :Diffly command
-- definition explicitly (idempotent via vim.g.loaded_diffly).
vim.cmd("runtime! plugin/diffly.lua")
