-- Shared test helpers, loaded from each test file with `dofile('tests/helpers.lua')`
-- (the mini.test convention: tests always run with cwd == repo root). Git is never
-- mocked in this project's tests: everything here creates and drives real repositories
-- in temporary directories.

local helpers = {}

---@class diffly.test.Repo
---@field dir string  -- toplevel
local Repo = {}
Repo.__index = Repo

--- Run `git -C dir <args...>`, raising a Lua error (with stderr) on non-zero exit.
---@param args string[]
---@return string stdout
function Repo:git(args)
  local cmd = { "git", "-C", self.dir }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    error(
      string.format(
        "`git %s` failed (exit %d): %s",
        table.concat(args, " "),
        res.code,
        (res.stderr or ""):gsub("%s+$", "")
      ),
      2
    )
  end
  return res.stdout or ""
end

--- Write a file under the repo, creating parent directories as needed.
---@param path string           -- relative to `dir`
---@param content string|string[]
function Repo:write(path, content)
  local full = self.dir .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  local lines = type(content) == "table" and content or vim.split(content, "\n")
  vim.fn.writefile(lines, full, "b")
end

--- Stage everything and commit.
---@param msg string
function Repo:commit(msg)
  self:git({ "add", "-A" })
  self:git({ "commit", "-q", "-m", msg })
end

--- Create and switch to a new branch off the current HEAD.
---@param name string
function Repo:branch(name)
  self:git({ "switch", "-q", "-c", name })
end

--- Best-effort recursive delete of the repo's temp dir.
function Repo:destroy()
  vim.fn.delete(self.dir, "rf")
end

--- Fresh repo in a new temp dir, configured so commits work unattended in CI
--- (deterministic local identity, no GPG signing prompts).
---@return diffly.test.Repo
function helpers.new_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  local repo = setmetatable({ dir = dir }, Repo)
  repo:git({ "init", "-q", "-b", "main" })
  repo:git({ "config", "user.name", "diffly test" })
  repo:git({ "config", "user.email", "diffly-test@example.com" })
  repo:git({ "config", "commit.gpgsign", "false" })
  repo:git({ "config", "tag.gpgsign", "false" })
  return repo
end

---@class diffly.test.FixturePaths
---@field new string           -- added on `feature`, absent on `main`
---@field modified string      -- present on both, edited on `feature`
---@field deleted string       -- present on `main`, removed on `feature`
---@field renamed_from string  -- pre-rename path, present on `main` only
---@field renamed_to string    -- post-rename path, present on `feature` only

--- Standard fixture reused across WPs: `main` with two commits, and a `feature` branch
--- forked from `main`'s tip with one more commit that adds, modifies, deletes, and
--- renames a file each -- enough for a single `git diff -M <merge-base> feature` to
--- exercise every `diffly.FileEntry.status` value. The rename keeps most of the original
--- lines untouched (only appends a function) so its similarity is well above the 50%
--- default threshold and `-M` reports it as a rename rather than an add+delete pair.
---@return diffly.test.Repo repo
---@return diffly.test.FixturePaths paths
function helpers.fixture_branch_repo()
  local repo = helpers.new_repo()

  repo:write("README.md", "# fixture\n")
  repo:write("src/mod.lua", {
    "local M = {}",
    "",
    "function M.hello()",
    '  return "hello"',
    "end",
    "",
    "return M",
  })
  repo:write("src/gone.lua", {
    "local M = {}",
    "",
    "function M.bye()",
    '  return "bye"',
    "end",
    "",
    "return M",
  })
  repo:write("src/old_name.lua", {
    "local M = {}",
    "",
    "function M.old_name()",
    '  return "old"',
    "end",
    "",
    "return M",
  })
  repo:commit("chore: initial commit")

  repo:write("README.md", "# fixture\n\nSecond commit on main.\n")
  repo:commit("docs: expand readme")

  repo:branch("feature")

  repo:write("src/new.lua", {
    "local M = {}",
    "",
    "function M.new_feature()",
    '  return "new"',
    "end",
    "",
    "return M",
  })
  repo:write("src/mod.lua", {
    "local M = {}",
    "",
    "function M.hello()",
    '  return "hello, world"',
    "end",
    "",
    "function M.extra()",
    "  return true",
    "end",
    "",
    "return M",
  })
  vim.fn.delete(repo.dir .. "/src/gone.lua")
  vim.fn.delete(repo.dir .. "/src/old_name.lua")
  repo:write("src/renamed.lua", {
    "local M = {}",
    "",
    "function M.old_name()",
    '  return "old"',
    "end",
    "",
    "function M.renamed_extra()",
    '  return "renamed"',
    "end",
    "",
    "return M",
  })
  repo:commit("feat: add, modify, delete, rename")

  local paths = {
    new = "src/new.lua",
    modified = "src/mod.lua",
    deleted = "src/gone.lua",
    renamed_from = "src/old_name.lua",
    renamed_to = "src/renamed.lua",
  }
  return repo, paths
end

--- Child-process Neovim (via `MiniTest.new_child_neovim`) restarted with
--- `tests/minimal_init.lua` and its cwd set to `dir`. Callers own the child's lifecycle
--- (e.g. `child.stop()` in a `post_once` hook); this only performs the initial start.
---@param dir string
---@return table child  -- see `:h MiniTest-child-neovim`
function helpers.new_child(dir)
  local child = MiniTest.new_child_neovim()
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.fn.chdir(dir)
  return child
end

--- Prepend a temp dir to `$PATH` containing an executable `name` running `body` (sh
--- script text; a `#!/bin/sh` shebang is added automatically unless `body` already
--- starts with one). Used to fake CLIs like `gh` without ever touching the real one.
---@param name string
---@param body string
---@return fun() restore  -- call to remove the shim dir from PATH again
function helpers.path_shim(name, body)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  local path = dir .. "/" .. name
  local script = body:match("^#!") and body or ("#!/bin/sh\n" .. body)
  vim.fn.writefile(vim.split(script, "\n"), path, "b")
  vim.fn.setfperm(path, "rwxr-xr-x")

  local old_path = vim.env.PATH
  vim.env.PATH = dir .. ":" .. old_path
  return function()
    vim.env.PATH = old_path
  end
end

--- Like `helpers.path_shim`, but writes the fake executable to disk from the
--- test-runner process (fine: it's just a filesystem operation) and then points *the
--- child's* `PATH` at it -- since the child, not this process, is what actually runs the
--- code under test (`require("diffly.github")`/`require("diffly")` inside `child.lua`
--- calls). Promoted from tests/test_github.lua and tests/test_e2e.lua, which had it
--- duplicated identically.
---@param child table
---@param name string
---@param body string
---@return fun() restore
function helpers.child_path_shim(child, name, body)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  local path = dir .. "/" .. name
  local script = body:match("^#!") and body or ("#!/bin/sh\n" .. body)
  vim.fn.writefile(vim.split(script, "\n"), path, "b")
  vim.fn.setfperm(path, "rwxr-xr-x")

  local old_path = child.lua_get("vim.env.PATH")
  child.lua("vim.env.PATH = ...", { dir .. ":" .. old_path })
  return function()
    child.lua("vim.env.PATH = ...", { old_path })
  end
end

return helpers
