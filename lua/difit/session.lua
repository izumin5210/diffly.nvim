-- Session orchestration core (WP-E). This module owns the git/state plumbing that
-- turns a working directory into a `difit.DiffSpec` + file list + viewed-state, and
-- exposes the operations a UI drives a review with. It has no UI of its own: renders
-- happen through subscriber callbacks and an injected view factory (see
-- `difit.SessionOpts.view_factory`), so this module is fully testable without any
-- `lua/difit/ui/*` dependency, and the real factories are wired up by WP-I.

local config = require("difit.config")
local git = require("difit.git")
local state = require("difit.state")
local tree = require("difit.tree")

-- Loaded once at require-time; `opts.github` (tests, mainly) overrides this per call
-- without needing to touch the module cache.
local default_github = require("difit.github")

local M = {}

---@class difit.Session
---@field spec difit.DiffSpec
---@field entries difit.FileEntry[]
---@field state difit.ReviewState
---@field mode "sidebyside"|"unified"
---@field current_path string?
local Session = {}
Session.__index = Session

-- This notice is meant to fire once per Neovim *session* (i.e. process lifetime), not
-- once per `difit.Session` instance -- a plain module-level flag survives across
-- however many reviews get opened/closed in one Neovim run, and resets naturally on the
-- next Neovim start (or the next test's fresh child process).
local gh_missing_notified = false

-- Same "once per Neovim session" rationale as `gh_missing_notified` above, keyed by the
-- offending pattern string instead of a single flag: a bad entry in `config.viewed_patterns`
-- is typically a persistent config mistake, not a one-off, so every `sweep_patterns()` call
-- for the life of the process would otherwise re-warn on every single sweep.
local bad_pattern_notified = {}

--- Compile `pattern` (see `config.viewed_patterns`) into a matcher over an entry's path, or
--- `nil` when the pattern fails to compile (warned about once per pattern, see
--- `bad_pattern_notified`). A pattern with no "/" matches the entry's basename only
--- (gitignore-style); one containing "/" matches the full toplevel-relative path.
---@param pattern string
---@return fun(path: string): boolean|nil matcher
local function compile_pattern(pattern)
  local ok, lpeg_pattern = pcall(vim.glob.to_lpeg, pattern)
  if not ok then
    if not bad_pattern_notified[pattern] then
      bad_pattern_notified[pattern] = true
      vim.notify(
        string.format(
          "difit: ignoring invalid viewed_patterns entry %q (%s)",
          pattern,
          lpeg_pattern
        ),
        vim.log.levels.WARN
      )
    end
    return nil
  end

  local has_slash = pattern:find("/", 1, true) ~= nil
  return function(path)
    local subject = has_slash and path or vim.fs.basename(path)
    return lpeg_pattern:match(subject) ~= nil
  end
end

--- Review keys/UI store the short branch name ("main"), never the resolved
--- remote-tracking ref ("origin/main") `resolve_ref` may have needed internally.
---@param ref string
---@return string
local function short_name(ref)
  return ref:match("^origin/(.+)$") or ref
end

--- Resolve `name` to a ref `git rev-parse` accepts: the bare name, its `origin/`-
--- prefixed remote-tracking form (e.g. a PR's `baseRefName` or a config override is
--- usually a short name like "main", which only exists locally as `origin/main` when the
--- branch itself was never checked out), and finally the same short name prefixed by
--- every *other* configured remote (e.g. an "upstream"-only clone with no "origin" at
--- all, or a base branch that only exists on a secondary remote).
---@param repo difit.RepoIdentity
---@param name string
---@return string|nil resolved
local function resolve_ref(repo, name)
  if git.rev_parse(repo, name) then
    return name
  end
  local origin_remote = "origin/" .. name
  if git.rev_parse(repo, origin_remote) then
    return origin_remote
  end

  for _, remote in ipairs(git.remotes(repo) or {}) do
    if remote ~= "origin" then
      local candidate = remote .. "/" .. name
      if git.rev_parse(repo, candidate) then
        return candidate
      end
    end
  end

  return nil
end

---@param entries difit.FileEntry[]
---@return table<string, difit.FileEntry>
local function index_by_path(entries)
  local map = {}
  for _, entry in ipairs(entries) do
    map[entry.path] = entry
  end
  return map
end

--- Call every subscriber. Errors from one subscriber must not stop the others (a
--- crashing render callback shouldn't corrupt session state or hide other subscribers'
--- updates).
function Session:_notify()
  for _, fn in ipairs(self._subscribers) do
    pcall(fn)
  end
end

---@param opts difit.SessionOpts
---@return difit.Session|nil, string|nil err
function M.new(opts)
  opts = opts or {}

  if type(opts.view_factory) ~= "function" then
    return nil, "difit.session.new: opts.view_factory is required"
  end
  local github = opts.github or default_github

  -- 1. Repo identity, scoped to the current working directory (SessionOpts has no
  -- explicit cwd/repo override -- callers `cd` into the repo they want to review).
  local repo, repo_err = git.repo_identity(vim.fn.getcwd())
  if not repo then
    return nil, repo_err
  end

  -- `detect_pr` is always attempted (not only when base/config stay silent): per
  -- design.md, the PR is a metadata source for *two independent* things -- the base
  -- branch (only used as a fallback below) and the review key (used whenever a PR
  -- exists for the current branch, regardless of which base ultimately won).
  local pr_info = github.detect_pr(repo)

  -- No PR was detected *and* `gh` itself isn't on PATH: the review key is about to fall
  -- back to the branch-pair space silently, which design.md promises a one-time notice
  -- about (so users understand why viewed state won't follow them into a PR-keyed space
  -- later). Deliberately NOT triggered when `gh` works fine but this branch just has no
  -- open PR -- that's an entirely normal, silent case.
  if not pr_info and not github.available() and not gh_missing_notified then
    gh_missing_notified = true
    vim.notify("difit: gh not found; viewed state is keyed by branch pair", vim.log.levels.INFO)
  end

  -- 2. Base resolution: arg > config > detected PR's base > repo default.
  local base_name = opts.base
    or config.get().base
    or (pr_info and pr_info.base_ref)
    or git.default_branch(repo)
  if not base_name then
    return nil, "difit: could not resolve a base branch (no arg, config, PR, or default branch)"
  end

  local base_ref = resolve_ref(repo, base_name)
  if not base_ref then
    return nil,
      string.format(
        "difit: base ref %q does not resolve (tried it, origin/%s, and every other remote's %s)",
        base_name,
        base_name,
        base_name
      )
  end

  -- 3. merge-base(base, HEAD) -- the left side of every diff (three-dot semantics).
  local merge_base, merge_base_err = git.merge_base(repo, base_ref, "HEAD")
  if not merge_base then
    return nil, merge_base_err
  end

  -- 4. Review key: PR detected -> keyed by PR number; otherwise by the branch pair.
  ---@type difit.ReviewKey
  local review_key
  if pr_info then
    review_key = { kind = "pr", repo = repo.id, pr_number = pr_info.number }
  else
    review_key = {
      kind = "branch",
      repo = repo.id,
      base = short_name(base_ref),
      head = git.current_branch(repo) or "HEAD",
    }
  end

  local right = opts.right or config.get().right

  ---@type difit.DiffSpec
  local spec = {
    repo = repo,
    base_ref = base_ref,
    merge_base = merge_base,
    right = right,
    review_key = review_key,
  }

  -- 5. Viewed state + the file list itself.
  local entries, entries_err =
    git.diff_files(repo, merge_base, right, { include_untracked = config.get().include_untracked })
  if not entries then
    return nil, entries_err
  end

  local review_state = state.load(review_key)

  local self = setmetatable({
    spec = spec,
    entries = entries,
    _entries_by_path = index_by_path(entries),
    state = review_state,
    mode = "sidebyside",
    current_path = nil,
    _view_factory = opts.view_factory,
    _subscribers = {},
  }, Session)
  self._view = self._view_factory(self.mode)

  return self
end

--- Recompute the merge-base and entry list against the same `base_ref` (e.g. after new
--- commits land on either side) and notify subscribers so panels/views can redraw. Also
--- keeps whatever the view is currently showing in sync: an open `current_path` gets
--- reopened through the view with its fresh entry (so e.g. an already-open unified
--- buffer picks up the new hunks instead of showing a stale diff), or -- if the file
--- disappeared from the diff entirely -- `current_path` is cleared instead of leaving a
--- diff open for a file that's no longer part of the review.
function Session:refresh()
  local merge_base, err = git.merge_base(self.spec.repo, self.spec.base_ref, "HEAD")
  if merge_base then
    local entries = git.diff_files(
      self.spec.repo,
      merge_base,
      self.spec.right,
      { include_untracked = config.get().include_untracked }
    )
    if entries then
      self.spec.merge_base = merge_base
      self.entries = entries
      self._entries_by_path = index_by_path(entries)

      if self.current_path then
        local entry = self._entries_by_path[self.current_path]
        if entry then
          self._view:open(entry, self.spec)
        else
          self.current_path = nil
        end
      end
    end
  end
  self:_notify()
end

--- Register a callback invoked after refresh/toggle/mode-change. There is no
--- unsubscribe: subscribers are expected to live exactly as long as the session (the
--- panel/view they render into is torn down together with it).
---@param fn fun()
function Session:subscribe(fn)
  table.insert(self._subscribers, fn)
end

--- Open `path` in the current view. A no-op when `path` isn't among `self.entries`
--- (e.g. a stale panel row after a refresh dropped the file).
---@param path string
function Session:open_file(path)
  local entry = self._entries_by_path[path]
  if not entry then
    return
  end
  self.current_path = path
  self._view:open(entry, self.spec)
end

--- Toggle `path`'s viewed mark, persist it, and notify subscribers.
---@param path string
---@return boolean new_value
function Session:toggle_viewed(path)
  local entry = self._entries_by_path[path]
  if not entry then
    return false
  end

  local new_value = not state.is_viewed(self.state, entry)
  if new_value then
    state.mark(self.state, entry)
  else
    state.unmark(self.state, entry.path)
  end
  state.save(self.state)

  self:_notify()
  return new_value
end

---@param path string
---@return boolean
function Session:is_viewed(path)
  local entry = self._entries_by_path[path]
  if not entry then
    return false
  end
  return state.is_viewed(self.state, entry)
end

--- Tri-state bulk toggle over `paths`, shared by `sweep_patterns()` and the panel's
--- subtree `V` key: if at least one of `paths` is currently un-viewed, mark every un-viewed
--- one of them; if they are ALL already viewed, unmark them all instead -- so repeatedly
--- invoking the same batch (same glob patterns, same subtree) is a clean toggle rather than
--- a one-way ratchet. Persists with exactly ONE `state.save` and notifies subscribers
--- exactly once, regardless of how many files moved -- callers batching many files at once
--- must not thrash disk/UI once per file the way `toggle_viewed` does for a single file.
--- `paths` entries absent from `self.entries` (stale caller-side data) are silently
--- ignored, mirroring `toggle_viewed`'s own no-op-on-unknown-path behavior.
---@param paths string[]
---@return {marked: integer, unmarked: integer, matched: integer}
function Session:toggle_viewed_batch(paths)
  local entries = {}
  for _, path in ipairs(paths) do
    local entry = self._entries_by_path[path]
    if entry then
      table.insert(entries, entry)
    end
  end
  if #entries == 0 then
    return { marked = 0, unmarked = 0, matched = 0 }
  end

  local any_unviewed = false
  for _, entry in ipairs(entries) do
    if not state.is_viewed(self.state, entry) then
      any_unviewed = true
      break
    end
  end

  local marked, unmarked = 0, 0
  if any_unviewed then
    for _, entry in ipairs(entries) do
      if not state.is_viewed(self.state, entry) then
        state.mark(self.state, entry)
        marked = marked + 1
      end
    end
  else
    for _, entry in ipairs(entries) do
      state.unmark(self.state, entry.path)
      unmarked = unmarked + 1
    end
  end

  state.save(self.state)
  self:_notify()

  return { marked = marked, unmarked = unmarked, matched = #entries }
end

---@class difit.PatternGroupInfo : difit.PatternGroup
---@field matched string[]  -- self.entries' paths matching this group, in entries order
---@field unviewed integer  -- how many of `matched` are currently un-viewed

--- `config.get().viewed_patterns`, normalized into named groups (see
--- `config.normalize_pattern_groups`) and resolved against `self.entries` -- the single
--- source both a group-picking menu (which group, and how many files/how many un-viewed,
--- to show per choice) and `sweep_patterns` (actually sweeping one) read from, so a menu's
--- counts and the batch a sweep performs can never drift apart. An entry matches a group
--- when ANY of that group's patterns matches it (see `compile_pattern`); invalid patterns
--- are skipped within their group (warned once, see `bad_pattern_notified`) rather than
--- failing the whole group.
---@return difit.PatternGroupInfo[]
function Session:pattern_groups()
  local groups = config.normalize_pattern_groups(config.get().viewed_patterns or {})

  local result = {}
  for _, group in ipairs(groups) do
    local matchers = {}
    for _, pattern in ipairs(group.patterns) do
      local matcher = compile_pattern(pattern)
      if matcher then
        table.insert(matchers, matcher)
      end
    end

    local matched = {}
    local unviewed = 0
    for _, entry in ipairs(self.entries) do
      for _, matcher in ipairs(matchers) do
        if matcher(entry.path) then
          table.insert(matched, entry.path)
          if not state.is_viewed(self.state, entry) then
            unviewed = unviewed + 1
          end
          break
        end
      end
    end

    table.insert(
      result,
      { name = group.name, patterns = group.patterns, matched = matched, unviewed = unviewed }
    )
  end

  return result
end

--- Sweep either ONE named group (`group_name` matched EXACTLY against a
--- `pattern_groups()` entry's `name` -- prefix resolution, if any, is a UI-level concern;
--- see `init.lua`'s `:Difit sweep {name}` handling) or, when `group_name` is nil, the
--- UNION of every group's matched paths (a file matched by more than one group is only
--- toggled once) -- the pre-groups `sweep_patterns()` behavior, preserved as the
--- no-argument case so existing single-list `viewed_patterns` configs keep working
--- unchanged. Either way, delegates the actual mark/unmark/save/notify work to
--- `toggle_viewed_batch` (see its own docs for the tri-state rule and the single-save/
--- single-notify guarantee).
---@param group_name string?
---@return {marked: integer, unmarked: integer, matched: integer}|nil result
---@return string scope_or_err  -- on success: the resolved scope name ("all groups", or
---  `group_name` itself) for callers' notifications; on failure (unknown `group_name`,
---  `result` is nil): a ready-to-notify error message
function Session:sweep_patterns(group_name)
  local groups = self:pattern_groups()

  if group_name == nil then
    local paths, seen = {}, {}
    for _, group in ipairs(groups) do
      for _, path in ipairs(group.matched) do
        if not seen[path] then
          seen[path] = true
          table.insert(paths, path)
        end
      end
    end
    return self:toggle_viewed_batch(paths), "all groups"
  end

  for _, group in ipairs(groups) do
    if group.name == group_name then
      return self:toggle_viewed_batch(group.matched), group.name
    end
  end

  return nil, string.format("difit: unknown pattern group %q", group_name)
end

--- `tree.file_order(tree.build(self.entries))`, the single source every navigation
--- method below walks. Computed fresh on every call rather than cached: `self.entries`
--- only ever changes via `refresh()` (rare, user-triggered), and every caller here already
--- tolerates a stale `after_path`/`before_path` that no longer appears in the current
--- order (falls back to "from the start/end" -- see `next_file`/`prev_file`), so there is
--- no correctness reason to cache it, only a marginal one.
---@param self difit.Session
---@return string[]
local function file_order(self)
  return tree.file_order(tree.build(self.entries))
end

--- Next un-viewed file after `after_path`, in `tree.file_order` order, wrapping around
--- once. Returns nil when there are no entries, or every entry is already viewed.
---@param after_path string?
---@return string|nil
function Session:next_unviewed(after_path)
  local order = file_order(self)
  local n = #order
  if n == 0 then
    return nil
  end

  local start_idx = 0
  if after_path then
    for i, path in ipairs(order) do
      if path == after_path then
        start_idx = i
        break
      end
    end
  end

  for offset = 1, n do
    local idx = ((start_idx + offset - 1) % n) + 1
    local path = order[idx]
    if not self:is_viewed(path) then
      return path
    end
  end
  return nil
end

--- Next file after `after_path`, in `tree.file_order` order (same source as
--- `next_unviewed`), wrapping around once -- unlike `next_unviewed`, viewed files are
--- included: this backs plain `]f`-style navigation ("show me the next file"), not "find
--- something left to review". `after_path == nil` -- or a path no longer among
--- `self.entries`, e.g. a stale reference after a `refresh()` dropped it -- means "from
--- the start". Returns nil when there are no files.
---@param after_path string?
---@return string|nil
function Session:next_file(after_path)
  local order = file_order(self)
  local n = #order
  if n == 0 then
    return nil
  end

  local start_idx = 0
  if after_path then
    for i, path in ipairs(order) do
      if path == after_path then
        start_idx = i
        break
      end
    end
  end

  return order[(start_idx % n) + 1]
end

--- Previous file before `before_path`, mirroring `next_file` in the opposite direction.
--- `before_path == nil` (or not found) means "from the end". Returns nil when there are
--- no files.
---@param before_path string?
---@return string|nil
function Session:prev_file(before_path)
  local order = file_order(self)
  local n = #order
  if n == 0 then
    return nil
  end

  local start_idx = n + 1
  if before_path then
    for i, path in ipairs(order) do
      if path == before_path then
        start_idx = i
        break
      end
    end
  end

  return order[((start_idx - 2) % n) + 1]
end

---@return {viewed: integer, total: integer}
function Session:progress()
  local viewed = 0
  for _, entry in ipairs(self.entries) do
    if state.is_viewed(self.state, entry) then
      viewed = viewed + 1
    end
  end
  return { viewed = viewed, total = #self.entries }
end

--- Switch view modes: build the new view via the injected factory and reopen
--- `current_path` (if any) through it BEFORE closing the outgoing view (docs/
--- refactor-v1.md R2, diffview's `StandardView:use_entry` order) -- so the replacement
--- windows exist before the old ones ever disappear, instead of the diff area flashing
--- empty (or vanishing entirely) in between.
---@param mode "sidebyside"|"unified"
function Session:set_mode(mode)
  local old_view = self._view
  self.mode = mode
  self._view = self._view_factory(mode)

  if self.current_path then
    local entry = self._entries_by_path[self.current_path]
    if entry then
      self._view:open(entry, self.spec)
    end
  end

  old_view:close()

  self:_notify()
end

function Session:close()
  self._view:close()
  state.save(self.state)
end

return M
