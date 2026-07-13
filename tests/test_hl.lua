-- Tests for lua/diffly/ui/hl.lua's derived side-by-side diff palette: the
-- asymmetric red/green groups computed from the active colorscheme. Each case runs in a
-- fresh child Neovim: derivation reads global highlight state (`nvim_get_hl`), and
-- `default = true` semantics make definitions sticky within a process, so in-process
-- cases would bleed into each other.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

local child

--- Overwrite the colorscheme-owned groups the derivation reads from, from a clean slate.
--- `nvim_set_hl(0, name, def)` REPLACES the whole definition, so `{}` empties a group --
--- required because `hi clear` restores builtin DEFAULTS (`Added` keeps its fg, `Normal`
--- its bg, ...) rather than leaving groups empty.
---@param groups table<string, table>
local function paint_scheme(groups)
  child.lua(
    [[
      local groups = ...
      for _, name in ipairs({
        "Normal", "DiffAdd", "DiffDelete", "DiffText", "Added", "Removed",
      }) do
        vim.api.nvim_set_hl(0, name, groups[name] or {})
      end
    ]],
    { groups }
  )
end

---@param name string
---@return table
local function get_hl(name)
  return child.lua_get(([[vim.api.nvim_get_hl(0, { name = %q })]]):format(name))
end

---@param name string
---@return table
local function get_hl_resolved(name)
  return child.lua_get(([[vim.api.nvim_get_hl(0, { name = %q, link = false })]]):format(name))
end

local function setup_hl()
  child.lua([[require("diffly.ui.hl").setup()]])
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      child = helpers.new_child(dir)
    end,
    post_case = function()
      child.stop()
    end,
  },
})

-- The derivation contract (docs/design.md "Side-by-side"): line bg comes from the
-- colorscheme's DiffAdd/DiffDelete bg verbatim; the intra-line emphasis is the SAME hue
-- pushed 40% toward the family accent (`Added`/`Removed` fg), plus bold -- never the
-- colorscheme's DiffText, whose hue (often blue) doesn't read as add/remove at all.
T["derives line/text pairs from DiffAdd/DiffDelete bg + Added/Removed fg accents"] = function()
  paint_scheme({
    Normal = { bg = 0x202020 },
    DiffAdd = { bg = 0x203A2A },
    DiffDelete = { bg = 0x3A2028 },
    Added = { fg = 0x40C057 },
    Removed = { fg = 0xE03131 },
  })
  setup_hl()

  eq(get_hl_resolved("DifflyDiffNewLine").bg, 0x203A2A)
  eq(get_hl_resolved("DifflyDiffOldLine").bg, 0x3A2028)

  -- blend(line, accent, 0.4), channel-wise round(a + (b - a) * t)
  local new_text = get_hl_resolved("DifflyDiffNewText")
  eq(new_text.bg, 0x2D703C)
  eq(new_text.bold, true)
  local old_text = get_hl_resolved("DifflyDiffOldText")
  eq(old_text.bg, 0x7C272C)
  eq(old_text.bold, true)
end

T["falls back to blending Normal bg toward the accent when diff groups have no bg"] = function()
  paint_scheme({
    Normal = { bg = 0x282828 },
    DiffAdd = { fg = 0x777777 }, -- fg-only: no bg to inherit
    DiffDelete = { fg = 0x777777 },
    Added = { fg = 0x40C057 },
    Removed = { fg = 0xE03131 },
  })
  setup_hl()

  -- line = blend(Normal.bg, accent, 0.2); text = blend(line, accent, 0.4)
  eq(get_hl_resolved("DifflyDiffNewLine").bg, 0x2D4631)
  eq(get_hl_resolved("DifflyDiffNewText").bg, 0x357740)
  eq(get_hl_resolved("DifflyDiffOldLine").bg, 0x4D2A2A)
  eq(get_hl_resolved("DifflyDiffOldText").bg, 0x882D2D)
end

T["accent falls back to DiffAdd/DiffDelete fg when Added/Removed are empty"] = function()
  paint_scheme({
    Normal = { bg = 0x202020 },
    DiffAdd = { bg = 0x203A2A, fg = 0x40C057 },
    DiffDelete = { bg = 0x3A2028, fg = 0xE03131 },
  })
  setup_hl()

  -- Same expected values as the Added/Removed case: only the accent SOURCE changed.
  eq(get_hl_resolved("DifflyDiffNewText").bg, 0x2D703C)
  eq(get_hl_resolved("DifflyDiffOldText").bg, 0x7C272C)
end

T["degrades to plain links when no usable bg exists anywhere"] = function()
  paint_scheme({}) -- every source group empty: nothing to derive from
  setup_hl()

  eq(get_hl("DifflyDiffNewLine").link, "DiffAdd")
  eq(get_hl("DifflyDiffOldLine").link, "DiffDelete")
  eq(get_hl("DifflyDiffNewText").link, "DiffText")
  eq(get_hl("DifflyDiffOldText").link, "DiffText")
end

T["never clobbers a user-defined group (default = true semantics)"] = function()
  child.lua([[vim.api.nvim_set_hl(0, "DifflyDiffNewText", { bg = 0x123456 })]])
  paint_scheme({
    Normal = { bg = 0x202020 },
    DiffAdd = { bg = 0x203A2A },
    DiffDelete = { bg = 0x3A2028 },
    Added = { fg = 0x40C057 },
    Removed = { fg = 0xE03131 },
  })
  setup_hl()

  eq(get_hl_resolved("DifflyDiffNewText").bg, 0x123456)
end

T["re-derives on ColorScheme so a scheme switch never leaves a stale palette"] = function()
  paint_scheme({
    Normal = { bg = 0x202020 },
    DiffAdd = { bg = 0x203A2A },
    DiffDelete = { bg = 0x3A2028 },
  })
  setup_hl()
  eq(get_hl_resolved("DifflyDiffNewLine").bg, 0x203A2A)

  -- A real `:colorscheme` load runs `hi clear` (dropping our definitions) before the
  -- ColorScheme autocmds fire -- reproduce that exact sequence.
  child.lua([[vim.cmd("highlight clear")]])
  paint_scheme({
    Normal = { bg = 0x101010 },
    DiffAdd = { bg = 0x113311 },
    DiffDelete = { bg = 0x331111 },
  })
  child.lua([[vim.cmd("doautocmd ColorScheme")]])

  eq(get_hl_resolved("DifflyDiffNewLine").bg, 0x113311)
  eq(get_hl_resolved("DifflyDiffOldLine").bg, 0x331111)
end

T["unified overlay + filler groups link into the shared palette"] = function()
  setup_hl()

  -- One palette across both view modes: switching sidebyside <-> unified must not shift
  -- what red/green mean.
  eq(get_hl("DifflyOverlayAdd").link, "DifflyDiffNewLine")
  eq(get_hl("DifflyOverlayDelete").link, "DifflyDiffOldLine")
  -- Filler rows (the `----` alignment lines) are noise, not signal: NonText keeps them
  -- out of the red/green scan entirely.
  eq(get_hl("DifflyDiffFiller").link, "NonText")
end

return T
