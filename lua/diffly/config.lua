local M = {}

M.defaults = {
  base = nil, -- string|nil: base branch override
  right = "worktree", -- "worktree"|"head"
  include_untracked = true,
  -- Guard against loading a huge text file's full CONTENT into a diff view by accident
  -- (images/other binaries already render a placeholder regardless of size -- see
  -- ui/sidebyside.lua's/ui/unified.lua's `show_binary`; `ui/guard.lua` owns this
  -- one). Bytes; `false` disables the guard entirely. Applies only to actually loading a
  -- blob/worktree file's content into a buffer -- panel counts come from `git diff
  -- --numstat`, which is cheap regardless of file size, so panel rows are unaffected. An
  -- oversized entry renders a placeholder (styled like the binary one) with a
  -- buffer-local `L` key to force-load it for the rest of that view (side-by-side/unified
  -- track this independently; a mode switch or `:Diffly close` resets it).
  max_file_size = 1024 * 1024,
  -- GitHub-parity collapsing of generated files (docs/architecture.md "Rendering",
  -- lua/diffly/generated.lua): a file's diff body renders as a placeholder (same `L`-key
  -- force-load mechanics as `max_file_size` above, see `ui/guard.lua`) instead of its real
  -- content when it's recognized as vendored/lockfile/codegen output, by linguist's own
  -- rules, OR carries an explicit `.gitattributes` `linguist-generated` override. `false`
  -- disables BOTH the heuristics and the `.gitattributes` override -- every file always
  -- renders normally. There is no diffly-specific pattern list to configure here: GitHub's
  -- own extension point, `.gitattributes` `linguist-generated`/`-linguist-generated`, is
  -- how a user opts a specific file in or out, same as on github.com.
  collapse_generated = true,
  auto_advance = true, -- jump to next un-viewed file after marking
  icons = true, -- use mini.icons / nvim-web-devicons when available
  -- Bulk-viewed pattern GROUPS (gitignore-inspired globs), triggered explicitly via the
  -- panel's `S` key / `:Diffly sweep [group]` -- never applied automatically. Each item is
  -- either a plain string glob (backward compat: every such string collects into one
  -- implicit group named "default", positioned wherever the FIRST plain string appears --
  -- see `M.normalize_pattern_groups`) or a table `{ name = "...", patterns = {...} }` for
  -- an explicitly named group (e.g. splitting lockfiles from generated output so either
  -- can be swept independently). Within a group, a pattern with no "/" matches an entry's
  -- basename (e.g. "*.lock" matches "yarn.lock" anywhere in the tree); a pattern containing
  -- "/" matches the full toplevel-relative path (e.g. "dist/**" matches only "dist/...").
  -- Compiled via `vim.glob.to_lpeg` (LSP glob semantics: "**" crosses directories, a single
  -- "*" does not). See `M.normalize_pattern_groups()` and `Session:pattern_groups()`/
  -- `Session:sweep_patterns()`.
  viewed_patterns = {},
  -- Inline comment display (docs/design.md "Comments"). Neovim never wraps virt_lines
  -- natively ('wrap' applies to real buffer lines only; virt_lines wider than the window
  -- are truncated -- see :h virt_lines_overflow), so diffly wraps comment BODY text
  -- itself at render time. Display-only: the stored comment is untouched (`cy`/`cY` copy
  -- the original), and the code windows' own 'wrap' is never touched either. `wrap =
  -- false` restores the truncating behavior everywhere, including the compose float.
  -- `max_width` caps the wrap budget in display cells so comments stay readable in very
  -- wide windows; `false` uncaps (the window width alone decides).
  comments = { wrap = true, max_width = 100 },
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
    -- applied ONLY in diffly-owned buffers (blob/unified), IN ADDITION to `keymaps.universal`
    -- below -- never in real file buffers. See ui/sidebyside.lua's `View:owned_buffer` /
    -- ui/unified.lua's `setup_keymaps` for the deterministic apply order (diff first,
    -- universal second) that decides which one wins if a user configures the same lhs in
    -- both groups.
    diff = {
      toggle_viewed = "v",
      toggle_mode = "s",
      focus_panel = "<leader>e",
      close = "q",
      -- The comment family (docs/design.md "Comments"). Single keys are safe here: owned
      -- buffers are 'nomodifiable', so the `c` operator these shadow is dead anyway. Only
      -- applied when the buffer shows commentable side content (never on binary/oversized/
      -- generated placeholders -- see ui/keymaps.lua's `side` plumbing).
      comment_add = "ca", -- n: cursor line; x: the visual range
      comment_edit = "ce",
      comment_delete = "cd",
      comment_toggle = "ct", -- collapse/expand inline comment rendering, session-wide
      comment_toggle_resolved = "cr", -- reveal/hide resolved remote threads, session-wide
      comment_copy = "cy", -- difit-format prompt for the comment at the cursor
      comment_copy_all = "cY", -- ditto, every comment in the review
    },
    -- The two-layer model's universal layer (docs/design.md "Interface"): leader-prefixed,
    -- real-buffer-safe keys that work in EVERY diffly context -- diffly-owned buffers (panel,
    -- blob/unified; applied alongside `keymaps.panel`/`keymaps.diff` above) AND real file
    -- buffers currently shown in the viewer (the side-by-side worktree right buffer, which
    -- gets ONLY this group, never `keymaps.diff`). Leader-prefixed so they never collide
    -- with a real buffer's own, non-diffly keymaps. No `close` here -- closing a real file
    -- buffer isn't "closing the review", unlike in an owned diff buffer.
    --
    -- Renamed from `keymaps.file` (pre-v1): the old name only made sense for the
    -- real-file-buffer case; this group is now applied everywhere, so `universal` describes
    -- it accurately in every context, not just that one.
    universal = {
      toggle_viewed = "<leader>v",
      toggle_mode = "<leader>s",
      focus_panel = "<leader>e",
      -- Plain file navigation (ALWAYS all files, never filtered by the
      -- panel's `toggle_hide_viewed` -- that's a display concern; skipping viewed files
      -- during navigation is what `v`'s auto-advance is already for).
      next_file = "]f",
      prev_file = "[f",
      -- Comment navigation: every INLINE-RENDERED thread in the review, in document
      -- order across files (both sides interleaved; see Session:next_comment), wrapping.
      -- Uppercase C: the side-by-side windows run in diff mode, where lowercase `]c`/`[c`
      -- is the builtin change-jump reviewers rely on -- these must never shadow it.
      next_comment = "]C",
      prev_comment = "[C",
      -- The comment family again, leader-prefixed: on a REAL file buffer (the main place
      -- comments get written) this layer is the only one allowed, so the primary comment
      -- gesture is `<leader>c…` by design, not a single key.
      comment_add = "<leader>ca",
      comment_edit = "<leader>ce",
      comment_delete = "<leader>cd",
      comment_toggle = "<leader>ct",
      comment_toggle_resolved = "<leader>cr",
      comment_copy = "<leader>cy",
      comment_copy_all = "<leader>cY",
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

--- Name every implicit group of plain-string globs collects into (see
--- `M.normalize_pattern_groups` below) -- also the name an explicit
--- `{ name = "default", ... }` table collides with, which is deliberately treated as just
--- another duplicate (merged into the first occurrence, warned once) rather than
--- special-cased.
local DEFAULT_GROUP_NAME = "default"

--- "Once per Neovim session" flag for a duplicate group name, keyed by the name itself --
--- same rationale as `session.lua`'s `bad_pattern_notified`: a duplicate name is a
--- persistent config mistake, not a one-off, so every caller re-normalizing the same
--- `viewed_patterns` (every sweep, every menu render that needs group counts, ...) would
--- otherwise re-warn on every single call.
local duplicate_group_notified = {}

---@class diffly.PatternGroup
---@field name string
---@field patterns string[]

--- Normalize `viewed_patterns`' backward-compatible shape into an ordered list of named
--- groups: a plain string glob collects into one implicit group named "default",
--- positioned wherever the FIRST such string appears among `patterns`; a table
--- `{ name = ..., patterns = {...} }` is its own group, positioned where IT appears
--- instead. An explicitly-named table colliding with an already-existing group (another
--- table with the same name, or the implicit "default" bucket) merges into that first
--- occurrence (patterns appended in encounter order) and warns once (see
--- `duplicate_group_notified`) -- a repeated explicit name is virtually always a config
--- mistake, not an intentional split. Plain strings joining the "default" bucket are never
--- treated as a "duplicate", however many of them there are or however that bucket first
--- came to exist (implicitly or via an explicit `{name="default", ...}` table): collecting
--- loose strings together is the exact, unremarkable point of that bucket.
---
--- Lives here rather than `session.lua` because it is pure shape-interpretation of a
--- config value -- no git/session/entries involved -- so it is testable (and tested, see
--- tests/test_config.lua) without spinning up a repo or a `diffly.Session` at all;
--- `session.lua`'s `Session:pattern_groups()` calls this and then does the part that
--- genuinely needs a session: compiling each group's patterns and matching them against
--- `self.entries`.
---@param patterns (string|{name: string, patterns: string[]})[]
---@return diffly.PatternGroup[]
function M.normalize_pattern_groups(patterns)
  local groups = {}
  local index_by_name = {}

  --- @return diffly.PatternGroup group
  --- @return boolean created  -- false when `name` already had a group before this call
  local function get_or_create(name)
    local idx = index_by_name[name]
    if idx then
      return groups[idx], false
    end
    local group = { name = name, patterns = {} }
    table.insert(groups, group)
    index_by_name[name] = #groups
    return group, true
  end

  for _, item in ipairs(patterns or {}) do
    if type(item) == "string" then
      local group = get_or_create(DEFAULT_GROUP_NAME)
      table.insert(group.patterns, item)
    elseif type(item) == "table" and type(item.name) == "string" then
      local group, created = get_or_create(item.name)
      if not created and not duplicate_group_notified[item.name] then
        duplicate_group_notified[item.name] = true
        vim.notify(
          string.format(
            "diffly: duplicate viewed_patterns group name %q; merging into the first occurrence",
            item.name
          ),
          vim.log.levels.WARN
        )
      end
      for _, pattern in ipairs(item.patterns or {}) do
        table.insert(group.patterns, pattern)
      end
    end
  end

  return groups
end

return M
