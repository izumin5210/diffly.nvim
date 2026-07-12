-- Tests for lua/diffly/github.lua (WP-D). Uses a child Neovim (never the test-runner
-- process itself) so that faking/stripping `gh` on PATH per test case can't leak into
-- other test files sharing the same `make test` run.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

--- Point the child's PATH at an empty directory, so `gh` (even if genuinely installed
--- on the host running these tests) is invisible to it.
---@param child table
local function strip_path(child)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  child.lua("vim.env.PATH = ...", { dir })
end

--- Call diffly.github.detect_pr(repo) inside the child, returning a plain table instead
--- of raw multi-values (sparse {info, nil} arrays don't survive the msgpack round-trip
--- predictably).
---@param child table
---@param toplevel string
local function detect_pr(child, toplevel)
  return child.lua(
    [[
      local repo = ...
      local info, err = require("diffly.github").detect_pr(repo)
      return { info = info, err = err }
    ]],
    { { toplevel = toplevel } }
  )
end

local available = function(child)
  return child.lua_get([[require("diffly.github").available()]])
end

local repo, child

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      repo = helpers.new_repo()
      child = helpers.new_child(repo.dir)
    end,
    post_case = function()
      child.stop()
      repo:destroy()
    end,
  },
})

T["available() is true when a `gh` shim is on PATH"] = function()
  local restore = helpers.child_path_shim(child, "gh", 'echo "irrelevant"')
  eq(available(child), true)
  restore()
end

T["available() is false once PATH is stripped of `gh`"] = function()
  strip_path(child)
  eq(available(child), false)
end

T["detect_pr() parses PrInfo from canned `gh` JSON"] = function()
  local restore = helpers.child_path_shim(
    child,
    "gh",
    [[printf '%s' '{"number":123,"baseRefName":"main","url":"https://github.com/acme/widgets/pull/123"}']]
  )

  local result = detect_pr(child, repo.dir)

  eq(result.err, nil)
  eq(
    result.info,
    { number = 123, base_ref = "main", url = "https://github.com/acme/widgets/pull/123" }
  )

  restore()
end

T["detect_pr() returns nil, err when `gh` exits non-zero"] = function()
  local restore = helpers.child_path_shim(
    child,
    "gh",
    [[
      echo "no pull requests found for branch \"feature\"" >&2
      exit 1
    ]]
  )

  local result = detect_pr(child, repo.dir)

  eq(result.info, nil)
  eq(type(result.err), "string")
  eq(result.err:find("no pull requests found") ~= nil, true)

  restore()
end

T["detect_pr() returns nil, err on malformed JSON, without raising"] = function()
  local restore = helpers.child_path_shim(child, "gh", [[printf '%s' 'not json at all {{{']])

  local result = detect_pr(child, repo.dir)

  eq(result.info, nil)
  eq(type(result.err), "string")

  restore()
end

T["detect_pr() returns nil, err on JSON missing expected fields, without raising"] = function()
  local restore = helpers.child_path_shim(child, "gh", [[printf '%s' '{"number":1}']])

  local result = detect_pr(child, repo.dir)

  eq(result.info, nil)
  eq(type(result.err), "string")

  restore()
end

T["detect_pr() returns nil without raising when `gh` is missing"] = function()
  strip_path(child)

  local result = detect_pr(child, repo.dir)

  eq(result.info, nil)
  eq(type(result.err), "string")
end

T["detect_pr() also parses head_oid and url when present, and tolerates their absence"] = function()
  local restore = helpers.child_path_shim(
    child,
    "gh",
    [[printf '%s' '{"number":7,"baseRefName":"main","headRefOid":"abc123","url":"https://github.com/acme/widgets/pull/7"}']]
  )
  local result = detect_pr(child, repo.dir)
  eq(result.err, nil)
  eq(result.info, {
    number = 7,
    base_ref = "main",
    head_oid = "abc123",
    url = "https://github.com/acme/widgets/pull/7",
  })
  restore()

  -- Older shims / restricted `gh` output without the new fields must keep working: the
  -- extra fields are optional, only number/baseRefName are required.
  restore =
    helpers.child_path_shim(child, "gh", [[printf '%s' '{"number":7,"baseRefName":"main"}']])
  result = detect_pr(child, repo.dir)
  eq(result.err, nil)
  eq(result.info, { number = 7, base_ref = "main" })
  restore()
