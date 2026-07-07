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
  DifitCounts = "Comment",
  DifitCheckbox = "Special",
}

function M.setup()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

return M
