-- Tests for lua/difit/ui/sidebyside.lua (WP-F): the two-window vertical diff pair.
-- Runs entirely inside a child Neovim (real windows/buffers are required, not fakeable),
-- driven from the test-runner process via `child.lua`. Entry/spec tables are built from
-- real git plumbing (`difit.git`) against `helpers.fixture_branch_repo()` -- no mocks.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

--- Build a difit.DiffSpec + difit.FileEntry[] pair for the fixture repo (main...feature)
--- entirely inside the child, using the same git plumbing the real session would use.
---@param child table
---@param right "worktree"|"head"
---@return table @{ spec = difit.DiffSpec, entries = difit.FileEntry[] }
local function build(child, right)
  return child.lua(
    [[
      local right = ...
      local git = require("difit.git")
      local repo = git.repo_identity(vim.fn.getcwd())
      local merge_base = git.merge_base(repo, "main", "feature")
      local entries = git.diff_files(repo, merge_base, right, { include_untracked = true })
      local spec = {
        repo = repo,
        base_ref = "main",
        merge_base = merge_base,
        right = right,
        review_key = { kind = "branch", repo = repo.id, base = "main", head = "feature" },
      }
      return { spec = spec, entries = entries }
    ]],
    { right }
  )
end

---@param entries difit.FileEntry[]
---@param path string
---@return difit.FileEntry
local function entry_by_path(entries, path)
  for _, e in ipairs(entries) do
    if e.path == path then
      return e
    end
  end
  error("no entry for path " .. path)
end

--- Create the view under test in the child and stash it as a global, so later calls in
--- the same test case can keep driving the same instance (needed to observe window
--- reuse across multiple `open()` calls).
---@param child table
local function new_view(child)
  child.lua([[ _G.__view = require("difit.ui.sidebyside").new() ]])
end

---@param child table
---@param spec table
---@param entry table
local function view_open(child, spec, entry)
  child.lua(
    [[
      local spec, entry = ...
      _G.__view:open(entry, spec)
    ]],
    { spec, entry }
  )
end

---@param child table
local function view_close(child)
  child.lua([[ _G.__view:close() ]])
end

---@param child table
local function win_count(child)
  return child.lua_get("#vim.api.nvim_tabpage_list_wins(0)")
end

---@param child table
---@param which "left_win"|"right_win"
local function win_id(child, which)
  return child.lua_get("_G.__view." .. which)
end

---@param child table
---@param which "left_win"|"right_win"
local function win_bufname(child, which)
  return child.lua_get(
    string.format("vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(_G.__view.%s))", which)
  )
end

---@param child table
---@param which "left_win"|"right_win"
---@param opt string
local function win_bufopt(child, which, opt)
  return child.lua_get(
    string.format("vim.bo[vim.api.nvim_win_get_buf(_G.__view.%s)].%s", which, opt)
  )
end

---@param child table
---@param which "left_win"|"right_win"
local function win_buflines(child, which)
  return child.lua_get(
    string.format(
      "vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(_G.__view.%s), 0, -1, false)",
      which
    )
  )
end

---@param child table
---@param which "left_win"|"right_win"
local function win_diff(child, which)
  return child.lua_get(string.format("vim.wo[_G.__view.%s].diff", which))
end

--- Independent cross-check for committed content (bypasses difit.git.file_content, which
--- is what the module under test uses internally).
---@param repo difit.test.Repo
---@param rev string
---@param path string
---@return string[]
local function git_show_lines(repo, rev, path)
  local out = (repo:git({ "show", rev .. ":" .. path })):gsub("\n$", "")
  if out == "" then
    return {}
  end
  return vim.split(out, "\n", { plain = true })
end

--- Write raw bytes bypassing Repo:write (which round-trips through `writefile()` and
--- can't carry an embedded NUL byte); mirrors tests/test_git.lua's helper of the same
--- purpose.
---@param repo difit.test.Repo
---@param path string
---@param bytes string
local function write_bytes(repo, path, bytes)
  local full = repo.dir .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  local fd = assert(io.open(full, "wb"))
  fd:write(bytes)
  fd:close()
end

local repo, paths, child

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      repo, paths = helpers.fixture_branch_repo()
      child = helpers.new_child(repo.dir)
    end,
    post_case = function()
      child.stop()
      repo:destroy()
    end,
  },
})

