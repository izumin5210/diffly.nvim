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

--- Build a `difit.ui.ViewCtx` (docs/refactor-v1.md R2/R3) in the child: `anchor` is
--- whatever window is current at the time this runs (views must split rightward from it
--- and never touch it -- see the `ensure_windows` regression test below); `actions`
--- records every call into `_G.__actions_log` instead of driving a real session, so
--- keymap-wiring tests can assert on it without needing `init.lua` in the loop. Stashed as
--- `_G.__ctx` so a test can reach in and set `ctx.claim` when it wants to exercise window
--- absorption specifically.
---@param child table
local function new_ctx(child)
  child.lua([[
    _G.__actions_log = {}
    _G.__ctx = {
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
  ]])
end

--- Create the view under test (with a fresh `ctx`, see `new_ctx`) in the child and stash
--- it as a global, so later calls in the same test case can keep driving the same
--- instance (needed to observe window reuse across multiple `open()` calls).
---@param child table
local function new_view(child)
  new_ctx(child)
  child.lua([[ _G.__view = require("difit.ui.sidebyside").new(_G.__ctx) ]])
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

---@param child table
---@param which "left_win"|"right_win"
---@return integer bufnr
local function buf_of(child, which)
  return child.lua_get(string.format("vim.api.nvim_win_get_buf(_G.__view.%s)", which))
end

--- `vim.fn.maparg(key, "n", false, true)`, evaluated with `bufnr` as the current buffer
--- (via `nvim_buf_call`, no window needed) -- the same dict `nvim_buf_get_keymap` entries
--- carry, including `nowait`/`buffer`. Returns an empty table when nothing matches
--- (`maparg` itself would fall back to a *global* mapping sharing the same lhs, so callers
--- use `mapped()` below rather than treating "non-empty" as "buffer-local exists").
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
      -- `m.callback` is a Lua function value -- strip it before crossing the RPC
      -- boundary back to the test-runner process (functions aren't serializable).
      return { buffer = m.buffer, nowait = m.nowait, lhs = m.lhs }
    ]],
    { bufnr, key }
  )
end

--- True iff `m` (from `buf_maparg`) describes an actual BUFFER-LOCAL mapping -- `maparg()`
--- happily returns a *global* mapping's dict when no buffer-local one exists for the same
--- lhs, so checking `next(m) ~= nil` alone would be a false positive in that case.
---@param m table
---@return boolean
local function mapped(m)
  return m ~= nil and next(m) ~= nil and m.buffer == 1
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

  -- ctx.anchor (the window `new_ctx` captured) is never claimed (docs/refactor-v1.md R2)
  -- -- both diff windows are always fresh splits to its right, so it survives alongside
  -- them as a third window.
  eq(win_count(child), 3)
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
  eq(win_count(child), 3) -- ctx.anchor + left_win + right_win
  local left1, right1 = win_id(child, "left_win"), win_id(child, "right_win")

  view_open(child, built.spec, second)
  eq(win_count(child), 3)
  local left2, right2 = win_id(child, "left_win"), win_id(child, "right_win")

  eq(left1, left2)
  eq(right1, right2)
end

---------------------------------------------------------------------------------------
-- ensure_windows() must never claim ctx.anchor itself (docs/refactor-v1.md R2 -- this
-- used to be the "unclaimable current window" regression: switching unified -> sidebyside
-- lands focus on the panel, which the old bare "claim the current window" logic used to
-- grab as left_win -- fatal once the panel got 'winfixbuf', silent window-stealing before
-- that. The explicit ctx.anchor/ctx.claim contract removes the whole class of bug: a view
-- never even looks at "the current window", so there is nothing left to special-case).
---------------------------------------------------------------------------------------

T["ensure_windows: ctx.anchor is never claimed or modified, whatever it shows; two fresh windows are created to its right"] = function()
  child.lua([[
    -- Mirrors what used to require special-casing (winfixbuf, a difit://-named buffer):
    -- neither matters anymore, since ctx.anchor is never even inspected, only split from.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "difit://some-owned-scratch")
    _G.__anchor_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(_G.__anchor_win, buf)
    vim.wo[_G.__anchor_win].winfixbuf = true
    _G.__anchor_buf = buf
  ]])

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  eq(win_count(child), 3, "ctx.anchor survives alongside two fresh diff windows")
  eq(
    child.lua_get("vim.api.nvim_win_get_buf(_G.__anchor_win) == _G.__anchor_buf"),
    true,
    "ctx.anchor keeps its original buffer"
  )
  eq(win_id(child, "left_win") ~= child.lua_get("_G.__anchor_win"), true)
  eq(win_id(child, "right_win") ~= child.lua_get("_G.__anchor_win"), true)
  eq(win_diff(child, "left_win"), true)
  eq(win_diff(child, "right_win"), true)
end

T["ensure_windows: an offered ctx.claim is absorbed as left_win instead of splitting a third window"] = function()
  new_view(child)
  child.lua([[
    _G.__claim_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      split = "right",
      win = _G.__ctx.anchor,
    })
    _G.__ctx.claim = _G.__claim_win
  ]])

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)
  view_open(child, built.spec, entry)

  -- ctx.anchor + the claimed window (now left_win) + one fresh right_win == 3, same as
  -- the no-claim case above -- claiming just avoids an otherwise-redundant extra split.
  eq(win_count(child), 3)
  eq(win_id(child, "left_win"), child.lua_get("_G.__claim_win"))
  eq(
    child.lua_get("_G.__ctx.claim == nil"),
    true,
    "claim is consumed so a later view never reuses it"
  )
end

