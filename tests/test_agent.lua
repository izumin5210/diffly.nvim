-- Tests for lua/diffly/agent.lua: the agent bridge shared by bin/diffly's two transports
-- (RPC dispatch into a live instance, headless fallback). run_headless cases drive a
-- data-only session in a child Neovim whose cwd is a real fixture repo; dispatch cases
-- drive a real `:Diffly` UI in the same child. Git is never mocked; gh is faked via
-- helpers.child_path_shim (even for read ops -- session.new always attempts detect_pr).

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

local repo, paths, child, state_dir

--- gh shim failing every call: no PR, review key stays branch-paired.
local function shim_no_pr()
  helpers.child_path_shim(child, "gh", "exit 1")
end

---@param op string
---@param args table?
---@return table
local function run_headless(op, args)
  return child.lua([[return require("diffly.agent").run_headless(...)]], { op, args or {} })
end

--- The single persisted review state, decoded straight from the isolated state dir --
--- pinning that headless mutations actually reach disk, not just a session table.
---@return table
local function saved_state()
  local jsons = vim.tbl_filter(function(f)
    return f:match("%.json$") ~= nil
  end, vim.fn.readdir(state_dir))
  eq(#jsons, 1)
  local text = table.concat(vim.fn.readfile(state_dir .. "/" .. jsons[1]), "\n")
  return vim.json.decode(text, { luanil = { object = true } })
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      repo, paths = helpers.fixture_branch_repo()
      child = helpers.new_child(repo.dir)
      state_dir = vim.fn.tempname()
      vim.fn.mkdir(state_dir, "p")
      child.lua("require('diffly.state')._dir = ...", { state_dir })
    end,
    post_case = function()
      child.stop()
      vim.fn.delete(state_dir, "rf")
      repo:destroy()
    end,
  },
})

-- run_headless ------------------------------------------------------------------------

T["run_headless('info') describes the branch review with per-file flags"] = function()
  shim_no_pr()

  local res = run_headless("info")
  eq(res.ok, true)
  eq(res.data.review_key.kind, "branch")
  eq(res.data.review_key.base, "main")
  eq(res.data.base_ref, "main")
  eq(res.data.right, "worktree")
  eq(type(res.data.merge_base), "string")
  eq(res.data.pr, nil)
  eq(type(res.data.repo.toplevel), "string")

  local by_path = {}
  for _, file in ipairs(res.data.files) do
    by_path[file.path] = file
  end
  eq(by_path[paths.modified].status, "M")
  eq(by_path[paths.modified].viewed, false)
  eq(by_path[paths.modified].comments, 0)
  eq(by_path[paths.deleted].status, "D")
  eq(by_path[paths.renamed_to].old_path, paths.renamed_from)
end

T["run_headless('add'): head side snapshots the worktree and persists"] = function()
  shim_no_pr()

  local res = run_headless("add", {
    path = paths.modified,
    side = "head",
    start_line = 4,
    body = "from the agent",
  })
  eq(res.ok, true)
  eq(res.data.id, "c1")
  eq(res.data.anchor.side, "head")
  eq(res.data.anchor.start_line, 4)
  eq(res.data.anchor.end_line, 4)
  eq(res.data.anchor.outdated, false)
  -- Internals stay internal: the exported anchor has no sha/snapshot.
  eq(res.data.anchor.sha, nil)
  eq(res.data.anchor.snapshot, nil)
  eq(res.data.messages[1].author, "agent")

  local thread = saved_state().comments[paths.modified][1]
  eq(thread.messages[1].body, "from the agent")
  eq(thread.anchor.snapshot, { '  return "hello, world"' })
end

T["run_headless('add'): base side snapshots blob content, --author overrides"] = function()
  shim_no_pr()

  local res = run_headless("add", {
    path = paths.deleted,
    side = "base",
    start_line = 3,
    end_line = 4,
    body = "why remove this?",
    author = "bot",
  })
  eq(res.ok, true)

  local thread = saved_state().comments[paths.deleted][1]
  eq(thread.anchor.side, "base")
  eq(thread.anchor.snapshot, { "function M.bye()", '  return "bye"' })
  eq(thread.messages[1].author, "bot")
