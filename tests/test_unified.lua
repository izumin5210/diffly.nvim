-- Tests for lua/difit/ui/unified.lua (WP-G): the read-only unified/patch diff view.
-- Runs in a child Neovim (real buffers/windows) against the standard fixture repo;
-- git is never mocked -- entry/spec data comes from real `difit.git` calls.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

--- Resolve symlinks on both sides before comparing paths. On macOS `$TMPDIR` resolves
--- through a `/private` symlink, so a path built from `repo.dir` can differ textually
--- from what `:edit` reports (which goes through `vim.fn.expand("%:p")`-style
--- resolution) while still pointing at the same file (mirrors tests/test_git.lua).
---@param path string
---@return string
local function realpath(path)
  return vim.uv.fs_realpath(path)
end

local repo, paths, child

--- Build a real difit.RepoIdentity + entries map (keyed by path) + a difit.DiffSpec for
--- the fixture's `main`...`feature` comparison, and stash them as globals in the child so
--- later `child.lua(...)` calls (one per assertion) can all see the same view instance.
local function setup_child()
  child.lua([[
    _G.git = require("difit.git")
    _G.unified = require("difit.ui.unified")

    _G.repo = git.repo_identity(vim.fn.getcwd())
    _G.base_sha = vim.trim(vim.fn.system({ "git", "-C", repo.toplevel, "rev-parse", "main" }))

    local entries = git.diff_files(repo, base_sha, "head", { include_untracked = true })
    _G.entries = {}
    for _, e in ipairs(entries) do
      _G.entries[e.path] = e
    end

    _G.spec = {
      repo = repo,
      base_ref = "main",
      merge_base = base_sha,
      right = "head",
      review_key = { kind = "branch", repo = repo.id, base = "main", head = "feature" },
    }
    _G.view = unified.new()
  ]])
end

--- Open `path` in the shared view, returning the resulting window/buffer state.
---@param path string
local function open(path)
  return child.lua(
    [[
      local path = ...
      view:open(entries[path], spec)
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_get_current_buf()
      return {
        win = win,
        buf = buf,
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        filetype = vim.bo[buf].filetype,
        buftype = vim.bo[buf].buftype,
        modifiable = vim.bo[buf].modifiable,
        bufname = vim.api.nvim_buf_get_name(buf),
        win_count = #vim.api.nvim_tabpage_list_wins(0),
      }
    ]],
    { path }
  )
end

--- Open a synthetic binary FileEntry (binary rendering never calls into git, so there is
--- nothing to fake here beyond a plain FileEntry-shaped table).
local function open_binary()
  return child.lua([[
    local entry = {
      path = "bin.dat",
      old_path = nil,
      status = "M",
      untracked = false,
      binary = true,
      additions = 0,
      deletions = 0,
      base_sha = "aaaaaaa",
      head_sha = "bbbbbbb",
    }
    view:open(entry, spec)
    local buf = vim.api.nvim_get_current_buf()
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  ]])
end

--- Move the cursor to `line` in the current (unified) window, press <CR>, and report
--- where the input landed.
---@param line integer
local function press_cr_at(line)
  child.api.nvim_win_set_cursor(0, { line, 0 })
  child.type_keys("<CR>")
  return child.lua([[
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    return {
      bufname = vim.api.nvim_buf_get_name(buf),
      cursor = vim.api.nvim_win_get_cursor(win),
    }
  ]])
end

--- Index (1-based) of the first buffer line whose content is exactly `content`.
---@param lines string[]
---@param content string
---@return integer
local function line_index(lines, content)
  for i, l in ipairs(lines) do
    if l == content then
      return i
    end
  end
  error("line not found: " .. content)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      repo, paths = helpers.fixture_branch_repo()
      child = helpers.new_child(repo.dir)
      setup_child()
    end,
    post_case = function()
      child.stop()
      repo:destroy()
    end,
  },
})