T["modified file: two &diff windows, left is an owned non-modifiable buffer, right is the real file"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  eq(win_count(child), 2)
  eq(win_diff(child, "left_win"), true)
  eq(win_diff(child, "right_win"), true)

  local left_name = win_bufname(child, "left_win")
  eq(vim.startswith(left_name, "difit://"), true)
  eq(win_bufopt(child, "left_win", "modifiable"), false)
  eq(win_bufopt(child, "left_win", "buftype"), "nofile")

  local right_name = win_bufname(child, "right_win")
  eq(vim.endswith(right_name, "/" .. paths.modified), true)
  eq(vim.startswith(right_name, "difit://"), false)
  eq(win_bufopt(child, "right_win", "modifiable"), true)
end

T["added file: left window is an empty scratch buffer"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.new)
  eq(entry.base_sha, nil)

  new_view(child)
  view_open(child, built.spec, entry)

  eq(win_bufname(child, "left_win"), "difit://empty/" .. paths.new)
  eq(win_bufopt(child, "left_win", "modifiable"), false)
  eq(win_buflines(child, "left_win"), { "" })
end

T["deleted file: right window is an empty scratch buffer"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.deleted)
  eq(entry.head_sha, nil)

  new_view(child)
  view_open(child, built.spec, entry)

  eq(win_bufname(child, "right_win"), "difit://deleted/" .. paths.deleted)
  eq(win_bufopt(child, "right_win", "modifiable"), false)
  eq(win_buflines(child, "right_win"), { "" })

  -- Left side is unaffected: the file exists at the merge-base, so it's a normal
  -- read-only blob buffer, not another empty scratch.
  eq(win_bufopt(child, "left_win", "modifiable"), false)
  eq(win_buflines(child, "left_win"), git_show_lines(repo, "main", paths.deleted))
end

T["head mode: right window is a read-only blob matching the committed content"] = function()
  local built = build(child, "head")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local right_name = win_bufname(child, "right_win")
  eq(vim.startswith(right_name, "difit://"), true)
  eq(win_bufopt(child, "right_win", "modifiable"), false)
  eq(win_buflines(child, "right_win"), git_show_lines(repo, "feature", paths.modified))
end

T["reopening a second file reuses the same two windows"] = function()
  local built = build(child, "worktree")
  local first = entry_by_path(built.entries, paths.modified)
  local second = entry_by_path(built.entries, paths.new)

  new_view(child)
  view_open(child, built.spec, first)
  eq(win_count(child), 2)
  local left1, right1 = win_id(child, "left_win"), win_id(child, "right_win")

  view_open(child, built.spec, second)
  eq(win_count(child), 2)
  local left2, right2 = win_id(child, "left_win"), win_id(child, "right_win")

  eq(left1, left2)
  eq(right1, right2)
end

T["close(): no difit:// buffers remain and &diff is unset"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)
  local left_win, right_win = win_id(child, "left_win"), win_id(child, "right_win")

  view_close(child)

  local remaining_difit_bufs = child.lua_get([[
    (function()
      local n = 0
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):match("^difit://") then
          n = n + 1
        end
      end
      return n
    end)()
  ]])
  eq(remaining_difit_bufs, 0)

  eq(child.lua_get(string.format("vim.wo[%d].diff", left_win)), false)
  eq(child.lua_get(string.format("vim.wo[%d].diff", right_win)), false)
end

T["worktree mode: editing the right buffer then :write persists to disk"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  child.lua([[
    vim.api.nvim_win_call(_G.__view.right_win, function()
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "-- appended by test" })
      vim.cmd("write")
    end)
  ]])

  local on_disk = vim.fn.readfile(repo.dir .. "/" .. paths.modified)
  eq(on_disk[#on_disk], "-- appended by test")
end

T["binary entries: both windows share a placeholder buffer without diffthis"] = function()
  write_bytes(repo, "bin.dat", "\0\1\2binary")
  repo:commit("feat: add binary file")

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, "bin.dat")
  eq(entry.binary, true)

  new_view(child)
  view_open(child, built.spec, entry)

  eq(win_diff(child, "left_win"), false)
  eq(win_diff(child, "right_win"), false)

  local left_buf = child.lua_get("vim.api.nvim_win_get_buf(_G.__view.left_win)")
  local right_buf = child.lua_get("vim.api.nvim_win_get_buf(_G.__view.right_win)")
  eq(left_buf, right_buf)
  eq(win_buflines(child, "left_win"), { "binary file" })
end

return T
