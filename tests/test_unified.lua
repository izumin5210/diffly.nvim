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

--- `vim.fn.maparg(key, "n", false, true)` for `bufnr`, stripped of its (unserializable)
--- `callback` field before crossing the RPC boundary. Only `buffer == 1` distinguishes an
--- actual buffer-local mapping from `maparg`'s fallback to a same-named global one.
---@param child table
---@param bufnr integer
---@param key string
---@return table
local function buf_maparg(child, bufnr, key)
  return child.lua(
    [[
      local bufnr, key = ...
      local m = vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.maparg(key, "n", false, true)
      end)
      return { buffer = m.buffer, nowait = m.nowait, lhs = m.lhs }
    ]],
    { bufnr, key }
  )
end

---@param m table
---@return boolean
local function mapped(m)
  return m ~= nil and next(m) ~= nil and m.buffer == 1
end

local repo, paths, child

--- Build a real difit.RepoIdentity + entries map (keyed by path) + a difit.DiffSpec for
--- the fixture's `main`...`feature` comparison, and stash them as globals in the child so
--- later `child.lua(...)` calls (one per assertion) can all see the same view instance.
--
--- `_G.ctx` (docs/refactor-v1.md R2/R3) is the `difit.ui.ViewCtx` the view is built with:
--- `anchor` is whatever window is current when this runs (never touched -- views only
--- ever split rightward from it); `actions` records every call into `_G.__actions_log`
--- instead of driving a real session.
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

    _G.__actions_log = {}
    _G.ctx = {
      anchor = vim.api.nvim_get_current_win(),
      claim = nil,
      actions = {
        toggle_viewed = function(path)
          table.insert(_G.__actions_log, { action = "toggle_viewed", path = path })
        end,
        toggle_mode = function()
          table.insert(_G.__actions_log, { action = "toggle_mode" })
        end,
        focus_panel = function()
          table.insert(_G.__actions_log, { action = "focus_panel" })
        end,
        close = function()
          table.insert(_G.__actions_log, { action = "close" })
        end,
      },
    }
    _G.view = unified.new(_G.ctx)
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

T["open(): buffer never sets 'filetype' (docs/refactor-v1.md R4), is a read-only scratch buffer"] = function()
  local result = open(paths.modified)

  eq(result.filetype, "", "difit:// buffers must never fire FileType autocmds")
  eq(result.buftype, "nofile")
  eq(result.modifiable, false)
  local anchor = child.lua_get("_G.ctx.anchor")
  eq(result.bufname, "difit://unified/" .. anchor .. "/" .. paths.modified)
end

T["open(): highlights as 'diff' via treesitter or the legacy 'syntax' option, never 'filetype'"] = function()
  local result = open(paths.modified)

  local highlighted = child.lua(
    [[
      local buf = ...
      local ts_active = vim.treesitter.highlighter.active[buf] ~= nil
      return ts_active or vim.bo[buf].syntax == "diff"
    ]],
    { result.buf }
  )
  eq(highlighted, true)
end

