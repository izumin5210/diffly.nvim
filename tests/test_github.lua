-- Tests for lua/difit/github.lua (WP-D). Uses a child Neovim (never the test-runner
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
  eq(result.info, { number = 123, base_ref = "main" })

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

return T