end

T["run_headless('add'): an empty author falls back to the default, never ''"] = function()
  shim_no_pr()

  local res = run_headless("add", {
    path = paths.modified,
    side = "head",
    start_line = 4,
    body = "attributed",
    author = "",
  })
  eq(res.ok, true)
  eq(res.data.messages[1].author, "agent")
end

T["run_headless('add'): validates range, path, side content, and body"] = function()
  shim_no_pr()

  local res = run_headless("add", {
    path = paths.modified,
    side = "head",
    start_line = 999,
    body = "x",
  })
  eq(res.ok, false)
  eq(res.error:find("999") ~= nil, true)

  res =
    run_headless("add", { path = "does/not/exist.lua", side = "head", start_line = 1, body = "x" })
  eq(res.ok, false)

  -- A deleted file has no head side to comment on.
  res = run_headless("add", { path = paths.deleted, side = "head", start_line = 1, body = "x" })
  eq(res.ok, false)

  res = run_headless("add", { path = paths.modified, side = "head", start_line = 4, body = "  " })
  eq(res.ok, false)

  -- Nothing was persisted: not one rejected add produced a state file.
  eq(
    vim.tbl_filter(function(f)
      return f:match("%.json$") ~= nil
    end, vim.fn.readdir(state_dir)),
    {}
  )
end

