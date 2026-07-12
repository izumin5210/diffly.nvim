-- `gh` CLI wrapper (WP-D) -- the diffly.Provider implementation (see types.lua): PR
-- detection and review-thread fetching, in diffly-neutral vocabulary. GitHub-specific
-- shapes (LEFT/RIGHT sides, GraphQL node fields) never leave this module. PR mode is an
-- optional enhancement over the branch-pair fallback (see docs/design.md), so nothing
-- here may ever raise: every failure path (missing `gh`, non-zero exit, malformed JSON)
-- degrades to `nil, err` instead.

local M = {}

---@return boolean
function M.available()
  return vim.fn.executable("gh") == 1
end

---@class diffly.PrInfo
---@field number integer
---@field base_ref string    -- baseRefName, e.g. "main"
---@field head_oid string?   -- headRefOid; optional (older gh / restricted output), the
--- review-submission commit_id -- submitting aborts with a message when absent
---@field url string?

--- Detect the PR (if any) associated with the current branch via `gh pr view`.
---
--- Never raises: `gh` missing, a non-zero exit (no PR for this branch / not logged in),
--- or output that doesn't parse as the expected JSON shape all yield `nil, err`.
---@param repo diffly.RepoIdentity
---@return diffly.PrInfo|nil, string|nil err
function M.detect_pr(repo)
  if not M.available() then
    return nil, "gh executable not found on PATH"
  end

  -- vim.system() itself raises synchronously if the command can't be spawned at all;
  -- guard against that racing with the availability check above.
  local spawn_ok, res_or_err = pcall(function()
    return vim
      .system(
        { "gh", "pr", "view", "--json", "number,baseRefName,headRefOid,url" },
        { text = true, cwd = repo.toplevel, timeout = 10000 }
      )
      :wait()
  end)
  if not spawn_ok then
    return nil, tostring(res_or_err)
  end

  local res = res_or_err
  if res.code ~= 0 then
    local err = res.stderr and vim.trim(res.stderr) or ""
    if err == "" then
      err = string.format("gh pr view exited with code %d", res.code)
    end
    return nil, err
  end

  local decode_ok, data = pcall(vim.json.decode, res.stdout or "")
  if not decode_ok or type(data) ~= "table" then
    return nil, "failed to parse `gh pr view` output as JSON"
  end

  if type(data.number) ~= "number" or type(data.baseRefName) ~= "string" then
    return nil, "`gh pr view` output missing expected fields"
  end

  ---@type diffly.PrInfo
  local info = {
    number = data.number,
    base_ref = data.baseRefName,
    -- Optional extras (older gh versions / restricted --json fields may omit them):
    -- their absence only disables review submission, never detection itself.
    head_oid = type(data.headRefOid) == "string" and data.headRefOid or nil,
    url = type(data.url) == "string" and data.url or nil,
  }
  return info, nil
end

--- Split a normalized remote-URL repo identity ("github.com/owner/repo") into its
--- GraphQL coordinates. A toplevel-path fallback identity (no remote) doesn't match --
--- callers degrade to "no overlay" rather than guessing.
---@param repo_id string
---@return string|nil host, string|nil owner, string|nil name
local function parse_owner_repo(repo_id)
  return repo_id:match("^([^/]+)/([^/]+)/(.+)$")
end

-- Review threads with everything the overlay needs in one paginated query: resolution/
-- outdated state, live AND original positions (the live `line` is null once a thread is
-- outdated -- the original position is what :Diffly comments lists), the side, and the
-- full message list including replies.
local THREADS_QUERY = [[
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated line originalLine startLine originalStartLine
          diffSide path
          comments(first: 100) { nodes { author { login } body } }
        }
      }
    }
  }
}
]]

--- Translate accumulated GraphQL thread nodes into path-grouped diffly.RemoteThread
--- lists. The ONLY place GitHub review-thread vocabulary is understood.
---@param nodes table[]
---@return table<string, diffly.RemoteThread[]>
local function translate_threads(nodes)
  local by_path = {}
  for _, node in ipairs(nodes) do
    -- An outdated thread's live line is null; fall back to the original (historical)
    -- position so the thread still has SOME location for lists. 1 is the last-resort
    -- clamp for a shape that should not occur.
    local end_line = node.line or node.originalLine or 1
    local start_line = node.startLine or node.originalStartLine or end_line

    local messages = {}
    for _, comment in ipairs(vim.tbl_get(node, "comments", "nodes") or {}) do
      table.insert(messages, {
        -- A deleted account's author is null; GitHub renders those as "ghost".
        author = (type(comment.author) == "table" and comment.author.login) or "ghost",
        body = comment.body or "",
      })
    end

    ---@type diffly.RemoteThread
    local thread = {
      id = node.id,
      path = node.path,
      remote = true,
      resolved = node.isResolved == true,
      anchor = {
        side = node.diffSide == "LEFT" and "base" or "head",
        start_line = start_line,
        end_line = end_line,
        outdated = node.isOutdated == true or nil,
      },
      messages = messages,
    }
    by_path[node.path] = by_path[node.path] or {}
    table.insert(by_path[node.path], thread)
  end
  return by_path
end

