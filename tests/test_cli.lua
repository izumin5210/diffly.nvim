-- End-to-end tests for bin/diffly + lua/diffly/cli.lua: the real executable spawned as a
-- subprocess against real fixture repos. gh is faked via helpers.path_shim (the runner's
-- PATH mutation is inherited by the spawned CLI); the spawned Neovim's stdpath('data') is
-- isolated per test via XDG_DATA_HOME. RPC cases target a child Neovim's socket.
--
-- The CLI is ALWAYS spawned async and awaited with vim.wait: the discovery scan probes
-- every peer socket -- including this test-runner's own -- with a blocking rpcrequest,
-- so the runner must keep serving RPC (vim.wait pumps the loop) while the CLI runs, or
-- the probe would deadlock against a runner stuck in vim.system():wait().

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

local BIN = vim.fn.fnamemodify("bin/diffly", ":p")

local repo, paths, data_dir, restore_gh

---@param args string[]
---@param opts { env: table<string, string>?, stdin: string? }?
---@return { code: integer, stdout: string, stderr: string }
local function run_cli(args, opts)
  opts = opts or {}
  local cmd = { BIN }
  vim.list_extend(cmd, args)

  local env = vim.tbl_extend("force", { XDG_DATA_HOME = data_dir, NVIM = "" }, opts.env or {})

  local done, result = false, nil
  local proc = vim.system(cmd, {
    text = true,
    cwd = repo.dir,
    env = env,
    stdin = opts.stdin,
  }, function(res)
    result = res
    done = true
  end)
  if not vim.wait(20000, function()
    return done
  end, 50) then
    proc:kill(9)
    vim.wait(2000, function()
      return done
    end, 50)
  end
  return result or { code = -1, stdout = "", stderr = "diffly test: CLI timed out" }
end

---@param res { stdout: string }
---@return table
local function decode(res)
  return vim.json.decode(res.stdout, { luanil = { object = true } })
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      repo, paths = helpers.fixture_branch_repo()
      data_dir = vim.fn.tempname()
      vim.fn.mkdir(data_dir, "p")
      -- Every gh call fails: no PR, branch-paired review key. Individual cases may
      -- re-shim. Installed on the RUNNER's PATH -- vim.system children inherit it.
      restore_gh = helpers.path_shim("gh", "exit 1")
    end,
    post_case = function()
      restore_gh()
      vim.fn.delete(data_dir, "rf")
      repo:destroy()
    end,
  },
})

-- headless ------------------------------------------------------------------------------

