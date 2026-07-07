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

--- Review keys/UI store the short branch name ("main"), never the resolved
--- remote-tracking ref ("origin/main") `resolve_ref` may have needed internally.
---@param ref string
---@return string
local function short_name(ref)
  return ref:match("^origin/(.+)$") or ref
end

--- Resolve `name` to a ref `git rev-parse` accepts, trying the bare name first and
--- falling back to its `origin/`-prefixed remote-tracking form (e.g. a PR's
--- `baseRefName` or a config override is usually a short name like "main", which only
--- exists locally as `origin/main` when the branch itself was never checked out).
---@param repo difit.RepoIdentity
---@param name string
---@return string|nil resolved
local function resolve_ref(repo, name)
  if git.rev_parse(repo, name) then
    return name
  end
  local remote = "origin/" .. name
  if git.rev_parse(repo, remote) then
    return remote
  end
  return nil
end

---@param entries difit.FileEntry[]
---@param path string
---@return difit.FileEntry|nil
local function find_entry(entries, path)
  for _, entry in ipairs(entries) do
    if entry.path == path then
      return entry
    end
  end
  return nil
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
        "difit: base ref %q does not resolve (tried it and origin/%s)",
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
--- commits land on either side) and notify subscribers so panels/views can redraw.
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
  local entry = find_entry(self.entries, path)
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
  local entry = find_entry(self.entries, path)
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
  local entry = find_entry(self.entries, path)
  if not entry then
    return false
  end
  return state.is_viewed(self.state, entry)
end

--- Next un-viewed file after `after_path`, in `tree.file_order` order, wrapping around
--- once. Returns nil when there are no entries, or every entry is already viewed.
---@param after_path string?
---@return string|nil
function Session:next_unviewed(after_path)
  local order = tree.file_order(tree.build(self.entries))
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

--- Switch view modes: close the current view, build the new one via the injected
--- factory, and reopen `current_path` (if any) through it.
---@param mode "sidebyside"|"unified"
function Session:set_mode(mode)
  self._view:close()
  self.mode = mode
  self._view = self._view_factory(mode)

  if self.current_path then
    local entry = find_entry(self.entries, self.current_path)
    if entry then
      self._view:open(entry, self.spec)
    end
  end

  self:_notify()
end

function Session:close()
  self._view:close()
  state.save(self.state)
end

return M