end

-- fetch_threads() -------------------------------------------------------------------

-- A two-page GraphQL response pair: page 1 says hasNextPage with cursor C1; the follow-up
-- call (recognized by "endCursor" appearing in the args) returns page 2. Threads cover a
-- RIGHT-side unresolved 2-message thread, a LEFT-side resolved one, and an outdated one
-- whose live line is null (originalLine carries the historical position).
local PAGE1 = [[{"data":{"repository":{"pullRequest":{"reviewThreads":{]]
  .. [["pageInfo":{"hasNextPage":true,"endCursor":"C1"},]]
  .. [["nodes":[{"id":"T1","isResolved":false,"isOutdated":false,]]
  .. [["line":4,"originalLine":4,"startLine":null,"originalStartLine":null,]]
  .. [["diffSide":"RIGHT","path":"src/a.lua","comments":{"nodes":[]]
  .. [[{"author":{"login":"alice"},"body":"looks off"},]]
  .. [[{"author":{"login":"bob"},"body":"agreed"}]}}]}}}}}]]

local PAGE2 = [[{"data":{"repository":{"pullRequest":{"reviewThreads":{]]
  .. [["pageInfo":{"hasNextPage":false,"endCursor":null},]]
  .. [["nodes":[{"id":"T2","isResolved":true,"isOutdated":false,]]
  .. [["line":10,"originalLine":10,"startLine":8,"originalStartLine":8,]]
  .. [["diffSide":"LEFT","path":"src/a.lua","comments":{"nodes":[]]
  .. [[{"author":null,"body":"old note"}]}},]]
  .. [[{"id":"T3","isResolved":false,"isOutdated":true,]]
  .. [["line":null,"originalLine":9,"startLine":null,"originalStartLine":null,]]
  .. [["diffSide":"RIGHT","path":"src/b.lua","comments":{"nodes":[]]
  .. [[{"author":{"login":"carol"},"body":"gone now"}]}}]}}}}}]]

--- A gh shim that answers `gh api graphql ...` with the two pages above (dispatching on
--- whether the follow-up cursor appears in the args) and logs every invocation's args.
---@param log string @absolute path the shim appends "ARGS ..." lines to
---@return function restore
local function graphql_shim(log)
  local body = ([[
LOG=%q
# One log line per invocation: the args embed the multi-line GraphQL query, so newlines
# must be flattened or a single call would append a dozen lines.
printf 'ARGS %%s' "$*" | tr '\n' ' ' >> "$LOG"
printf '\n' >> "$LOG"
case "$1" in
  api)
    # Dispatch on the follow-up CURSOR ARGUMENT ("endCursor=..."), not the bare word --
    # the GraphQL query text itself contains "$endCursor" on every page.
    case "$*" in
      *endCursor=*) printf '%%s' '%s' ;;
      *) printf '%%s' '%s' ;;
    esac ;;
  *) printf '%%s' '{"number":7,"baseRefName":"main"}' ;;
esac
]]):format(log, PAGE2, PAGE1)
  return helpers.child_path_shim(child, "gh", body)
end

--- Kick off fetch_threads inside the child, recording the sync result and (eventually)
--- the completion into child globals.
---@param repo_id string
local function start_fetch(repo_id)
  child.lua(
    [[
      local repo_id, toplevel = ...
      _G.__fetch_done = nil
      local github = require("diffly.github")
      local handle, err = github.fetch_threads(
        { id = repo_id, toplevel = toplevel },
        { number = 7, base_ref = "main" },
        function(by_path, ferr)
          _G.__fetch_done = { by_path = by_path, err = ferr, count = (_G.__fetch_done_count or 0) + 1 }
          _G.__fetch_done_count = (_G.__fetch_done_count or 0) + 1
        end
      )
      _G.__fetch_handle = handle
      _G.__fetch_start = { ok = handle ~= nil, err = err }
    ]],
    { repo_id, repo.dir }
  )
end

