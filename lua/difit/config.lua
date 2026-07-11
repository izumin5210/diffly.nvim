local M = {}

M.defaults = {
  base = nil, -- string|nil: base branch override
  right = "worktree", -- "worktree"|"head"
  include_untracked = true,
  auto_advance = true, -- jump to next un-viewed file after marking
  icons = true, -- use mini.icons / nvim-web-devicons when available
  -- Bulk-viewed glob patterns (gitignore-inspired), triggered explicitly via the panel's
  -- `S` key / `:Difit sweep` -- never applied automatically. A pattern with no "/" matches
  -- an entry's basename (e.g. "*.lock" matches "yarn.lock" anywhere in the tree); a pattern
  -- containing "/" matches the full toplevel-relative path (e.g. "dist/**" matches only
  -- "dist/..."). Compiled via `vim.glob.to_lpeg` (LSP glob semantics: "**" crosses
  -- directories, a single "*" does not). See `Session:sweep_patterns()`.
  viewed_patterns = {},
  panel = { width = 35 },
  keymaps = {
    panel = {
      open = "<CR>", -- open file diff / toggle dir fold when on a dir row
      toggle_viewed = "v",
      refresh = "R",
      toggle_mode = "s", -- side-by-side <-> unified
      close = "q",
      fold = "za",
      toggle_hide_viewed = "H", -- hide/show already-viewed rows (display only; see ui/panel.lua)
      sweep = "S", -- tri-state bulk toggle for files matching `viewed_patterns`
      toggle_viewed_subtree = "V", -- tri-state bulk toggle for every file under a dir row
    },
    -- applied ONLY in difit-owned buffers (blob/unified), IN ADDITION to `keymaps.universal`
    -- below -- never in real file buffers. See ui/sidebyside.lua's `View:owned_buffer` /
    -- ui/unified.lua's `setup_keymaps` for the deterministic apply order (diff first,
    -- universal second) that decides which one wins if a user configures the same lhs in
    -- both groups.
    diff = { toggle_viewed = "v", toggle_mode = "s", focus_panel = "<leader>e", close = "q" },
    -- The two-layer model's universal layer (docs/design.md "Interface"): leader-prefixed,
    -- real-buffer-safe keys that work in EVERY difit context -- difit-owned buffers (panel,
    -- blob/unified; applied alongside `keymaps.panel`/`keymaps.diff` above) AND real file
    -- buffers currently shown in the viewer (the side-by-side worktree right buffer, which
    -- gets ONLY this group, never `keymaps.diff`). Leader-prefixed so they never collide
    -- with a real buffer's own, non-difit keymaps. No `close` here -- closing a real file
    -- buffer isn't "closing the review", unlike in an owned diff buffer.
    --
    -- Renamed from `keymaps.file` (pre-v1): the old name only made sense for the
    -- real-file-buffer case; this group is now applied everywhere, so `universal` describes
    -- it accurately in every context, not just that one.
    universal = {
      toggle_viewed = "<leader>v",
      toggle_mode = "<leader>s",
      focus_panel = "<leader>e",
      -- Plain file navigation (docs/plan.md-style: ALWAYS all files, never filtered by the
      -- panel's `toggle_hide_viewed` -- that's a display concern; skipping viewed files
      -- during navigation is what `v`'s auto-advance is already for).
      next_file = "]f",
      prev_file = "[f",
    },
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