T["open(): renders the diff --git header, hunk header and +/- body lines"] = function()
  local result = open(paths.modified)

  eq(result.lines[1], "diff --git a/" .. paths.modified .. " b/" .. paths.modified)
  eq(vim.tbl_contains(result.lines, "@@ -1,7 +1,11 @@"), true)
  eq(vim.tbl_contains(result.lines, '-  return "hello"'), true)
  eq(vim.tbl_contains(result.lines, '+  return "hello, world"'), true)
  eq(vim.tbl_contains(result.lines, "+function M.extra()"), true)
end

T["open(): buffer has filetype=diff, is a read-only scratch buffer"] = function()
  local result = open(paths.modified)

  eq(result.filetype, "diff")
  eq(result.buftype, "nofile")
  eq(result.modifiable, false)
  eq(result.bufname, "difit://unified/" .. paths.modified)
end

T["open(): reuses the same window across multiple opens"] = function()
  local first = open(paths.modified)
  local before = child.lua([[return #vim.api.nvim_list_wins()]])
  local second = open(paths.new)
  local after = child.lua([[return #vim.api.nvim_list_wins()]])

  eq(second.win, first.win)
  eq(after, before)
end

T["<CR> on a '+' line jumps to the exact new-file line"] = function()
  local result = open(paths.modified)
  local target_line = line_index(result.lines, '+  return "hello, world"')

  local jumped = press_cr_at(target_line)

  eq(realpath(jumped.bufname), realpath(repo.dir .. "/" .. paths.modified))
  eq(jumped.cursor[1], 4)

  local real_lines = vim.fn.readfile(repo.dir .. "/" .. paths.modified)
  eq(real_lines[4], '  return "hello, world"')
end

T["<CR> on a context line jumps to the corresponding new-file line"] = function()
  local result = open(paths.modified)
  local target_line = line_index(result.lines, " function M.hello()")

  local jumped = press_cr_at(target_line)

  eq(realpath(jumped.bufname), realpath(repo.dir .. "/" .. paths.modified))
  eq(jumped.cursor[1], 3)

  local real_lines = vim.fn.readfile(repo.dir .. "/" .. paths.modified)
  eq(real_lines[3], "function M.hello()")
end

T["<CR> on a '-' line jumps to the hunk's new_start"] = function()
  local result = open(paths.modified)
  local target_line = line_index(result.lines, '-  return "hello"')

  local jumped = press_cr_at(target_line)

  eq(realpath(jumped.bufname), realpath(repo.dir .. "/" .. paths.modified))
  eq(jumped.cursor[1], 1)
end

T["<CR> on the diff --git header line is a no-op"] = function()
  local result = open(paths.modified)
  local unified_win = result.win
  local unified_buf = result.buf

  press_cr_at(1)

  local still_here = child.lua([[
    return { win = vim.api.nvim_get_current_win(), buf = vim.api.nvim_get_current_buf() }
  ]])
  eq(still_here.win, unified_win)
  eq(still_here.buf, unified_buf)
end

T["open(): binary entries render a single placeholder line"] = function()
  local lines = open_binary()
  eq(lines, { "binary file" })
end

T["open(): deleted files render without error"] = function()
  local ok = child.lua(
    [[
      local path = ...
      local ok = pcall(function() view:open(entries[path], spec) end)
      return ok
    ]],
    { paths.deleted }
  )
  eq(ok, true)

  local result = open(paths.deleted)
  eq(result.lines[1], "diff --git a/" .. paths.deleted .. " b/" .. paths.deleted)
  eq(vim.tbl_contains(result.lines, "-local M = {}"), true)
end

T["open(): renamed files render without error, using old_path in the header"] = function()
  local result = open(paths.renamed_to)
  eq(result.lines[1], "diff --git a/" .. paths.renamed_from .. " b/" .. paths.renamed_to)
end

T["close(): wipes owned buffers and closes its window"] = function()
  local first = open(paths.modified)
  open(paths.new)

  child.lua([[view:close()]])

  local buf_valid = child.lua([[return vim.api.nvim_buf_is_valid(...)]], { first.buf })
  eq(buf_valid, false)

  local win_valid = child.lua([[return vim.api.nvim_win_is_valid(...)]], { first.win })
  eq(win_valid, false)
end

return T
