-- Session orchestration core (WP-E). This module owns the git/state plumbing that
-- turns a working directory into a `diffly.DiffSpec` + file list + viewed-state, and
-- exposes the operations a UI drives a review with. It has no UI of its own: renders
-- happen through subscriber callbacks and an injected view factory (see
-- `diffly.SessionOpts.view_factory`), so this module is fully testable without any
-- `lua/diffly/ui/*` dependency, and the real factories are wired up by WP-I.

local comments = require("diffly.comments")
local config = require("diffly.config")
local git = require("diffly.git")
local state = require("diffly.state")
local tree = require("diffly.tree")

-- Loaded once at require-time; `opts.github` (tests, mainly) overrides this per call
-- without needing to touch the module cache.
local default_github = require("diffly.github")

local M = {}

---@class diffly.Session
---@field spec diffly.DiffSpec
---@field entries diffly.FileEntry[]
---@field state diffly.ReviewState
---@field mode "sidebyside"|"unified"
---@field current_path string?
---@field comments_collapsed boolean -- session-wide runtime flag (never persisted)
---@field pr diffly.PrInfo? -- the detected PR, when any; what the overlay/submission target
---@field remote_threads table<string, diffly.RemoteThread[]> -- the read-only overlay
--- layer, session-held ONLY (never persisted into ReviewState); path-keyed like comments
---@field show_resolved_remote boolean -- session-wide runtime flag (never persisted)
local Session = {}
Session.__index = Session

-- This notice is meant to fire once per Neovim *session* (i.e. process lifetime), not
-- once per `diffly.Session` instance -- a plain module-level flag survives across
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
          "diffly: ignoring invalid viewed_patterns entry %q (%s)",
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
---@param repo diffly.RepoIdentity
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

---@param entries diffly.FileEntry[]
---@return table<string, diffly.FileEntry>
local function index_by_path(entries)
  local map = {}
  for _, entry in ipairs(entries) do
    map[entry.path] = entry
  end
  return map
end

--- Batched `git check-attr linguist-generated` over every entry's path (`ui/guard.lua`'s
--- `M.is_generated` reads the result per-entry, at `open()` time) -- ONE subprocess call
--- per session build/`refresh()`, never per file/per open (docs/architecture.md
--- "Rendering"'s "never add a subprocess call for files nobody opened" rule extends here:
--- since EVERY entry's row/±counts already render in the panel regardless of whether its
--- diff is ever opened, batching over the whole entry list up front is the cheap choice --
--- one process per refresh beats a `git check-attr` per `open()` call for reviews with many
--- open/close cycles over the same file). Skipped entirely (empty table, no subprocess)
--- when `config.collapse_generated` is off.
---@param repo diffly.RepoIdentity
---@param entries diffly.FileEntry[]
---@return table<string, string>
local function load_generated_attrs(repo, entries)
  if not config.get().collapse_generated then
    return {}
  end
  local paths = {}
  for _, e in ipairs(entries) do
    table.insert(paths, e.path)
  end
  return git.check_attrs(repo, "linguist-generated", paths) or {}
end