--- Fetch every review thread of `pr`, ASYNCHRONOUSLY -- the codebase's one async
--- subprocess pattern (docs/architecture.md): network latency must never block opening a
--- review, unlike the local git plumbing that stays deliberately synchronous.
---
--- Contract:
--- - Synchronous failures (gh missing, unparsable repo identity) return `nil, err` and
---   `on_done` NEVER fires -- callers can degrade immediately.
--- - Otherwise returns a diffly.FetchHandle; `on_done` fires EXACTLY ONCE, always on the
---   main loop (the entire completion is `vim.schedule`d out of vim.system's fast
---   context), with either the path-grouped threads or an error.
--- - `handle.cancel()` kills the in-flight process and suppresses `on_done`.
---@param repo diffly.RepoIdentity
---@param pr diffly.PrInfo
---@param on_done fun(threads_by_path: table<string, diffly.RemoteThread[]>|nil, err: string|nil)
---@return diffly.FetchHandle|nil handle, string|nil err
function M.fetch_threads(repo, pr, on_done)
  if not M.available() then
    return nil, "gh executable not found on PATH"
  end
  local host, owner, name = parse_owner_repo(repo.id)
  if not host then
    return nil, string.format("repo identity %q has no parsable remote host/owner/name", repo.id)
  end

  local state = { cancelled = false, sys = nil }
  local accumulated = {}

  ---@param cursor string?
  ---@return boolean ok, string|nil err
  local function run_page(cursor)
    local cmd = {
      "gh",
      "api",
      "graphql",
      "--hostname",
      host,
      "-f",
      "owner=" .. owner,
      "-f",
      "name=" .. name,
      "-F",
      "number=" .. pr.number,
      "-f",
      "query=" .. THREADS_QUERY,
    }
    if cursor then
      table.insert(cmd, "-f")
      table.insert(cmd, "endCursor=" .. cursor)
    end

    local spawn_ok, sys_or_err = pcall(
      vim.system,
      cmd,
      { text = true, cwd = repo.toplevel, timeout = 30000 },
      function(res)
        -- vim.system completion runs in a fast context; scheduling the WHOLE body
        -- sidesteps every "is this API fast-safe" question.
        vim.schedule(function()
          if state.cancelled then
            return
          end
          state.sys = nil

          if res.code ~= 0 then
            local err = res.stderr and vim.trim(res.stderr) or ""
            if err == "" then
              err = string.format("gh api graphql exited with code %d", res.code)
            end
            on_done(nil, err)
            return
          end

          local ok, data = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true } })
          local threads = ok
            and type(data) == "table"
            and vim.tbl_get(data, "data", "repository", "pullRequest", "reviewThreads")
          if type(threads) ~= "table" or type(threads.nodes) ~= "table" then
            on_done(nil, "failed to parse `gh api graphql` review-thread output")
            return
          end

          vim.list_extend(accumulated, threads.nodes)

          local page = threads.pageInfo
          if type(page) == "table" and page.hasNextPage and type(page.endCursor) == "string" then
            local ok2, err2 = run_page(page.endCursor)
            if not ok2 then
              -- A follow-up page failing to even spawn can't propagate synchronously
              -- anymore; it becomes a completion error like any other.
              on_done(nil, err2)
            end
          else
            on_done(translate_threads(accumulated), nil)
          end
        end)
      end
    )
    if not spawn_ok then
      return false, tostring(sys_or_err)
    end
    state.sys = sys_or_err
    return true, nil
  end

  local ok, err = run_page(nil)
  if not ok then
    return nil, err
  end

  ---@type diffly.FetchHandle
  return {
    cancel = function()
      state.cancelled = true
      if state.sys then
        pcall(state.sys.kill, state.sys, 9)
        state.sys = nil
      end
    end,
  },
    nil
end

--- Submit one review -- SYNCHRONOUSLY (`:wait()`): unlike the background overlay fetch,
--- a submit is an explicit user action awaiting its outcome, and the one async pattern
--- stays reserved for `fetch_threads`. The payload's diffly-neutral sides translate to
--- forge vocabulary here, at the last moment; single-line comments must not carry range
--- fields (the forge rejects `start_line == line`), which `plan_submission` already
--- guarantees by omission. Errors surface with gh's stderr verbatim, so a 422's "line
--- must be part of the diff" reaches the user unedited.
---@param repo diffly.RepoIdentity
---@param pr diffly.PrInfo
---@param submission diffly.ReviewSubmission
---@return boolean|nil ok, string|nil err
function M.submit_review(repo, pr, submission)
  if not M.available() then
    return nil, "gh executable not found on PATH"
  end
  local host, owner, name = parse_owner_repo(repo.id)
  if not host then
    return nil, string.format("repo identity %q has no parsable remote host/owner/name", repo.id)
  end

  local comments_payload = {}
  for _, comment in ipairs(submission.comments) do
    local side = comment.side == "base" and "LEFT" or "RIGHT"
    table.insert(comments_payload, {
      path = comment.path,
      side = side,
      line = comment.line,
      start_line = comment.start_line,
      start_side = comment.start_line and side or nil,
      body = comment.body,
    })
  end
  local payload = {
    commit_id = submission.commit_id,
    event = submission.event,
    body = submission.body ~= "" and submission.body or nil,
    comments = comments_payload,
  }

  local spawn_ok, res_or_err = pcall(function()
    return vim
      .system({
        "gh",
        "api",
        "--hostname",
        host,
        string.format("repos/%s/%s/pulls/%d/reviews", owner, name, pr.number),
        "--input",
        "-",
      }, {
        text = true,
        cwd = repo.toplevel,
        stdin = vim.json.encode(payload),
        timeout = 30000,
      })
      :wait()
  end)
  if not spawn_ok then
    return nil, tostring(res_or_err)
  end

  local res = res_or_err
  if res.code ~= 0 then
    local err = res.stderr and vim.trim(res.stderr) or ""
    if err == "" then
      err = string.format("gh api exited with code %d", res.code)
    end
    return nil, err
  end
  return true, nil
end

return M
