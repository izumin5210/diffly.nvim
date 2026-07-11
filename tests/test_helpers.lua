-- Smoke tests for tests/helpers.lua itself. If these fail, every other WP's test suite
-- is unreliable, so they run first.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["new_repo() creates a repo where commits work"] = function()
  local repo = helpers.new_repo()

  repo:write("a.txt", "hello\n")
  repo:commit("chore: add a.txt")

  local log = vim.split(repo:git({ "log", "--oneline" }), "\n", { trimempty = true })
  eq(#log, 1)

  -- Nothing left uncommitted, and the file round-trips through the working tree.
  eq(repo:git({ "status", "--porcelain" }), "")
  eq(vim.fn.readfile(repo.dir .. "/a.txt"), { "hello" })

  -- A second commit should be possible on top of the first.
  repo:write("dir/b.txt", { "one", "two" })
  repo:commit("chore: add dir/b.txt")
  log = vim.split(repo:git({ "log", "--oneline" }), "\n", { trimempty = true })
  eq(#log, 2)

  repo:destroy()
  eq(vim.uv.fs_stat(repo.dir), nil)
end

T["fixture_branch_repo() sets up the expected branches, paths and statuses"] = function()
  local repo, paths = helpers.fixture_branch_repo()

  eq(paths, {
    new = "src/new.lua",
    modified = "src/mod.lua",
    deleted = "src/gone.lua",
    renamed_from = "src/old_name.lua",
    renamed_to = "src/renamed.lua",
  })

  local branches =
    vim.split(repo:git({ "branch", "--format=%(refname:short)" }), "\n", { trimempty = true })
  table.sort(branches)
  eq(branches, { "feature", "main" })

  -- `feature` is the checked-out branch left behind for callers.
  eq(vim.trim(repo:git({ "branch", "--show-current" })), "feature")

  -- `main` has exactly two commits.
  local main_log = vim.split(repo:git({ "log", "--oneline", "main" }), "\n", { trimempty = true })
  eq(#main_log, 2)

  -- A single `-M` diff between the branches must report each fixture path with the
  -- status diffly.FileEntry expects, and the rename must be detected (not seen as a
  -- delete+add pair).
  local diff = vim.split(
    repo:git({ "diff", "--name-status", "-M", "main", "feature" }),
    "\n",
    { trimempty = true }
  )
  local by_status = { A = {}, M = {}, D = {}, R = {} }
  for _, line in ipairs(diff) do
    local status, rest = line:match("^(%a)%d*\t(.+)$")
    if status == "R" then
      local old_path, new_path = rest:match("^(.-)\t(.+)$")
      table.insert(by_status.R, { old_path, new_path })
    else
      table.insert(by_status[status], rest)
    end
  end

  eq(by_status.A, { paths.new })
  eq(by_status.M, { paths.modified })
  eq(by_status.D, { paths.deleted })
  eq(by_status.R, { { paths.renamed_from, paths.renamed_to } })

  repo:destroy()
end

T["new_child() starts a child neovim with cwd set to the given dir"] = function()
  local repo = helpers.new_repo()
  local child = helpers.new_child(repo.dir)

  -- Compare real paths: on macOS `$TMPDIR` resolves through a `/private` symlink, so
  -- `getcwd()` (which returns the resolved path) can otherwise differ textually from
  -- `repo.dir` while still pointing at the same directory.
  local expected = vim.uv.fs_realpath(repo.dir)
  eq(child.fn.getcwd(), expected)
  eq(child.lua_get("1 + 1"), 2)

  child.stop()
  repo:destroy()
end

T["path_shim() makes a fake executable win over PATH"] = function()
  -- Put a conflicting "loser" executable of the same name on PATH first, so the test
  -- actually exercises "wins over PATH" rather than just "is found somewhere on PATH".
  local loser_dir = vim.fn.tempname()
  vim.fn.mkdir(loser_dir, "p")
  local loser_path = loser_dir .. "/diffly-test-shim"
  vim.fn.writefile({ "#!/bin/sh", 'echo "loser"' }, loser_path, "b")
  vim.fn.setfperm(loser_path, "rwxr-xr-x")

  local old_path = vim.env.PATH
  vim.env.PATH = loser_dir .. ":" .. old_path

  local before = vim.system({ "diffly-test-shim" }, { text = true }):wait()
  eq(vim.trim(before.stdout), "loser")

  local restore = helpers.path_shim("diffly-test-shim", 'echo "winner"')
  local res = vim.system({ "diffly-test-shim" }, { text = true }):wait()
  eq(res.code, 0)
  eq(vim.trim(res.stdout), "winner")

  restore()

  -- Restoring removes only the shim's own dir; the pre-existing "loser" stays on PATH.
  local after = vim.system({ "diffly-test-shim" }, { text = true }):wait()
  eq(vim.trim(after.stdout), "loser")

  vim.env.PATH = old_path
  vim.fn.delete(loser_dir, "rf")
end

return T