--- Re-anchor every persisted comment against the current entry list -- the ONLY place
--- anchors are ever rewritten (render code never writes state; see docs/architecture.md).
--- Returns whether anything moved or expired, so callers persist exactly once and only
--- when needed.
---
--- Cost discipline: a side's content is loaded at most once per (path, side), and only
--- when at least one of its threads' anchor sha differs from the entry's current side
--- sha -- the steady-state refresh (nothing changed) does zero I/O here. Paths with no
--- live entry (the file left the diff) are left untouched: there is nothing current to
--- verify against, and expiring or dropping them would destroy user text over a
--- transient state (e.g. a temporarily reverted worktree).
---@param self diffly.Session
---@return boolean dirty
local function reanchor_comments(self)
  local dirty = false
  for path, threads in pairs(self.state.comments) do
    local entry = self._entries_by_path[path]
    if entry then
      for _, side in ipairs({ "base", "head" }) do
        -- NOT `side == "base" and entry.base_sha or entry.head_sha`: a nil base_sha
        -- (added file) would fall through the `or` to the HEAD sha.
        local current_sha
        if side == "base" then
          current_sha = entry.base_sha
        else
          current_sha = entry.head_sha
        end

        local side_threads = {}
        for _, thread in ipairs(threads) do
          if thread.anchor.side == side then
            table.insert(side_threads, thread)
          end
        end

        if not current_sha then
          -- The side has no content anymore (e.g. head side of a now-deleted file):
          -- nothing to search, so the threads are outdated by definition.
          for _, thread in ipairs(side_threads) do
            if not thread.anchor.outdated then
              thread.anchor.outdated = true
              dirty = true
            end
          end
        else
          local needs_content = false
          for _, thread in ipairs(side_threads) do
            if thread.anchor.sha ~= current_sha then
              needs_content = true
              break
            end
          end

          if needs_content then
            -- Base blobs and head-mode right sides are immutable objects; the worktree
            -- right side is read straight from disk.
            local locator
            if side == "base" or self.spec.right == "head" then
              locator = { sha = current_sha }
            else
              locator = { path = path }
            end
            local lines = git.file_content(self.spec.repo, locator)
            if lines then
              for _, thread in ipairs(side_threads) do
                local resolution = comments.resolve(thread, current_sha, lines)
                if comments.apply_resolution(thread, resolution) then
                  dirty = true
                end
              end
            end
          end
        end
      end
    end
  end
  return dirty
end

--- Call every subscriber. Errors from one subscriber must not stop the others (a
--- crashing render callback shouldn't corrupt session state or hide other subscribers'
--- updates).
function Session:_notify()
  for _, fn in ipairs(self._subscribers) do
    pcall(fn)
  end
end