T["open(): reuses the same window across multiple opens"] = function()
  local first = open(paths.modified)
  local before = child.lua([[return #vim.api.nvim_list_wins()]])
  local second = open(paths.new)
  local after = child.lua([[return #vim.api.nvim_list_wins()]])

  eq(second.win, first.win)
  eq(after, before)
end

T["ensure_window: an offered ctx.claim is absorbed instead of splitting a fresh window"] = function()
  child.lua([[
    _G.__claim_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      split = "right",
      win = _G.ctx.anchor,
    })
    _G.ctx.claim = _G.__claim_win
  ]])

  local result = open(paths.modified)

  eq(result.win, child.lua_get("_G.__claim_win"))
  eq(
    child.lua_get("_G.ctx.claim == nil"),
    true,
    "claim is consumed so a later view build never reuses it"
  )
end

-- NOTE: `_G.spec` (built by `setup_child`) has `right = "head"`, so from here down every
-- jump lands in a read-only HEAD blob buffer (finding 7's fix), never the worktree file
-- -- see the divergence regression test further below for *why* that matters. Cross-check
-- expected content against `git show HEAD:<path>` (independent of the worktree) rather
-- than `vim.fn.readfile` (which reads the worktree file) to make that distinction explicit.

---@param path string
---@return string[]
local function head_content(path)
  return vim.fn.systemlist({ "git", "-C", repo.dir, "show", "HEAD:" .. path })
end

---@param bufname string
---@param path string
local function assert_head_blob_bufname(bufname, path)
  eq(vim.startswith(bufname, "difit://"), true)
  eq(vim.endswith(bufname, "/" .. path), true)
end

T["<CR> on a '+' line jumps to the exact line in a read-only HEAD blob (spec.right == 'head')"] = function()
  local result = open(paths.modified)
  local target_line = line_index(result.lines, '+  return "hello, world"')

  local jumped = press_cr_at(target_line)

  assert_head_blob_bufname(jumped.bufname, paths.modified)
  eq(jumped.cursor[1], 4)

  local head_lines = head_content(paths.modified)
  eq(head_lines[4], '  return "hello, world"')

  local buf_props = child.lua([[
    return { buftype = vim.bo[0].buftype, modifiable = vim.bo[0].modifiable }
  ]])
  eq(buf_props.buftype, "nofile")
  eq(buf_props.modifiable, false)
end

T["<CR> on a context line jumps to the corresponding line in the HEAD blob"] = function()
  local result = open(paths.modified)
  local target_line = line_index(result.lines, " function M.hello()")

  local jumped = press_cr_at(target_line)

  assert_head_blob_bufname(jumped.bufname, paths.modified)
  eq(jumped.cursor[1], 3)

  local head_lines = head_content(paths.modified)
  eq(head_lines[3], "function M.hello()")
end

T["<CR> on a '-' line jumps to the hunk's new_start in the HEAD blob"] = function()
  local result = open(paths.modified)
  local target_line = line_index(result.lines, '-  return "hello"')

  local jumped = press_cr_at(target_line)

  assert_head_blob_bufname(jumped.bufname, paths.modified)
  eq(jumped.cursor[1], 1)
end

T["<CR>: right=worktree jump still opens the real worktree file (unchanged behavior)"] = function()
  child.lua([[_G.spec_worktree = vim.tbl_extend("force", {}, spec, { right = "worktree" })]])
  local result = child.lua(
    [[
      local path = ...
      view:open(entries[path], _G.spec_worktree)
      return { lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false) }
    ]],
    { paths.modified }
  )
  local target_line = line_index(result.lines, '+  return "hello, world"')

  local jumped = press_cr_at(target_line)

  eq(realpath(jumped.bufname), realpath(repo.dir .. "/" .. paths.modified))
  eq(jumped.cursor[1], 4)
end

T["<CR>: right=head jump lands at the correct line even when the worktree has diverged from HEAD"] = function()
  local result = open(paths.modified)
  local target_line = line_index(result.lines, '+  return "hello, world"')
  local expected_head_lines = head_content(paths.modified)

  -- Diverge the worktree from HEAD: prepend extra uncommitted lines above the hunk. If
  -- the jump wrongly opened the worktree file (the bug fixed here), the very same target
  -- line would now show completely different content.
  local diverged = { "-- extra worktree-only line 1", "-- extra worktree-only line 2" }
  vim.list_extend(diverged, vim.fn.readfile(repo.dir .. "/" .. paths.modified))
  vim.fn.writefile(diverged, repo.dir .. "/" .. paths.modified)

  local jumped = press_cr_at(target_line)

  assert_head_blob_bufname(jumped.bufname, paths.modified)
  eq(jumped.cursor[1], 4)

  local blob_lines = child.lua([[return vim.api.nvim_buf_get_lines(0, 0, -1, false)]])
  eq(blob_lines, expected_head_lines)
  eq(blob_lines[4], '  return "hello, world"')
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

T["close(): wipes owned buffers and closes its window, leaving ctx.anchor untouched"] = function()
  local first = open(paths.modified)
  open(paths.new)

  child.lua([[view:close()]])

  local buf_valid = child.lua([[return vim.api.nvim_buf_is_valid(...)]], { first.buf })
  eq(buf_valid, false)

  -- docs/refactor-v1.md R2: close() destroys every window this view owns...
  local win_valid = child.lua([[return vim.api.nvim_win_is_valid(...)]], { first.win })
  eq(win_valid, false)

  -- ...and leaves whatever it never owned (ctx.anchor) completely alone.
  local anchor_valid = child.lua([[return vim.api.nvim_win_is_valid(_G.ctx.anchor)]])
  eq(anchor_valid, true)
end

---------------------------------------------------------------------------------------
-- keymaps.diff on the unified buffer: before this fix it only ever carried `v`
-- (toggle_viewed); `s`/`q`/`<leader>e` (toggle_mode/close/focus_panel) are new.
---------------------------------------------------------------------------------------

T["open(): the unified buffer gets keymaps.diff's toggle_mode/close/focus_panel in addition to v"] = function()
  local result = open(paths.modified)

  for _, key in ipairs({ "v", "s", "<leader>e", "q" }) do
    eq(mapped(buf_maparg(child, result.buf, key)), true, key .. " missing on the unified buffer")
  end
end

T["open(): keymaps.diff maps on the unified buffer are set with nowait"] = function()
  local result = open(paths.modified)

  eq(buf_maparg(child, result.buf, "v").nowait, 1)
  eq(buf_maparg(child, result.buf, "s").nowait, 1)
  eq(buf_maparg(child, result.buf, "<leader>e").nowait, 1)
  eq(buf_maparg(child, result.buf, "q").nowait, 1)
end

T["toggle_mode/focus_panel/close actions fire when their keys are pressed"] = function()
  child.lua([[
    _G.__calls = { toggle_mode = 0, focus_panel = 0, close = 0 }
    _G.ctx.actions.toggle_mode = function()
      _G.__calls.toggle_mode = _G.__calls.toggle_mode + 1
    end
    _G.ctx.actions.focus_panel = function()
      _G.__calls.focus_panel = _G.__calls.focus_panel + 1
    end
    _G.ctx.actions.close = function()
      _G.__calls.close = _G.__calls.close + 1
    end
  ]])

  open(paths.modified)

  child.type_keys("s")
  child.type_keys([[\e]]) -- the literal keys `<leader>e` sends with the default mapleader
  child.type_keys("q")

  eq(child.lua_get("_G.__calls"), { toggle_mode = 1, focus_panel = 1, close = 1 })
end

---------------------------------------------------------------------------------------
-- Blob-loading error honesty (docs/refactor-v1.md R4): a REAL git failure (a sha that
-- doesn't resolve to an object) must notify once instead of silently degrading to an
-- empty/truncated render indistinguishable from ordinary "nothing to show" cases.
---------------------------------------------------------------------------------------

local BOGUS_SHA = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

---@param child table
local function install_notify_capture(child)
  child.lua([[
    _G.__notifications = {}
    vim.notify = function(msg, level)
      table.insert(_G.__notifications, { msg = msg, level = level })
    end
  ]])
end

T["<CR>: a bogus head_sha notifies WARN once and still opens an empty read-only blob"] = function()
  child.lua(
    [[
      local path, sha = ...
      entries[path].head_sha = sha
    ]],
    { paths.modified, BOGUS_SHA }
  )

  local result = open(paths.modified)
  local target_line = line_index(result.lines, '+  return "hello, world"')

  install_notify_capture(child)
  local jumped = press_cr_at(target_line)

  assert_head_blob_bufname(jumped.bufname, paths.modified)
  local blob_lines = child.lua([[return vim.api.nvim_buf_get_lines(0, 0, -1, false)]])
  eq(blob_lines, { "" }, "UI still renders (empty) instead of erroring")

  local notes = child.lua_get("_G.__notifications")
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
end

T["open(): a bogus merge_base notifies WARN once and still renders just the header line"] = function()
  child.lua([[spec.merge_base = ...]], { BOGUS_SHA })
  install_notify_capture(child)

  local result = open(paths.modified)

  eq(result.lines, { "diff --git a/" .. paths.modified .. " b/" .. paths.modified })

  local notes = child.lua_get("_G.__notifications")
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
end

return T
