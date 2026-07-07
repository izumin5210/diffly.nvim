local M = {}

M.defaults = {
  base = nil, -- string|nil: base branch override
  right = "worktree", -- "worktree"|"head"
  include_untracked = true,
  auto_advance = true, -- jump to next un-viewed file after marking
  icons = true, -- use mini.icons / nvim-web-devicons when available
  panel = { width = 35 },
  keymaps = {
    panel = {
      open = "<CR>", -- open file diff / toggle dir fold when on a dir row
      toggle_viewed = "v",
      refresh = "R",
      toggle_mode = "s", -- side-by-side <-> unified
      close = "q",
      fold = "za",
    },
    -- applied ONLY in difit-owned buffers (blob/unified), never in real file buffers
    diff = { toggle_viewed = "v" },
  },
}

M.options = vim.deepcopy(M.defaults)

--- Merge user-provided options on top of the current options. `setup()` is optional: the
--- plugin works with `M.defaults` untouched when it is never called. Deep-extends (rather
--- than replacing) so repeated calls layer instead of losing earlier overrides.
---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

---@return table
function M.get()
  return M.options
end

return M
