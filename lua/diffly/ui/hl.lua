-- Highlight groups for every diffly surface. Kept in its own module (rather than inlined
-- in panel.lua) so `require("diffly.ui.hl").setup()` can be called early and independently
-- (from `init.lua`'s open path and from the `ColorScheme` autocmd wired below) without
-- pulling in panel.lua's buffer/window machinery.

local M = {}

-- `default = true` in `nvim_set_hl` means "define unless the user (or their colorscheme)
-- already set this group" -- so `setup()` is safe to call repeatedly and never clobbers
-- a user override.
local LINKS = {
  DifflyPanelHeader = "Title",
  DifflyPanelDir = "Directory",
  DifflyStatusAdded = "Added",
  DifflyStatusModified = "Changed",
  DifflyStatusDeleted = "Removed",
  DifflyStatusRenamed = "Special",
  DifflyViewed = "Comment",
  -- The row for whichever file is currently shown in the diff view (`session.current_path`,
  -- see ui/panel.lua's `Panel:render`). `QuickFixLine` is the closest builtin semantic
  -- match ("the current entry") and is bg-colored in most colorschemes, so it reads as a
  -- row highlight rather than text-only styling.
  DifflyCurrentFile = "QuickFixLine",
  DifflyCounts = "Comment",
  DifflyCheckbox = "Special",
  -- Inline-overlay unified view (see docs/architecture.md's "Rendering" section): "+"
  -- lines get a line-level extmark in this group; deleted runs render as `virt_lines`
  -- chunks in the other. Linked into the derived side-by-side palette below so switching
  -- view modes never shifts what red/green mean.
  DifflyOverlayAdd = "DifflyDiffNewLine",
  DifflyOverlayDelete = "DifflyDiffOldLine",
  -- Diff-mode filler rows (the `----` alignment lines opposite added/deleted lines).
  -- They mark "no line here", which is noise to a reviewer scanning for red/green --
  -- NonText keeps them visible but out of the color scan (the native default,
  -- DiffDelete, paints them red INSIDE the green/new pane).
  DifflyDiffFiller = "NonText",
  -- Inline comment rendering (ui/comments.lua): the body text of an expanded thread, and
  -- the marker glyphs around it (the "┃ " gutter, the collapsed eol indicator, the
  -- panel's per-file comment count).
  DifflyCommentBody = "NormalFloat",
  DifflyCommentMarker = "Special",
  -- Remote review threads (the read-only overlay): a distinct marker so fetched
  -- conversations never masquerade as local drafts, plus author attribution and the
  -- resolved tag.
  DifflyCommentRemoteMarker = "Identifier",
  DifflyCommentAuthor = "Title",
  DifflyCommentResolved = "Comment",
}

--- Channel-wise linear interpolation from `color` toward `toward` (both 0xRRGGBB).
---@param color integer
---@param toward integer
---@param t number  -- 0 = `color`, 1 = `toward`
---@return integer
local function blend(color, toward, t)
  local function mix(a, b)
    return math.floor(a + (b - a) * t + 0.5)
  end
  local r = mix(math.floor(color / 0x10000), math.floor(toward / 0x10000))
  local g = mix(math.floor(color / 0x100) % 0x100, math.floor(toward / 0x100) % 0x100)
  local b = mix(color % 0x100, toward % 0x100)
  return r * 0x10000 + g * 0x100 + b
end

--- Effective (link-resolved) attributes of a highlight group; `{}` when undefined.
---@param name string
---@return vim.api.keyset.hl_info
local function attrs(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

-- The derived side-by-side palette (docs/design.md "Side-by-side"). Native diff
-- mode's group semantics are symmetric -- "lines missing on the other side" are DiffAdd
-- in BOTH windows, so the before pane paints deleted lines green -- and the intra-line
-- emphasis inherits the colorscheme's DiffText hue (often blue), which a reviewer
-- scanning for "red = removed / green = added" can't read. Instead diffly derives one
-- color FAMILY per pane from the colorscheme itself: the line bg is the colorscheme's
-- own DiffAdd/DiffDelete bg, and the intra-line emphasis is that same hue pushed toward
-- the family accent -- guaranteed same-hue, guaranteed distinct from the line bg,
-- regardless of what the colorscheme chose for DiffText.
local FAMILIES = {
  {
    line = "DifflyDiffOldLine",
    text = "DifflyDiffOldText",
    bg_src = "DiffDelete",
    accent_srcs = { "Removed", "DiffDelete" },
    -- Neutral fallback hues (GitHub's dark-theme diff accents) that stay legible on both
    -- light and dark backgrounds, for colorschemes that define no red/green fg at all.
    accent_fallback = 0xE5534B,
  },
  {
    line = "DifflyDiffNewLine",
    text = "DifflyDiffNewText",
    bg_src = "DiffAdd",
    accent_srcs = { "Added", "DiffAdd" },
    accent_fallback = 0x2EA043,
  },
}

-- How far toward the accent each layer sits: a line bg synthesized from Normal stays a
-- faint tint (0.2), while the intra-line emphasis moves far enough from ANY line bg to
-- always stand out against it (0.4).
local LINE_BLEND = 0.2
local TEXT_BLEND = 0.4

--- Compute and (default-)define the four derived groups. Line bg prefers the
--- colorscheme's own DiffAdd/DiffDelete bg verbatim; without one it's synthesized from
--- Normal's bg; without even that (fg-only schemes, transparent backgrounds) the whole
--- family degrades to plain links -- asymmetry survives via DiffAdd/DiffDelete, only the
--- guaranteed hue/contrast of the emphasis layer is lost.
local function apply_diff_palette()
  local normal_bg = attrs("Normal").bg
  for _, family in ipairs(FAMILIES) do
    local accent = attrs(family.accent_srcs[1]).fg
      or attrs(family.accent_srcs[2]).fg
      or family.accent_fallback
    local line_bg = attrs(family.bg_src).bg or (normal_bg and blend(normal_bg, accent, LINE_BLEND))
    if line_bg then
      vim.api.nvim_set_hl(0, family.line, { bg = line_bg, default = true })
      vim.api.nvim_set_hl(
        0,
        family.text,
        { bg = blend(line_bg, accent, TEXT_BLEND), bold = true, default = true }
      )
    else
      vim.api.nvim_set_hl(0, family.line, { link = family.bg_src, default = true })
      vim.api.nvim_set_hl(0, family.text, { link = "DiffText", default = true })
    end
  end
end

function M.setup()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  apply_diff_palette()

  -- A `:colorscheme` load runs `hi clear` (dropping the derived definitions above)
  -- before ColorScheme autocmds fire, so re-running setup() here re-derives against the
  -- new scheme; `default = true` keeps this a no-op for anything the user or the new
  -- scheme already defined. `clear = true` makes the registration idempotent across
  -- repeated setup() calls.
  local group = vim.api.nvim_create_augroup("diffly.hl", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      M.setup()
    end,
  })
end

return M