--- Poll the RUNNER side until `expr` is truthy in the child (the suite has no vim.wait;
--- extends test_e2e.lua's vim.uv.sleep precedent).
---@param expr string
---@param timeout_ms integer?
---@return boolean
local function wait_child(expr, timeout_ms)
  for _ = 1, math.floor((timeout_ms or 5000) / 50) do
    if child.lua_get("(" .. expr .. ") == true") then
      return true
    end
    vim.uv.sleep(50)
  end
  return child.lua_get("(" .. expr .. ") == true")
end

T["fetch_threads() pages through GraphQL and translates to neutral shapes"] = function()
  local log = vim.fn.tempname()
  local restore = graphql_shim(log)

  start_fetch("github.com/acme/widgets")
  eq(child.lua_get("_G.__fetch_start.ok"), true)
  eq(wait_child("_G.__fetch_done ~= nil"), true, "completion callback fired")

  local done = child.lua_get("_G.__fetch_done")
  eq(done.err, nil)
  eq(child.lua_get("_G.__fetch_done_count"), 1, "on_done fires exactly once")

  -- Two invocations of `gh api` (one per page), both against the parsed owner/name.
  local args_lines = vim.fn.readfile(log)
  eq(#args_lines, 2)
  eq(args_lines[1]:find("owner=acme", 1, true) ~= nil, true)
  eq(args_lines[1]:find("name=widgets", 1, true) ~= nil, true)
  eq(args_lines[1]:find("number=7", 1, true) ~= nil, true)
  eq(args_lines[1]:find("endCursor=", 1, true), nil, "page 1 passes no cursor argument")
  eq(args_lines[2]:find("endCursor=C1", 1, true) ~= nil, true)

  local a_threads = done.by_path["src/a.lua"]
  eq(#a_threads, 2)
  -- RIGHT -> head, both messages, authors verbatim.
  eq(a_threads[1].id, "T1")
  eq(a_threads[1].remote, true)
  eq(a_threads[1].resolved, false)
  eq(a_threads[1].anchor, { side = "head", start_line = 4, end_line = 4 })
  eq(a_threads[1].messages, {
    { author = "alice", body = "looks off" },
    { author = "bob", body = "agreed" },
  })
  -- LEFT -> base, range via startLine, resolved, ghost author for a deleted account.
  eq(a_threads[2].anchor, { side = "base", start_line = 8, end_line = 10 })
  eq(a_threads[2].resolved, true)
  eq(a_threads[2].messages[1].author, "ghost")

  -- Outdated: live line is null; originalLine carries the position, outdated flags it.
  local b_threads = done.by_path["src/b.lua"]
  eq(#b_threads, 1)
  eq(b_threads[1].anchor, { side = "head", start_line = 9, end_line = 9, outdated = true })

  restore()
end

T["fetch_threads() reports a gh failure through on_done(nil, err)"] = function()
  local restore = helpers.child_path_shim(
    child,
    "gh",
    [[
      echo "HTTP 401: Bad credentials" >&2
      exit 1
    ]]
  )

  start_fetch("github.com/acme/widgets")
  eq(child.lua_get("_G.__fetch_start.ok"), true)
  eq(wait_child("_G.__fetch_done ~= nil"), true)

  local done = child.lua_get("_G.__fetch_done")
  eq(done.by_path, nil)
  eq(done.err:find("Bad credentials") ~= nil, true)

  restore()
end

T["fetch_threads() reports malformed JSON through on_done(nil, err)"] = function()
  local restore = helpers.child_path_shim(child, "gh", [[printf '%s' 'not json {{{']])

  start_fetch("github.com/acme/widgets")
  eq(wait_child("_G.__fetch_done ~= nil"), true)

  local done = child.lua_get("_G.__fetch_done")
  eq(done.by_path, nil)
  eq(type(done.err), "string")

  restore()
end

T["fetch_threads() fails synchronously (on_done never fires) when gh is missing or the repo id is not a remote URL"] = function()
  strip_path(child)
  start_fetch("github.com/acme/widgets")
  eq(child.lua_get("_G.__fetch_start.ok"), false)
  eq(child.lua_get("type(_G.__fetch_start.err)"), "string")

  local restore = helpers.child_path_shim(child, "gh", [[printf '%s' '{}']])
  -- A toplevel-path repo id (no remote) can't be parsed into owner/name.
  start_fetch("/home/user/some/repo")
  eq(child.lua_get("_G.__fetch_start.ok"), false)
  eq(child.lua_get("type(_G.__fetch_start.err)"), "string")

  vim.uv.sleep(300)
  eq(child.lua_get("_G.__fetch_done == nil"), true, "on_done must never fire on a sync failure")

  restore()
end

-- submit_review() -------------------------------------------------------------------

--- Run submit_review inside the child against a stdin-capturing shim: the shim appends
--- its args and then its ENTIRE stdin (the JSON payload piped via `--input -`) to `log`.
---@param log string
---@return function restore
local function submit_shim(log)
  local body = ([[
LOG=%q
printf 'ARGS %%s\n' "$*" >> "$LOG"
case "$1" in
  api) cat >> "$LOG"; printf '%%s' '{}' ;;
  *) printf '%%s' '{}' ;;
esac
]]):format(log)
  return helpers.child_path_shim(child, "gh", body)
end

---@param submission table
---@return {ok: boolean|nil, err: string|nil}
local function submit(submission)
  return child.lua(
    [[
      local repo_id, toplevel, submission = ...
      local ok, err = require("diffly.github").submit_review(
        { id = repo_id, toplevel = toplevel },
        { number = 7, base_ref = "main", head_oid = "abc123" },
        submission
      )
      return { ok = ok, err = err }
    ]],
    { "github.com/acme/widgets", repo.dir, submission }
  )
end

T["submit_review() POSTs one review with translated sides and range rules"] = function()
  local log = vim.fn.tempname()
  local restore = submit_shim(log)

  local result = submit({
    commit_id = "abc123",
    event = "REQUEST_CHANGES",
    body = "overall summary",
    comments = {
      { path = "src/a.lua", side = "head", line = 5, body = "single line" },
      { path = "src/a.lua", side = "base", line = 6, start_line = 4, body = "a base range" },
    },
  })
  eq(result.err, nil)
  eq(result.ok, true)

  local lines = vim.fn.readfile(log)
  eq(lines[1]:find("repos/acme/widgets/pulls/7/reviews", 1, true) ~= nil, true)
  eq(lines[1]:find("--input -", 1, true) ~= nil, true)

  -- Everything after the ARGS line is the JSON payload the shim swallowed from stdin.
  local payload = vim.json.decode(table.concat(vim.list_slice(lines, 2), "\n"))
  eq(payload.commit_id, "abc123")
  eq(payload.event, "REQUEST_CHANGES")
  eq(payload.body, "overall summary")
  eq(#payload.comments, 2)
  -- diffly-neutral sides leave the provider translated to forge vocabulary...
  eq(payload.comments[1].side, "RIGHT")
  eq(payload.comments[1].line, 5)
  eq(payload.comments[1].body, "single line")
  -- ...and single-line comments must NOT carry range fields (the forge rejects
  -- start_line == line).
  eq(payload.comments[1].start_line, nil)
  eq(payload.comments[1].start_side, nil)
  eq(payload.comments[2].side, "LEFT")
  eq(payload.comments[2].start_line, 4)
  eq(payload.comments[2].start_side, "LEFT")
  eq(payload.comments[2].line, 6)

  restore()
end

T["submit_review() omits an empty body and propagates gh failures verbatim"] = function()
  local log = vim.fn.tempname()
  local restore = submit_shim(log)

  eq(
    submit({
      commit_id = "abc123",
      event = "COMMENT",
      comments = { { path = "a", side = "head", line = 1, body = "x" } },
    }).ok,
    true
  )
  local payload = vim.json.decode(table.concat(vim.list_slice(vim.fn.readfile(log), 2), "\n"))
  eq(payload.body, nil)
  restore()

  restore = helpers.child_path_shim(
    child,
    "gh",
    [[
      echo "HTTP 422: line must be part of the diff (pull_request_review_thread.line)" >&2
      exit 1
    ]]
  )
  local result = submit({
    commit_id = "abc123",
    event = "COMMENT",
    comments = { { path = "a", side = "head", line = 1, body = "x" } },
  })
  eq(result.ok, nil)
  eq(result.err:find("line must be part of the diff", 1, true) ~= nil, true)
  restore()
end

T["fetch_threads() cancel suppresses on_done"] = function()
  local restore = helpers.child_path_shim(
    child,
    "gh",
    [[
      sleep 3
      printf '%s' '{}'
    ]]
  )

  start_fetch("github.com/acme/widgets")
  eq(child.lua_get("_G.__fetch_start.ok"), true)
  child.lua("_G.__fetch_handle.cancel()")

  vim.uv.sleep(500)
  eq(child.lua_get("_G.__fetch_done == nil"), true, "a cancelled fetch never completes")

  restore()
end

return T