---@param opts diffly.SessionOpts
---@return diffly.Session|nil, string|nil err
function M.new(opts)
  opts = opts or {}

  if type(opts.view_factory) ~= "function" then
    return nil, "diffly.session.new: opts.view_factory is required"
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
    vim.notify("diffly: gh not found; viewed state is keyed by branch pair", vim.log.levels.INFO)
  end

  -- 2. Base resolution: arg > config > detected PR's base > repo default.
  local base_name = opts.base
    or config.get().base
    or (pr_info and pr_info.base_ref)
    or git.default_branch(repo)
  if not base_name then
    return nil, "diffly: could not resolve a base branch (no arg, config, PR, or default branch)"
  end

  local base_ref = resolve_ref(repo, base_name)
  if not base_ref then
    return nil,
      string.format(
        "diffly: base ref %q does not resolve (tried it, origin/%s, and every other remote's %s)",
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
  ---@type diffly.ReviewKey
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

  -- 5. The file list itself -- fetched before `spec` so `spec.generated_attrs` (the
  -- batched `git check-attr` result, see `load_generated_attrs`) can be filled in as part
  -- of building `spec` rather than mutated in right after.
  local entries, entries_err =
    git.diff_files(repo, merge_base, right, { include_untracked = config.get().include_untracked })
  if not entries then
    return nil, entries_err
  end

  ---@type diffly.DiffSpec
  local spec = {
    repo = repo,
    base_ref = base_ref,
    merge_base = merge_base,
    right = right,
    review_key = review_key,
    generated_attrs = load_generated_attrs(repo, entries),
  }

  -- 6. Viewed state.
  local review_state = state.load(review_key)

  -- 6b. Draft adoption (docs/design.md "Comments"): comments written before the PR
  -- existed live under the branch-pair key; the moment the review is PR-keyed, they
  -- follow -- drafts are user text and must never silently strand. One-way and naturally
  -- once (the branch store is emptied); viewed marks deliberately stay behind (the two
  -- keyspaces never mix for them, per the original v1 decision).
  if review_key.kind == "pr" then
    local branch_key = {
      kind = "branch",
      repo = repo.id,
      base = short_name(base_ref),
      head = git.current_branch(repo) or "HEAD",
    }
    local branch_state = state.load(branch_key)
    if next(branch_state.comments) ~= nil then
      local adopted = comments.adopt(branch_state, review_state)
      if adopted > 0 then
        state.save(branch_state)
        state.save(review_state)
        vim.notify(
          string.format("diffly: adopted %d comment draft(s) from the branch review", adopted),
          vim.log.levels.INFO
        )
      end
    end
  end

  local self = setmetatable({
    spec = spec,
    entries = entries,
    _entries_by_path = index_by_path(entries),
    state = review_state,
    mode = "sidebyside",
    current_path = nil,
    comments_collapsed = false,
    pr = pr_info,
    remote_threads = {},
    show_resolved_remote = false,
    _view_factory = opts.view_factory,
    _subscribers = {},
  }, Session)
  self._view = self._view_factory(self.mode)

  -- Catch comment drift since the last session (the file changed while nothing was
  -- watching); dirty-flag save keeps the no-drift open from writing anything.
  if reanchor_comments(self) then
    state.save(self.state)
  end

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
      self.spec.generated_attrs = load_generated_attrs(self.spec.repo, entries)
      self.entries = entries
      self._entries_by_path = index_by_path(entries)

      -- Re-anchor BEFORE reopening current_path below, so the reopened view already
      -- renders fresh comment positions.
      if reanchor_comments(self) then
        state.save(self.state)
      end

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
--- (e.g. a stale panel row after a refresh dropped the file). Notifies subscribers only
--- when `current_path` actually CHANGES -- the panel's current-file row highlight
--- (ui/panel.lua's `Panel:render`, keyed off `session.current_path`) would otherwise keep
--- pointing at the previously open file after `]f`/`[f`/`<CR>`/auto-advance, since none of
--- those go through `toggle_viewed`/`refresh`/`set_mode` (the only other notifying calls).
--- Reopening the SAME path (e.g. a stale `<CR>` on the row already open) must not notify
--- again -- that would re-render the panel for no visible change.
---@param path string
function Session:open_file(path)
  local entry = self._entries_by_path[path]
  if not entry then
    return
  end
  local changed = self.current_path ~= path
  self.current_path = path
  self._view:open(entry, self.spec)
  if changed then
    self:_notify()
  end
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

--- Repaint just the comment layer of whatever the view currently shows. Comment
--- mutations must NOT go through `open_file`/`View:open` -- reopening runs the view's
--- cursor placement (`]c`-style jumps) and would yank the cursor away right after the
--- user typed a comment. `refresh_comments` is an OPTIONAL View-contract method: fake
--- views in session tests implement it, placeholder-only flows may not.
function Session:_refresh_comment_render()
  if self._view.refresh_comments then
    self._view:refresh_comments()
  end
end

---@class diffly.session.CommentOpts
---@field side "base"|"head"
---@field start_line integer
---@field end_line integer
---@field body string
---@field snapshot string[]  -- the commented lines' text, captured by the caller from
--- the buffer the user was looking at when the comment was written

--- Create a comment thread on `path`. The anchor's sha is filled in here from the
--- entry's current side -- callers never handle shas. Mutation discipline (shared by
--- update/delete below, mirroring `toggle_viewed`): mutate, ONE `state.save`, repaint
--- the comment layer, ONE subscriber notify.
---@param path string
---@param opts diffly.session.CommentOpts
---@return diffly.CommentThread|nil, string|nil err
function Session:add_comment(path, opts)
  local entry = self._entries_by_path[path]
  if not entry then
    return nil, string.format("diffly: %s is not part of this review", path)
  end

  -- NOT the `and-or` idiom: a nil base_sha (added file) must stay nil, not fall through
  -- to the head sha.
  local sha
  if opts.side == "base" then
    sha = entry.base_sha
  else
    sha = entry.head_sha
  end
  if not sha then
    return nil, string.format("diffly: %s has no %s-side content to comment on", path, opts.side)
  end

  local thread = comments.add(self.state, {
    path = path,
    side = opts.side,
    start_line = opts.start_line,
    end_line = opts.end_line,
    body = opts.body,
    sha = sha,
    snapshot = opts.snapshot,
  })
  state.save(self.state)
  self:_refresh_comment_render()
  self:_notify()
  return thread, nil
end

---@param path string
---@param id string
---@param body string
---@return diffly.CommentThread|nil @nil (and no save/notify) when no such thread exists
function Session:update_comment(path, id, body)
  local thread = comments.update(self.state, path, id, body)
  if not thread then
    return nil
  end
  state.save(self.state)
  self:_refresh_comment_render()
  self:_notify()
  return thread
end

---@param path string
---@param id string
---@return boolean deleted
function Session:delete_comment(path, id)
  if not comments.delete(self.state, path, id) then
    return false
  end
  state.save(self.state)
  self:_refresh_comment_render()
  self:_notify()
  return true
end

---@param path string
---@return diffly.CommentThread[]
function Session:comments_for(path)
  return comments.list(self.state, path)
end

---@return diffly.CommentThread[]
function Session:all_comments()
  return comments.list_all(self.state)
end

--- Thread count for a path: local drafts (outdated included -- the panel indicator is
--- the discoverability channel for comments that no longer render inline) plus
--- UNRESOLVED remote threads. Deliberately independent of the resolved toggle, so the
--- panel number never jumps just because someone peeked at resolved conversations.
---@param path string
---@return integer
function Session:comment_count(path)
  local count = #comments.list(self.state, path)
  for _, thread in ipairs(self.remote_threads[path] or {}) do
    if not thread.resolved then
      count = count + 1
    end
  end
  return count
end

--- Session-wide collapse toggle for inline comment rendering. A runtime flag, not
--- persisted -- like the panel's hide-viewed filter, it describes how this session is
--- being looked at, not review data.
function Session:toggle_comments_collapsed()
  self.comments_collapsed = not self.comments_collapsed
  self:_refresh_comment_render()
  self:_notify()
end

--- Replace the read-only remote overlay layer with a fresh fetch result. Remote threads
--- live ONLY here -- never in `self.state` (the persisted ReviewState is local-draft
--- data; the forge already stores its own threads). Repaints the comment layer and
--- notifies once (the panel's per-file counts include remote threads).
---@param by_path table<string, diffly.RemoteThread[]>
function Session:set_remote_threads(by_path)
  self.remote_threads = by_path
  self:_refresh_comment_render()
  self:_notify()
end

--- Assemble everything `comments.plan_submission` needs and run it: the git-owning half
--- of `:Diffly submit` (the decision logic stays pure in comments.lua). The PR's diff is
--- `merge_base..HEAD` -- committed content only, untracked files excluded -- which is
--- exactly what the forge will diff too, PROVIDED local HEAD is the PR head: submitting
--- a review against anything else would comment on code the PR doesn't show, so that
--- mismatch aborts.
---@return diffly.SubmissionPlan|nil plan, string|nil err
function Session:prepare_submission()
  if not self.pr or not self.pr.head_oid then
    return nil, "diffly: this review has no PR (or gh did not report its head); cannot submit"
  end
  local head = git.rev_parse(self.spec.repo, "HEAD")
  if head ~= self.pr.head_oid then
    return nil,
      string.format(
        "diffly: local HEAD is not the PR head (%s); push, pull, or `gh pr checkout` first",
        self.pr.head_oid:sub(1, 7)
      )
  end

  local pr_entries, err =
    git.diff_files(self.spec.repo, self.spec.merge_base, "head", { include_untracked = false })
  if not pr_entries then
    return nil, err
  end
  local pr_by_path = index_by_path(pr_entries)

  ---@type table<string, diffly.SubmitCtx>
  local ctx_by_path = {}
  for path in pairs(self.state.comments) do
    local entry = pr_by_path[path]
    if entry then
      local hunks = git.hunks(self.spec.repo, entry, self.spec.merge_base, "head")
      local head_lines = entry.head_sha
          and git.file_content(self.spec.repo, { sha = entry.head_sha })
        or nil
      ctx_by_path[path] = {
        in_pr = true,
        head_sha = entry.head_sha,
        head_lines = head_lines,
        line_sets = comments.hunk_line_sets(hunks or {}),
      }
    end
    -- No entry: the path isn't in the PR diff; plan_submission's missing-ctx branch
    -- reports it.
  end

  return comments.plan_submission(self:all_comments(), ctx_by_path), nil
end

--- Post-submit cleanup: drop every submitted draft from the local store -- they live on
--- the forge now and reappear through the overlay refetch, so keeping them would render
--- everything twice. Batch discipline: ONE save, one comment repaint, ONE notify.
---@param items { thread: diffly.CommentThread, payload: diffly.ReviewCommentPayload }[]
function Session:remove_submitted(items)
  if #items == 0 then
    return
  end
  for _, item in ipairs(items) do
    comments.delete(self.state, item.thread.path, item.thread.id)
  end
  state.save(self.state)
  self:_refresh_comment_render()
  self:_notify()
end

--- Session-wide toggle revealing resolved remote threads (hidden by default: a resolved
--- conversation is finished business). Runtime flag, same family as
--- `toggle_comments_collapsed`.
function Session:toggle_remote_resolved()
  self.show_resolved_remote = not self.show_resolved_remote
  self:_refresh_comment_render()
  self:_notify()
end

--- Whether a remote thread is currently displayable (resolved ones only behind the
--- toggle). Outdated-ness is NOT a display concern here -- inline placement already
--- skips outdated anchors, and lists deliberately include them.
---@param self diffly.Session
---@param thread diffly.RemoteThread
---@return boolean
local function remote_shown(self, thread)
  return not thread.resolved or self.show_resolved_remote
end

--- THE render feed: local drafts first, then the displayable remote threads. The views'
--- `comments_for` getter points here, so both layers render through the identical
--- placement pipeline -- while `find_at`/edit/delete keep reading `state.comments`
--- directly, which is what makes remote threads read-only by construction.
---@param path string
---@return (diffly.CommentThread|diffly.RemoteThread)[]
function Session:threads_for_render(path)
  local result = comments.list(self.state, path)
  for _, thread in ipairs(self.remote_threads[path] or {}) do
    if remote_shown(self, thread) then
      table.insert(result, thread)
    end
  end
  return result
end

--- Flat, (path, start_line)-ordered list of displayable remote threads -- the quickfix
--- merge source. Outdated threads ARE included: `:Diffly comments` is their
--- discoverability channel, exactly like local outdated drafts.
---@return diffly.RemoteThread[]
function Session:remote_thread_list()
  local result = {}
  for _, threads in pairs(self.remote_threads) do
    for _, thread in ipairs(threads) do
      if remote_shown(self, thread) then
        table.insert(result, thread)
      end
    end
  end
  table.sort(result, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.anchor.start_line < b.anchor.start_line
  end)
  return result
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

---@class diffly.PatternGroupInfo : diffly.PatternGroup
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
---@return diffly.PatternGroupInfo[]
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
--- see `init.lua`'s `:Diffly sweep {name}` handling) or, when `group_name` is nil, the
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

  return nil, string.format("diffly: unknown pattern group %q", group_name)
end

--- `tree.file_order(tree.build(self.entries))`, the single source every navigation
--- method below walks. Computed fresh on every call rather than cached: `self.entries`
--- only ever changes via `refresh()` (rare, user-triggered), and every caller here already
--- tolerates a stale `after_path`/`before_path` that no longer appears in the current
--- order (falls back to "from the start/end" -- see `next_file`/`prev_file`), so there is
--- no correctness reason to cache it, only a marginal one.
---@param self diffly.Session
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
--- `current_path` (if any) through it BEFORE closing the outgoing view (mirrors
--- diffview's `StandardView:use_entry` order; see docs/architecture.md's "View contract"
--- section) -- so the replacement windows exist before the old ones ever disappear,
--- instead of the diff area flashing empty (or vanishing entirely) in between.
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