T["headless: info emits pure JSON on stdout with live=false"] = function()
  local res = run_cli({ "info" })
  eq(res.code, 0)

  local data = decode(res)
  eq(data.live, false)
  eq(data.server, nil)
  eq(data.review_key.kind, "branch")
  eq(data.right, "worktree")
  eq(#data.files, 4)
end

T["headless: add/list round-trip, author default + override, stdin body"] = function()
  local res = run_cli({
    "comments",
    "add",
    "--file",
    paths.modified,
    "--line",
    "4",
    "--body",
    "from the agent",
  })
  eq(res.code, 0)
  eq(decode(res).id, "c1")

  res = run_cli(
    { "comments", "add", "--file", paths.new, "--line", "3", "--author", "bot", "--body", "-" },
    { stdin = "from stdin\nsecond line\n" }
  )
  eq(res.code, 0)
  local added = decode(res)
  eq(added.id, "c2")
  eq(added.messages[1].author, "bot")
  eq(added.messages[1].body, "from stdin\nsecond line")

  res = run_cli({ "comments", "list" })
  eq(res.code, 0)
  local list = decode(res)
  eq(#list.comments, 2)
  eq(list.comments[1].messages[1].author, "agent")
  eq(list.comments[1].anchor.outdated, false)
end

T["headless: reply and rm by id; unknown ids exit 1 with empty stdout"] = function()
  eq(run_cli({ "comments", "add", "--file", paths.modified, "--line", "4", "--body", "x" }).code, 0)

  local res = run_cli({ "comments", "reply", "c1", "--body", "addressed" })
  eq(res.code, 0)
  eq(decode(res).messages[2].body, "addressed")
  eq(decode(res).messages[2].author, "agent")

  res = run_cli({ "comments", "rm", "c1" })
  eq(res.code, 0)
  eq(decode(res).deleted, "c1")

  res = run_cli({ "comments", "rm", "c1" })
  eq(res.code, 1)
  eq(res.stdout, "")
  eq(res.stderr ~= "", true)
end

T["headless: navigate exits 2 with a pointer to :Diffly"] = function()
  local res = run_cli({ "navigate", "--file", paths.modified, "--line", "4" })
  eq(res.code, 2)
  eq(res.stdout, "")
  eq(res.stderr:find(":Diffly") ~= nil, true)
end

T["usage errors exit 1 and print usage"] = function()
  local res = run_cli({ "frobnicate" })
  eq(res.code, 1)
  eq(res.stderr:find("Usage") ~= nil, true)

  res = run_cli({ "comments", "add", "--file", paths.modified, "--line" })
  eq(res.code, 1)
end

-- RPC ----------------------------------------------------------------------------------

local child

--- A child Neovim with a live `:Diffly` review on the fixture repo, listening on a
--- fresh socket. gh fails inside the child too (branch review), and its state dir is
--- isolated via the `_dir` seam.
---@return string sock, string child_state_dir
local function live_child()
  child = helpers.new_child(repo.dir)
  local child_state = vim.fn.tempname()
  vim.fn.mkdir(child_state, "p")
  child.lua("require('diffly.state')._dir = ...", { child_state })
  helpers.child_path_shim(child, "gh", "exit 1")
  child.cmd("runtime! plugin/diffly.lua")
  child.cmd("Diffly")
  return child.lua_get("vim.fn.serverstart()"), child_state
end

local function stop_child()
  if child then
    child.stop()
    child = nil
  end
end

T["rpc: --server routes the mutation into the live session and its panel"] = function()
  local sock = live_child()

  local res = run_cli({
    "--server",
    sock,
    "comments",
    "add",
    "--file",
    paths.modified,
    "--line",
    "4",
    "--body",
    "via rpc",
  })
  eq(res.code, 0)
  eq(decode(res).id, "c1")

  -- The live session mutated in place -- single write authority, no reload anywhere.
  local tab = child.lua_get("require('diffly.agent').sessions()[1].tab")
  eq(
    child.lua_get(
      ("require('diffly')._entries[%d].session.state.comments['%s'][1].messages[1].body"):format(
        tab,
        paths.modified
      )
    ),
    "via rpc"
  )
  -- And the human sees it: the panel row now carries the comment indicator.
  local panel_text = child.lua_get(
    ("table.concat(vim.api.nvim_buf_get_lines(require('diffly')._entries[%d].panel.buf, 0, -1, false), '\\n')"):format(
      tab
    )
  )
  eq(panel_text:find("✎1") ~= nil, true)

  stop_child()
end

T["rpc: --server pointing at a session-less instance fails rather than clobbering"] = function()
  child = helpers.new_child(repo.dir)
  local sock = child.lua_get("vim.fn.serverstart()")

  local res = run_cli({ "--server", sock, "comments", "list" })
  eq(res.code, 1)
  eq(res.stdout, "")

  stop_child()
end

T["rpc: navigate switches the live instance's tab, file, and line"] = function()
  local sock = live_child()
  child.cmd("tabnew")

  local res = run_cli({ "--server", sock, "navigate", "--file", paths.modified, "--line", "4" })
  eq(res.code, 0)

  local tab = child.lua_get("require('diffly.agent').sessions()[1].tab")
  eq(child.lua_get("vim.api.nvim_get_current_tabpage()"), tab)
  eq(
    child.lua_get(("require('diffly')._entries[%d].session.current_path"):format(tab)),
    paths.modified
  )
  eq(child.lua_get("vim.api.nvim_win_get_cursor(0)[1]"), 4)

  stop_child()
end

T["discovery: $NVIM finds the hosting instance without --server"] = function()
  local sock = live_child()

  local res = run_cli({ "info" }, { env = { NVIM = sock } })
  eq(res.code, 0)
  local data = decode(res)
  eq(data.live, true)
  eq(data.server, sock)

  stop_child()
end

T["discovery: the peer-socket scan finds the live instance by repo"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("serverlist({peer=true}) is not supported on Windows")
  end
  live_child()

  -- No --server, no $NVIM: only the scan can find the child (matched by repo id).
  local res = run_cli({ "info" })
  eq(res.code, 0)
  eq(decode(res).live, true)

  stop_child()
end

T["--headless skips discovery even when a live session exists"] = function()
  local sock = live_child()

  local res = run_cli({ "--headless", "info" }, { env = { NVIM = sock } })
  eq(res.code, 0)
  eq(decode(res).live, false)

  stop_child()
end

return T