T["run_headless: list / reply by id / rm by id, stateful across invocations"] = function()
  shim_no_pr()

  eq(
    run_headless("add", { path = paths.modified, side = "head", start_line = 4, body = "first" }).ok,
    true
  )
  eq(
    run_headless(
      "add",
      { path = paths.new, side = "head", start_line = 3, body = "second", author = "bot" }
    ).ok,
    true
  )

  local list = run_headless("list")
  eq(list.ok, true)
  eq(#list.data.comments, 2)
  eq(list.data.comments[1].path, paths.modified)
  eq(list.data.comments[1].messages[1].author, "agent")
  eq(list.data.comments[2].id, "c2")
  eq(list.data.remote, nil)

  local reply = run_headless("reply", { id = "c1", body = "addressed" })
  eq(reply.ok, true)
  eq(reply.data.messages[2].body, "addressed")
  eq(reply.data.messages[2].author, "agent")

  local rm = run_headless("rm", { id = "c2" })
  eq(rm.ok, true)
  eq(rm.data.deleted, "c2")
  eq(#run_headless("list").data.comments, 1)

  eq(run_headless("reply", { id = "c99", body = "x" }).ok, false)
  eq(run_headless("rm", { id = "c99" }).ok, false)
end

T["run_headless('navigate') refuses politely"] = function()
  shim_no_pr()

  local res = run_headless("navigate", { path = paths.modified, line = 4 })
  eq(res.ok, false)
  eq(res.error:find(":Diffly") ~= nil, true)
end

local THREADS_JSON = [[{"data":{"repository":{"pullRequest":{"reviewThreads":{]]
  .. [["pageInfo":{"hasNextPage":false,"endCursor":null},]]
  .. [["nodes":[{"id":"T1","isResolved":false,"isOutdated":false,]]
  .. [["line":4,"originalLine":4,"startLine":null,"originalStartLine":null,]]
  .. [["diffSide":"RIGHT","path":"src/mod.lua","comments":{"nodes":[]]
  .. [[{"author":{"login":"alice"},"body":"tighten the greeting"}]}},]]
  .. [[{"id":"T2","isResolved":true,"isOutdated":false,]]
  .. [["line":8,"originalLine":8,"startLine":null,"originalStartLine":null,]]
  .. [["diffSide":"RIGHT","path":"src/mod.lua","comments":{"nodes":[]]
  .. [[{"author":{"login":"bob"},"body":"resolved earlier"}]}}]}}}}}]]

T["run_headless('list', remote): fetches review threads synchronously"] = function()
  -- fetch_threads needs a parseable repo id and a detected PR.
  repo:git({ "remote", "add", "origin", "git@github.com:owner/repo.git" })
  helpers.child_path_shim(
    child,
    "gh",
    ([[
case "$1" in
  api) printf '%%s' '%s' ;;
  *) printf '%%s' '{"number":7,"baseRefName":"main","headRefOid":"abc123","url":"https://example.com/pr/7"}' ;;
esac
]]):format(THREADS_JSON)
  )

  local res = run_headless("list", { remote = true })
  eq(res.ok, true)
  eq(#res.data.remote, 2)
  eq(res.data.remote[1].id, "T1")
  eq(res.data.remote[1].resolved, false)
  eq(res.data.remote[1].anchor.start_line, 4)
  eq(res.data.remote[1].messages[1].author, "alice")
  -- Resolved threads ARE listed (the agent sees everything; flags carry the state).
  eq(res.data.remote[2].resolved, true)
end

T["run_headless('list', remote) without a PR degrades to an empty overlay"] = function()
  shim_no_pr()

  local res = run_headless("list", { remote = true })
  eq(res.ok, true)
  eq(res.data.remote, {})
end

-- sessions() / dispatch -----------------------------------------------------------------

T["sessions(): empty without init.lua loaded, lists the live review after :Diffly"] = function()
  shim_no_pr()

  eq(child.lua_get("require('diffly.agent').sessions()"), {})

  child.cmd("runtime! plugin/diffly.lua")
  child.cmd("Diffly")

  local sessions = child.lua_get("require('diffly.agent').sessions()")
  eq(#sessions, 1)
  eq(sessions[1].repo_id, child.lua_get("require('diffly.git').repo_identity(vim.fn.getcwd()).id"))
  eq(type(sessions[1].tab), "number")
  eq(type(sessions[1].toplevel), "string")
  eq(sessions[1].review_key.kind, "branch")
end

T["dispatch(): mutates the live session in place, rejects stale tabs and unknown ops"] = function()
  shim_no_pr()
  child.cmd("runtime! plugin/diffly.lua")
  child.cmd("Diffly")
  local tab = child.lua_get("require('diffly.agent').sessions()[1].tab")

  local res = child.lua(
    [[return require("diffly.agent").dispatch("add", ...)]],
    { { tab = tab, path = paths.modified, side = "head", start_line = 4, body = "live add" } }
  )
  eq(res.ok, true)
  eq(res.data.id, "c1")

  -- The live session saw the mutation directly -- no reload involved.
  eq(
    child.lua_get(
      ("require('diffly')._entries[%d].session.state.comments['%s'][1].messages[1].body"):format(
        tab,
        paths.modified
      )
    ),
    "live add"
  )

  local stale = child.lua([[return require("diffly.agent").dispatch("add", { tab = 999 })]])
  eq(stale.ok, false)

  local unknown =
    child.lua([[return require("diffly.agent").dispatch("frobnicate", ...)]], { { tab = tab } })
  eq(unknown.ok, false)
end

T["dispatch('navigate'): switches tab, opens the file, lands on the line"] = function()
  shim_no_pr()
  child.cmd("runtime! plugin/diffly.lua")
  child.cmd("Diffly")
  local tab = child.lua_get("require('diffly.agent').sessions()[1].tab")

  -- Prove the tab switch by walking away first.
  child.cmd("tabnew")

  local res = child.lua(
    [[return require("diffly.agent").dispatch("navigate", ...)]],
    { { tab = tab, path = paths.modified, line = 4 } }
  )
  eq(res.ok, true)
  eq(child.lua_get("vim.api.nvim_get_current_tabpage()"), tab)
  eq(
    child.lua_get(("require('diffly')._entries[%d].session.current_path"):format(tab)),
    paths.modified
  )
  eq(child.lua_get("vim.api.nvim_win_get_cursor(0)[1]"), 4)

  local bad = child.lua(
    [[return require("diffly.agent").dispatch("navigate", ...)]],
    { { tab = tab, path = "does/not/exist.lua", line = 1 } }
  )
  eq(bad.ok, false)
end

return T
