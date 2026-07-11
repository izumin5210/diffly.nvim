-- Highlight groups for the panel (WP-H). Kept in its own module (rather than inlined in
-- panel.lua) so `require("difit.ui.hl").setup()` can be called early and independently
-- (e.g. from an eventual `ColorScheme` autocmd in WP-I) without pulling in panel.lua's
-- buffer/window machinery.

local M = {}

-- `default = true` in `nvim_set_hl` means "define unless the user (or their colorscheme)
-- already set this group" -- so `setup()` is safe to call repeatedly and never clobbers
-- a user override.
local LINKS = {
  DifitPanelHeader = "Title",
  DifitPanelDir = "Directory",
  DifitStatusAdded = "Added",
  DifitStatusModified = "Changed",
  DifitStatusDeleted = "Removed",
  DifitStatusRenamed = "Special",
  DifitViewed = "Comment",
  -- The row for whichever file is currently shown in the diff view (`session.current_path`,
  -- see ui/panel.lua's `Panel:render`). `QuickFixLine` is the closest builtin semantic
  -- match ("the current entry") and is bg-colored in most colorschemes, so it reads as a
  -- row highlight rather than text-only styling.
  DifitCurrentFile = "QuickFixLine",
  DifitCounts = "Comment",
  DifitCheckbox = "Special",
  -- Inline-overlay unified view (see docs/architecture.md's "Rendering" section): "+"
  -- lines get a line-level extmark in this group; deleted runs render as `virt_lines`
  -- chunks in the other.
  DifitOverlayAdd = "DiffAdd",
  DifitOverlayDelete = "DiffDelete",
}

function M.setup()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

return M