T["close(): no difit:// buffers remain and both owned windows are closed"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  local anchor = child.lua_get("_G.__ctx.anchor")
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

  -- docs/refactor-v1.md R2: close() destroys every window this view owns...
  eq(child.lua_get(string.format("vim.api.nvim_win_is_valid(%d)", left_win)), false)
  eq(child.lua_get(string.format("vim.api.nvim_win_is_valid(%d)", right_win)), false)
  -- ...and leaves whatever it never owned (ctx.anchor) completely alone.
  eq(child.lua_get(string.format("vim.api.nvim_win_is_valid(%d)", anchor)), true)
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

---------------------------------------------------------------------------------------
-- keymaps.diff / keymaps.file (the fix for "no discoverable way back to the panel, and
-- real file buffers have no difit keymaps at all")
---------------------------------------------------------------------------------------

T["worktree mode: left blob buffer gets the full keymaps.diff set"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local left_buf = buf_of(child, "left_win")
  for _, key in ipairs({ "v", "s", "<leader>e", "q" }) do
    eq(mapped(buf_maparg(child, left_buf, key)), true, key .. " missing on the left blob buffer")
  end
end

T["worktree mode: real right buffer gets keymaps.file (leader-v/s/e), never keymaps.diff"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local real_buf = buf_of(child, "right_win")
  for _, key in ipairs({ "<leader>v", "<leader>s", "<leader>e" }) do
    eq(mapped(buf_maparg(child, real_buf, key)), true, key .. " missing on the real file buffer")
  end
  -- keymaps.diff's own keys must not leak onto the real buffer (it isn't difit-owned).
  eq(mapped(buf_maparg(child, real_buf, "v")), false)
  eq(mapped(buf_maparg(child, real_buf, "q")), false)
end

T["worktree mode: opening a second file removes keymaps.file from the first file's real buffer"] = function()
  local built = build(child, "worktree")
  local first = entry_by_path(built.entries, paths.modified)
  local second = entry_by_path(built.entries, paths.new)

  new_view(child)
  view_open(child, built.spec, first)
  local first_buf = buf_of(child, "right_win")

  view_open(child, built.spec, second)
  local second_buf = buf_of(child, "right_win")
  eq(second_buf ~= first_buf, true, "sanity: the two files use different real buffers")

  for _, key in ipairs({ "<leader>v", "<leader>s", "<leader>e" }) do
    eq(
      mapped(buf_maparg(child, second_buf, key)),
      true,
      key .. " missing on the newly opened buffer"
    )
    eq(
      mapped(buf_maparg(child, first_buf, key)),
      false,
      key .. " still lingers on the previous buffer"
    )
  end
end

T["close(): keymaps.file maps are removed from the real buffer"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)
  local real_buf = buf_of(child, "right_win")

  view_close(child)

  for _, key in ipairs({ "<leader>v", "<leader>s", "<leader>e" }) do
    eq(mapped(buf_maparg(child, real_buf, key)), false, key .. " still mapped after close()")
  end
end

T["head mode: right blob buffer gets keymaps.diff (v/s/<leader>e/q), not keymaps.file"] = function()
  local built = build(child, "head")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local right_buf = buf_of(child, "right_win")
  for _, key in ipairs({ "v", "s", "<leader>e", "q" }) do
    eq(
      mapped(buf_maparg(child, right_buf, key)),
      true,
      key .. " missing on the head-mode right buffer"
    )
  end
  eq(
    mapped(buf_maparg(child, right_buf, "<leader>v")),
    false,
    "keymaps.file must not leak into a difit-owned buffer"
  )
end

T["keymaps.file.toggle_mode = false disables only that key"] = function()
  child.lua([[require("difit.config").setup({ keymaps = { file = { toggle_mode = false } } })]])

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local real_buf = buf_of(child, "right_win")
  eq(mapped(buf_maparg(child, real_buf, "<leader>s")), false)
  eq(mapped(buf_maparg(child, real_buf, "<leader>v")), true)
  eq(mapped(buf_maparg(child, real_buf, "<leader>e")), true)
end

T["diff and file keymaps are all set with nowait"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local left_buf = buf_of(child, "left_win")
  eq(buf_maparg(child, left_buf, "v").nowait, 1)

  local real_buf = buf_of(child, "right_win")
  eq(buf_maparg(child, real_buf, "<leader>v").nowait, 1)
end

T["regression: buffer-local keymaps.file.toggle_viewed fires immediately despite a longer global mapping sharing its prefix"] = function()
  -- The reported bug: without `nowait`, a user's own global mapping that happens to share
  -- our key as a prefix (e.g. a global `<leader>vs`) wins the ambiguity, because Neovim
  -- waits out 'timeoutlen' for a possible continuation instead of firing our shorter
  -- mapping right away. Bound the wait so a future regression fails fast instead of
  -- hanging this test for a full 'timeoutlen'.
  child.o.timeoutlen = 50

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  child.lua([[
    _G.__global_fired = false
    _G.__seam_fired = false
    vim.keymap.set("n", "<leader>vx", function()
      _G.__global_fired = true
    end)
    _G.__ctx.actions.toggle_viewed = function()
      _G.__seam_fired = true
    end
  ]])
  view_open(child, built.spec, entry)
  -- `open()` already focuses the right window (the real file buffer) via
  -- `focus_right_first_change`.

  child.type_keys([[\v]]) -- the literal keys `<leader>v` sends with the default mapleader

  eq(child.is_blocked(), false, "difit's mapping must fire immediately, never wait on ambiguity")
  eq(child.lua_get("_G.__seam_fired"), true, "the buffer-local toggle_viewed callback fired")
  eq(
    child.lua_get("_G.__global_fired"),
    false,
    "the longer global mapping never got a chance to fire"
  )
end

return T
