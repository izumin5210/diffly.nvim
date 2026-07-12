-- Highlight groups for the panel (WP-H). Kept in its own module (rather than inlined in
-- panel.lua) so `require("diffly.ui.hl").setup()` can be called early and independently
-- (e.g. from an eventual `ColorScheme` autocmd in WP-I) without pulling in panel.lua's
-- buffer/window machinery.

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
  -- chunks in the other.
  DifflyOverlayAdd = "DiffAdd",
  DifflyOverlayDelete = "DiffDelete",
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

function M.setup()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

return M
