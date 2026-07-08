-- Tests for lua/difit/ui/scratch.lua (docs/refactor-v1.md R4): the shared find-or-create
-- helper for `difit://` scratch buffers that replaces the logic previously triplicated
-- across ui/panel.lua, ui/sidebyside.lua, and ui/unified.lua. No child Neovim is needed
-- here: MiniTest itself already runs inside a real Neovim process capable of creating
-- buffers (mirrors tests/test_panel.lua's standalone `hl.setup()` case).

local scratch = require("difit.ui.scratch")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    -- Buffers created here are unnamed-scratch by default (`nofile`/`nomodeline`), so
    -- nothing about them survives meaningfully across cases -- wipe them anyway to keep
    -- `vim.fn.bufnr(name)` lookups in later cases from ever seeing a stale buffer.
    post_case = function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf):match("^difit://") then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end,
  },
})

T["name(): builds difit://<kind>/<session_id>/<rest>"] = function()
  eq(scratch.name("panel", 7), "difit://panel/7")
  eq(scratch.name("unified", 3, "src/mod.lua"), "difit://unified/3/src/mod.lua")
end

T["name(): two different session ids never collide for the same kind/rest"] = function()
  local a = scratch.name("deadbeef", 1, "src/mod.lua")
  local b = scratch.name("deadbeef", 2, "src/mod.lua")
  eq(a == b, false)
end

T["find_or_create(): creates a nofile/hidden/no-swapfile buffer and fills content once"] = function()
  local name = scratch.name("test", 1, "a.txt")
  local buf, created = scratch.find_or_create(name, { lines = { "one", "two" } })

  eq(created, true)
  eq(vim.bo[buf].buftype, "nofile")
  eq(vim.bo[buf].bufhidden, "hide")
  eq(vim.bo[buf].swapfile, false)
  eq(vim.bo[buf].modifiable, false)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "two" })
end

T["find_or_create(): reuses an existing buffer by exact name and never re-applies `lines`"] = function()
  local name = scratch.name("test", 1, "b.txt")
  local first, created1 = scratch.find_or_create(name, { lines = { "original" } })
  eq(created1, true)

  local second, created2 = scratch.find_or_create(name, { lines = { "different" } })
  eq(created2, false)
  eq(second, first)
  eq(vim.api.nvim_buf_get_lines(first, 0, -1, false), { "original" })
end

T["find_or_create(): never sets 'filetype', even when a language resolves from `filename`"] = function()
  local name = scratch.name("test", 1, "c.lua")
  local buf = scratch.find_or_create(name, { lines = { "return 1" }, filename = "c.lua" })

  eq(vim.bo[buf].filetype, "")
  local ts_active = vim.treesitter.highlighter.active[buf] ~= nil
  eq(ts_active or vim.bo[buf].syntax == "lua", true)
end

T["find_or_create(): an explicit `lang` wins over filename resolution, and still never touches filetype"] = function()
  local name = scratch.name("test", 1, "d.txt")
  local buf = scratch.find_or_create(name, { lines = { "@@ -1 +1 @@" }, lang = "diff" })

  eq(vim.bo[buf].filetype, "")
  local ts_active = vim.treesitter.highlighter.active[buf] ~= nil
  eq(ts_active or vim.bo[buf].syntax == "diff", true)
end

T["find_or_create(): no filename/lang leaves highlighting untouched (the panel's plain-text case)"] = function()
  local name = scratch.name("test", 1, "e.txt")
  local buf = scratch.find_or_create(name, { lines = { "plain text" } })

  eq(vim.bo[buf].filetype, "")
  eq(vim.bo[buf].syntax, "")
end

T["configure(): honors an explicit `modifiable` option when no `lines` are given"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  scratch.configure(buf, { modifiable = false })

  eq(vim.bo[buf].buftype, "nofile")
  eq(vim.bo[buf].bufhidden, "hide")
  eq(vim.bo[buf].swapfile, false)
  eq(vim.bo[buf].modifiable, false)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "" }, "no content touched")
end

return T
