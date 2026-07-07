-- Tests for lua/difit/github.lua (WP-D). Uses a child Neovim (never the test-runner
-- process itself) so that faking/stripping `gh` on PATH per test case can't leak into
-- other test files sharing the same `make test` run.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

--- Like helpers.path_shim, but writes the fake executable to disk from the test-runner
--- process (fine: it's just a filesystem operation) and then points *the child's* PATH
--- at it, since the child -- not this process -- is what `require("difit.github")` runs
--- in for these tests.
---@param child table
---@param name string
---@param body string
---@return fun() restore
local function child_path_shim(child, name, body)
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

--- Point the child's PATH at an empty directory, so `gh` (even if genuinely installed
--- on the host running these tests) is invisible to it.
---@param child table
local function strip_path(child)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  child.lua("vim.env.PATH = ...", { dir })
end

--- Call difit.github.detect_pr(repo) inside the child, returning a plain table instead
--- of raw multi-values (sparse {info, nil} arrays don't survive the msgpack round-trip
--- predictably).
---@param child table
---@param toplevel string
local function detect_pr(child, toplevel)
  return child.lua(
    [[
      local repo = ...
      local info, err = require("difit.github").detect_pr(repo)
      return { info = info, err = err }
    ]],
    { { toplevel = toplevel } }
  )
end

local available = function(child)
  return child.lua_get([[require("difit.github").available()]])
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
  local restore = child_path_shim(child, "gh", 'echo "irrelevant"')
  eq(available(child), true)
  restore()
end

T["available() is false once PATH is stripped of `gh`"] = function()
  strip_path(child)
  eq(available(child), false)
end

T["detect_pr() parses PrInfo from canned `gh` JSON"] = function()
  local restore = child_path_shim(
    child,
    "gh",
    [[printf '%s' '{"number":123,"baseRefName":"main","url":"https://github.com/acme/widgets/pull/123"}']]
  )

  local result = detect_pr(child, repo.dir)

  eq(result.err, nil)
  eq(result.info, { number = 123, base_ref = "main", owner_repo = "acme/widgets" })

  restore()
end

T["detect_pr() parses owner/repo containing dots and dashes"] = function()
  local restore = child_path_shim(
    child,
    "gh",
    [[printf '%s' '{"number":7,"baseRefName":"develop","url":"https://github.com/my-org/repo.name/pull/7"}']]
  )

  local result = detect_pr(child, repo.dir)

  eq(result.info.owner_repo, "my-org/repo.name")

  restore()
end

T["detect_pr() returns nil, err when `gh` exits non-zero"] = function()
  local restore = child_path_shim(
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
  local restore = child_path_shim(child, "gh", [[printf '%s' 'not json at all {{{']])

  local result = detect_pr(child, repo.dir)

  eq(result.info, nil)
  eq(type(result.err), "string")

  restore()
end

T["detect_pr() returns nil, err on JSON missing expected fields, without raising"] = function()
  local restore = child_path_shim(child, "gh", [[printf '%s' '{"number":1}']])

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

return T
