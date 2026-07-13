-- Tests for lua/diffly/ui/sidebyside.lua (WP-F): the two-window vertical diff pair.
-- Runs entirely inside a child Neovim (real windows/buffers are required, not fakeable),
-- driven from the test-runner process via `child.lua`. Entry/spec tables are built from
-- real git plumbing (`diffly.git`) against `helpers.fixture_branch_repo()` -- no mocks.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

--- Build a diffly.DiffSpec + diffly.FileEntry[] pair for the fixture repo (main...feature)
--- entirely inside the child, using the same git plumbing the real session would use.
--- `spec.generated_attrs` is populated exactly the way `session.lua`'s `load_generated_attrs`
--- does (a batched `git check-attr linguist-generated` over every entry), since this
--- helper bypasses `diffly.Session` entirely -- tests exercising `.gitattributes`
--- overrides need it present, same as production.
---@param child table
---@param right "worktree"|"head"
---@return table @{ spec = diffly.DiffSpec, entries = diffly.FileEntry[] }
local function build(child, right)
  return child.lua(
    [[
      local right = ...
      local git = require("diffly.git")
      local config = require("diffly.config")
      local repo = git.repo_identity(vim.fn.getcwd())
      local merge_base = git.merge_base(repo, "main", "feature")
      local entries = git.diff_files(repo, merge_base, right, { include_untracked = true })
      local generated_attrs = {}
      if config.get().collapse_generated then
        local paths = {}
        for _, e in ipairs(entries) do
          table.insert(paths, e.path)
        end
        generated_attrs = git.check_attrs(repo, "linguist-generated", paths) or {}
      end
      local spec = {
        repo = repo,
        base_ref = "main",
        merge_base = merge_base,
        right = right,
        review_key = { kind = "branch", repo = repo.id, base = "main", head = "feature" },
        generated_attrs = generated_attrs,
      }
      return { spec = spec, entries = entries }
    ]],
    { right }
  )
end

---@param entries diffly.FileEntry[]
---@param path string
---@return diffly.FileEntry
local function entry_by_path(entries, path)
  for _, e in ipairs(entries) do
    if e.path == path then
      return e
    end
  end
  error("no entry for path " .. path)
end

--- Build a `diffly.ui.ViewCtx` (docs/architecture.md "View contract") in the child: `anchor` is
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
        -- Render-time getters the comment repaint pulls data through; tests drive them
        -- via the two globals instead of a real session.
        comments_for = function(path)
          return (_G.__fake_threads or {})[path] or {}
        end,
        comments_collapsed = function()
          return _G.__fake_collapsed == true
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
  child.lua([[ _G.__view = require("diffly.ui.sidebyside").new(_G.__ctx) ]])
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

--- The per-session discriminator (docs/architecture.md "Rendering") every owned buffer name
--- embeds -- `ctx.anchor`, the window `new_ctx` captured as the split point. Buffer-name
--- assertions below build the exact expected name around this instead of hardcoding the
--- pre-R4 `diffly://<kind>/<path>` shape.
---@param child table
---@return integer
local function ctx_anchor(child)
  return child.lua_get("_G.__ctx.anchor")
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

--- Independent cross-check for committed content (bypasses diffly.git.file_content, which
--- is what the module under test uses internally).
---@param repo diffly.test.Repo
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
---@param repo diffly.test.Repo
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

  -- ctx.anchor (the window `new_ctx` captured) is never claimed (docs/architecture.md "View contract")
  -- -- both diff windows are always fresh splits to its right, so it survives alongside
  -- them as a third window.
  eq(win_count(child), 3)
  eq(win_diff(child, "left_win"), true)
  eq(win_diff(child, "right_win"), true)

  local left_name = win_bufname(child, "left_win")
  eq(vim.startswith(left_name, "diffly://"), true)
  eq(win_bufopt(child, "left_win", "modifiable"), false)
  eq(win_bufopt(child, "left_win", "buftype"), "nofile")

  local right_name = win_bufname(child, "right_win")
  eq(vim.endswith(right_name, "/" .. paths.modified), true)
  eq(vim.startswith(right_name, "diffly://"), false)
  eq(win_bufopt(child, "right_win", "modifiable"), true)
end

T["both windows remap native diff groups asymmetrically via 'winhighlight'"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  -- Native diff mode's group semantics are symmetric ("lines missing on the other side"
  -- are DiffAdd in BOTH windows), so the before pane would paint deleted lines green.
  -- The window-local remap gives each pane one color family: left/old = red, right/new =
  -- green, fillers muted out of the scan (docs/design.md "Side-by-side").
  eq(
    child.lua_get([[vim.wo[_G.__view.left_win].winhighlight]]),
    "DiffAdd:DifflyDiffOldLine,DiffChange:DifflyDiffOldLine,"
      .. "DiffText:DifflyDiffOldText,DiffTextAdd:DifflyDiffOldText,DiffDelete:DifflyDiffFiller"
  )
  eq(
    child.lua_get([[vim.wo[_G.__view.right_win].winhighlight]]),
    "DiffAdd:DifflyDiffNewLine,DiffChange:DifflyDiffNewLine,"
      .. "DiffText:DifflyDiffNewText,DiffTextAdd:DifflyDiffNewText,DiffDelete:DifflyDiffFiller"
  )
end

T["added file: left window is an empty scratch buffer"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.new)
  eq(entry.base_sha, nil)

  new_view(child)
  view_open(child, built.spec, entry)

  eq(win_bufname(child, "left_win"), "diffly://empty/" .. ctx_anchor(child) .. "/" .. paths.new)
  eq(win_bufopt(child, "left_win", "modifiable"), false)
  eq(win_buflines(child, "left_win"), { "" })
end

T["deleted file: right window is an empty scratch buffer"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.deleted)
  eq(entry.head_sha, nil)

  new_view(child)
  view_open(child, built.spec, entry)

  eq(
    win_bufname(child, "right_win"),
    "diffly://deleted/" .. ctx_anchor(child) .. "/" .. paths.deleted
  )
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
  eq(vim.startswith(right_name, "diffly://"), true)
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
-- ensure_windows() must never claim ctx.anchor itself (docs/architecture.md "View contract" -- this
-- used to be the "unclaimable current window" regression: switching unified -> sidebyside
-- lands focus on the panel, which the old bare "claim the current window" logic used to
-- grab as left_win -- fatal once the panel got 'winfixbuf', silent window-stealing before
-- that. The explicit ctx.anchor/ctx.claim contract removes the whole class of bug: a view
-- never even looks at "the current window", so there is nothing left to special-case).
---------------------------------------------------------------------------------------

T["focus_line(): focuses the right window at the requested line, clamped to EOF"] = function()
  local built = build(child, "worktree")
  new_view(child)
  view_open(child, built.spec, entry_by_path(built.entries, paths.modified))

  -- Move focus away first so the focus switch is actually observable.
  child.lua("vim.api.nvim_set_current_win(_G.__ctx.anchor)")
  child.lua("_G.__view:focus_line(4)")
  eq(child.lua_get("vim.api.nvim_get_current_win()"), win_id(child, "right_win"))
  eq(child.lua_get("vim.api.nvim_win_get_cursor(_G.__view.right_win)[1]"), 4)

  child.lua("_G.__view:focus_line(999)")
  eq(
    child.lua_get("vim.api.nvim_win_get_cursor(_G.__view.right_win)[1]"),
    child.lua_get("vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(_G.__view.right_win))")
  )
end

T["ensure_windows: ctx.anchor is never claimed or modified, whatever it shows; two fresh windows are created to its right"] = function()
  child.lua([[
    -- Mirrors what used to require special-casing (winfixbuf, a diffly://-named buffer):
    -- neither matters anymore, since ctx.anchor is never even inspected, only split from.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "diffly://some-owned-scratch")
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

T["close(): no diffly:// buffers remain and both owned windows are closed"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  local anchor = child.lua_get("_G.__ctx.anchor")
  view_open(child, built.spec, entry)
  local left_win, right_win = win_id(child, "left_win"), win_id(child, "right_win")

  view_close(child)

  local remaining_diffly_bufs = child.lua_get([[
    (function()
      local n = 0
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):match("^diffly://") then
          n = n + 1
        end
      end
      return n
    end)()
  ]])
  eq(remaining_diffly_bufs, 0)

  -- docs/architecture.md "View contract": close() destroys every window this view owns...
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

--- Regression (the "focus lands on the panel after switching modes on a binary file"
--- bug): `ui/unified.lua`'s and this view's binary placeholder buffers are named
--- identically for the same file (`ui/scratch.lua` naming has no per-view component), so
--- a fresh unified view sharing a `ctx` this test then hands to a fresh sidebyside view
--- reproduces the exact collision `Session:set_mode` creates in production -- opening the
--- incoming (sidebyside) view before closing the outgoing (unified) one (docs/architecture.md
--- "View contract"). Before the `close()` fix (win_findbuf guard on the owned-buffer
--- delete loop), the outgoing view's `close()` force-deleted that shared buffer out from
--- under sidebyside's already-focused window, and Neovim closes every window still
--- showing a buffer it deletes -- silently destroying sidebyside's window and dropping
--- focus back to `ctx.anchor` (the panel, in production).
T["regression: an outgoing unified view's close() must not steal sidebyside's window when both show the same binary placeholder"] = function()
  local built = build(child, "worktree")
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

  new_ctx(child)
  child.lua(
    [[
      local unified = require("diffly.ui.unified")
      local spec, entry = ...
      -- Mirrors Session:set_mode's order: the outgoing view opens first...
      _G.__old_view = unified.new(_G.__ctx)
      _G.__old_view:open(entry, spec)
    ]],
    { built.spec, entry }
  )

  -- ...then the incoming view (sidebyside, this file's own `_G.__view`) opens the SAME
  -- entry BEFORE the outgoing one closes.
  child.lua([[ _G.__view = require("diffly.ui.sidebyside").new(_G.__ctx) ]])
  view_open(child, built.spec, entry)
  local right_win_before_close = win_id(child, "right_win")

  child.lua([[ _G.__old_view:close() ]])

  eq(
    child.lua_get("vim.api.nvim_get_current_win()"),
    right_win_before_close,
    "focus must stay on sidebyside's right window, not fall back to ctx.anchor"
  )
  eq(child.lua_get(string.format("vim.api.nvim_win_is_valid(%d)", right_win_before_close)), true)
end

---------------------------------------------------------------------------------------
-- Large-file guard (config.max_file_size, ui/guard.lua): an entry whose content
-- would exceed the configured limit renders a placeholder styled like the binary one
-- (both windows, no diffthis) instead of loading it, with a `L` key to force-load it for
-- the rest of this view instance. Binary detection always takes precedence.
---------------------------------------------------------------------------------------

---@param child table
---@param max integer|false
local function set_max_file_size(child, max)
  child.lua("require('diffly.config').setup({ max_file_size = ... })", { max })
end

T["oversized file: both windows share a placeholder with the size text instead of the real content"] = function()
  set_max_file_size(child, 64)
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  eq(win_diff(child, "left_win"), false)
  eq(win_diff(child, "right_win"), false)

  local left_buf = buf_of(child, "left_win")
  local right_buf = buf_of(child, "right_win")
  eq(left_buf, right_buf)

  local lines = win_buflines(child, "left_win")
  eq(#lines, 1)
  eq(lines[1]:find("file too large", 1, true) ~= nil, true)
  eq(lines[1]:find("press L to load", 1, true) ~= nil, true)
end

T["oversized file: pressing L force-loads the real diff, and it stays loaded on reopen"] = function()
  set_max_file_size(child, 64)
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)
  eq(win_buflines(child, "left_win")[1]:find("file too large", 1, true) ~= nil, true)

  -- `open()` already focuses the right window (`focus_right_first_change`), and the
  -- placeholder is shared by both windows -- pressing L from there triggers the same
  -- buffer-local mapping either way.
  child.type_keys("L")

  eq(vim.endswith(win_bufname(child, "right_win"), "/" .. paths.modified), true)
  eq(win_diff(child, "left_win"), true, "diffthis re-enabled once the real content loads")
  eq(win_diff(child, "right_win"), true)

  -- Reopening the same path later (e.g. navigating away and back) must not show the
  -- placeholder again -- `force_loaded` persists for the rest of this view instance.
  view_open(child, built.spec, entry)
  eq(vim.endswith(win_bufname(child, "right_win"), "/" .. paths.modified), true)
end

T["oversized file: max_file_size = false disables the guard entirely"] = function()
  set_max_file_size(child, false)
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  eq(vim.endswith(win_bufname(child, "right_win"), "/" .. paths.modified), true)
  eq(win_diff(child, "left_win"), true)
end

T["binary entries take precedence over the size guard -- no size text, no L key"] = function()
  set_max_file_size(child, 1) -- tiny enough that even "binary file" would exceed it, if checked
  write_bytes(repo, "bin.dat", "\0\1\2binary")
  repo:commit("feat: add binary file")

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, "bin.dat")

  new_view(child)
  view_open(child, built.spec, entry)

  eq(win_buflines(child, "left_win"), { "binary file" })
  eq(mapped(buf_maparg(child, buf_of(child, "left_win"), "L")), false)
end

---------------------------------------------------------------------------------------
-- Generated-file guard (config.collapse_generated, ui/guard.lua/lua/diffly/generated.lua):
-- GitHub-parity collapsing of vendored/lockfile/codegen output. Shares the exact same
-- placeholder/`L`-key mechanics as the large-file guard above; only the message and the
-- detection source (a `.gitattributes linguist-generated` override, else content
-- heuristics) differ.
---------------------------------------------------------------------------------------

---@param child table
---@param enabled boolean
local function set_collapse_generated(child, enabled)
  child.lua("require('diffly.config').setup({ collapse_generated = ... })", { enabled })
end

T["generated file (heuristic match): both windows share a placeholder with the generated text instead of the real content"] = function()
  repo:write("package-lock.json", { "{", '  "name": "fixture"', "}" })
  repo:commit("chore: add package-lock.json")

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, "package-lock.json")

  new_view(child)
  view_open(child, built.spec, entry)

  eq(win_diff(child, "left_win"), false)
  eq(win_diff(child, "right_win"), false)

  local left_buf = buf_of(child, "left_win")
  local right_buf = buf_of(child, "right_win")
  eq(left_buf, right_buf)

  local lines = win_buflines(child, "left_win")
  eq(#lines, 1)
  eq(lines[1], "Generated files are not rendered by default -- press L to load")
end

T["generated file: pressing L force-loads the real diff, and it stays loaded on reopen"] = function()
  repo:write("package-lock.json", { "{", '  "name": "fixture"', "}" })
  repo:commit("chore: add package-lock.json")

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, "package-lock.json")

  new_view(child)
  view_open(child, built.spec, entry)
  eq(win_buflines(child, "left_win")[1]:find("press L to load", 1, true) ~= nil, true)

  child.type_keys("L")

  eq(vim.endswith(win_bufname(child, "right_win"), "/package-lock.json"), true)
  eq(win_diff(child, "left_win"), true, "diffthis re-enabled once the real content loads")

  -- Reopening later must not show the placeholder again -- `force_loaded` persists for the
  -- rest of this view instance, same guarantee the size guard makes.
  view_open(child, built.spec, entry)
  eq(vim.endswith(win_bufname(child, "right_win"), "/package-lock.json"), true)
end

T["generated file: collapse_generated = false disables the guard entirely"] = function()
  set_collapse_generated(child, false)
  repo:write("package-lock.json", { "{", '  "name": "fixture"', "}" })
  repo:commit("chore: add package-lock.json")

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, "package-lock.json")

  new_view(child)
  view_open(child, built.spec, entry)

  eq(vim.endswith(win_bufname(child, "right_win"), "/package-lock.json"), true)
  eq(win_diff(child, "left_win"), true)
end

T[".gitattributes linguist-generated=false forces a real render despite a matching heuristic"] = function()
  repo:write("package-lock.json", { "{", '  "name": "fixture"', "}" })
  repo:write(".gitattributes", { "package-lock.json -linguist-generated" })
  repo:commit("chore: add package-lock.json with an override")

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, "package-lock.json")

  new_view(child)
  view_open(child, built.spec, entry)

  eq(vim.endswith(win_bufname(child, "right_win"), "/package-lock.json"), true)
  eq(win_diff(child, "left_win"), true)
end

T[".gitattributes linguist-generated forces a placeholder on an otherwise-innocent file"] = function()
  repo:write(".gitattributes", { paths.modified .. " linguist-generated" })
  repo:commit("chore: mark modified file as generated")

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local lines = win_buflines(child, "left_win")
  eq(#lines, 1)
  eq(lines[1], "Generated files are not rendered by default -- press L to load")
end

T["size guard takes precedence over the generated-file guard: an oversized generated-looking file shows the size message"] = function()
  set_max_file_size(child, 16)
  repo:write(
    "package-lock.json",
    { "{", '  "name": "fixture, made long enough to exceed the tiny limit"', "}" }
  )
  repo:commit("chore: add oversized package-lock.json")

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, "package-lock.json")

  new_view(child)
  view_open(child, built.spec, entry)

  local lines = win_buflines(child, "left_win")
  eq(#lines, 1)
  eq(
    lines[1]:find("file too large", 1, true) ~= nil,
    true,
    "size message wins, not the generated one"
  )
  eq(lines[1]:find("Generated files", 1, true) ~= nil, false)
end

---------------------------------------------------------------------------------------
-- keymaps.diff / keymaps.universal (the two-layer model, docs/design.md "Interface"):
-- diffly-owned buffers (the left blob, and the right blob in head mode) get BOTH groups;
-- the real worktree right buffer gets ONLY keymaps.universal, never keymaps.diff.
---------------------------------------------------------------------------------------

T["worktree mode: left blob buffer gets keymaps.diff AND keymaps.universal"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local left_buf = buf_of(child, "left_win")
  for _, key in ipairs({ "v", "s", "<leader>e", "q" }) do
    eq(mapped(buf_maparg(child, left_buf, key)), true, key .. " missing (keymaps.diff)")
  end
  -- keymaps.universal's own keys (toggle_viewed/toggle_mode) are distinct lhs from
  -- keymaps.diff's by default -- both must be present on the same owned buffer.
  for _, key in ipairs({ "<leader>v", "<leader>s" }) do
    eq(mapped(buf_maparg(child, left_buf, key)), true, key .. " missing (keymaps.universal)")
  end
end

T["worktree mode: real right buffer gets keymaps.universal (leader-v/s/e), never keymaps.diff"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local real_buf = buf_of(child, "right_win")
  for _, key in ipairs({ "<leader>v", "<leader>s", "<leader>e" }) do
    eq(mapped(buf_maparg(child, real_buf, key)), true, key .. " missing on the real file buffer")
  end
  -- keymaps.diff's own keys must not leak onto the real buffer (it isn't diffly-owned).
  eq(mapped(buf_maparg(child, real_buf, "v")), false)
  eq(mapped(buf_maparg(child, real_buf, "q")), false)
end

T["worktree mode: opening a second file removes keymaps.universal from the first file's real buffer"] = function()
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

T["close(): keymaps.universal maps are removed from the real buffer"] = function()
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

T["head mode: right blob buffer gets keymaps.diff (v/s/<leader>e/q) AND keymaps.universal (<leader>v/<leader>s)"] = function()
  local built = build(child, "head")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local right_buf = buf_of(child, "right_win")
  for _, key in ipairs({ "v", "s", "<leader>e", "q" }) do
    eq(
      mapped(buf_maparg(child, right_buf, key)),
      true,
      key .. " missing on the head-mode right buffer (keymaps.diff)"
    )
  end
  -- Unlike the pre-universal-layer design, an owned buffer legitimately carries
  -- keymaps.universal's keys too now -- it isn't "leaking", it's the two-layer model.
  for _, key in ipairs({ "<leader>v", "<leader>s" }) do
    eq(
      mapped(buf_maparg(child, right_buf, key)),
      true,
      key .. " missing on the head-mode right buffer (keymaps.universal)"
    )
  end
end

T["keymaps.universal.toggle_mode = false disables only that key on the real buffer"] = function()
  child.lua(
    [[require("diffly.config").setup({ keymaps = { universal = { toggle_mode = false } } })]]
  )

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local real_buf = buf_of(child, "right_win")
  eq(mapped(buf_maparg(child, real_buf, "<leader>s")), false)
  eq(mapped(buf_maparg(child, real_buf, "<leader>v")), true)
  eq(mapped(buf_maparg(child, real_buf, "<leader>e")), true)
end

T["keymaps.universal.toggle_mode = false disables only that key on an owned buffer too, leaving keymaps.diff's own toggle_mode intact"] = function()
  child.lua(
    [[require("diffly.config").setup({ keymaps = { universal = { toggle_mode = false } } })]]
  )

  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local left_buf = buf_of(child, "left_win")
  eq(mapped(buf_maparg(child, left_buf, "<leader>s")), false, "keymaps.universal.toggle_mode")
  eq(mapped(buf_maparg(child, left_buf, "s")), true, "keymaps.diff.toggle_mode is unaffected")
  eq(mapped(buf_maparg(child, left_buf, "<leader>v")), true, "other universal keys are unaffected")
end

T["diff and universal keymaps are all set with nowait"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  view_open(child, built.spec, entry)

  local left_buf = buf_of(child, "left_win")
  eq(buf_maparg(child, left_buf, "v").nowait, 1)
  eq(buf_maparg(child, left_buf, "<leader>v").nowait, 1)

  local real_buf = buf_of(child, "right_win")
  eq(buf_maparg(child, real_buf, "<leader>v").nowait, 1)
end

T["regression: buffer-local keymaps.universal.toggle_viewed fires immediately despite a longer global mapping sharing its prefix"] = function()
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

  eq(child.is_blocked(), false, "diffly's mapping must fire immediately, never wait on ambiguity")
  eq(child.lua_get("_G.__seam_fired"), true, "the buffer-local toggle_viewed callback fired")
  eq(
    child.lua_get("_G.__global_fired"),
    false,
    "the longer global mapping never got a chance to fire"
  )
end

---------------------------------------------------------------------------------------
-- Blob-loading error honesty (docs/architecture.md "Rendering"): `entry.base_sha`/`head_sha` being
-- `nil` is a legitimate empty buffer (added/deleted files, covered above); a non-nil sha
-- that `git.file_content` still fails to load (e.g. it doesn't resolve to a real object)
-- is a REAL git failure and must not be silently indistinguishable from that legitimate
-- case -- it should notify once and still render an empty buffer, so the UI survives.
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

T["set_left(): a bogus base_sha notifies WARN once and still renders an empty buffer"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)
  entry.base_sha = BOGUS_SHA

  new_view(child)
  install_notify_capture(child)
  view_open(child, built.spec, entry)

  eq(win_buflines(child, "left_win"), { "" }, "UI still renders (empty) instead of erroring")

  local notes = child.lua_get("_G.__notifications")
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
end

T["set_right_head(): a bogus head_sha notifies WARN once and still renders an empty buffer"] = function()
  local built = build(child, "head")
  local entry = entry_by_path(built.entries, paths.modified)
  entry.head_sha = BOGUS_SHA

  new_view(child)
  install_notify_capture(child)
  view_open(child, built.spec, entry)

  eq(win_buflines(child, "right_win"), { "" }, "UI still renders (empty) instead of erroring")

  local notes = child.lua_get("_G.__notifications")
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
end

---------------------------------------------------------------------------------------
-- comment rendering (ui/comments.lua wired through this view's own comment_ns; threads
-- come from the fake `ctx.actions` getters, driven via `_G.__fake_threads`)
---------------------------------------------------------------------------------------

--- A minimal diffly.CommentThread the fake `comments_for` getter serves up.
---@param path string
---@param side "base"|"head"
---@param line integer
---@param body string
local function fake_thread(path, side, line, body)
  return {
    id = "c1",
    path = path,
    anchor = { side = side, start_line = line, end_line = line, sha = "s", snapshot = { "x" } },
    messages = { { body = body, created_at = "2026-07-12T00:00:00Z" } },
  }
end

---@param child_ table
---@param bufnr integer
---@return table[]
local function comment_marks(child_, bufnr)
  return child_.lua(
    [[
      local buf = ...
      return vim.api.nvim_buf_get_extmarks(buf, _G.__view.comment_ns, 0, -1, { details = true })
    ]],
    { bufnr }
  )
end

T["comments: base threads render into the left blob, head threads into the right file"] = function()
  local built = build(child, "worktree")
  local entry = entry_by_path(built.entries, paths.modified)

  new_view(child)
  child.lua("_G.__fake_threads = ...", {
    {
      [paths.modified] = {
        fake_thread(paths.modified, "base", 4, "base-side note"),
        fake_thread(paths.modified, "head", 4, "head-side note"),
      },
    },
  })
  view_open(child, built.spec, entry)

  -- Boxed shape: header (✎ draft), body, footer -- the body sits on line 2.
  local left = comment_marks(child, buf_of(child, "left_win"))
  eq(#left, 1)
  eq(left[1][2], 3)
  eq(left[1][4].virt_lines[2][2][1], "base-side note")

  local right = comment_marks(child, buf_of(child, "right_win"))
  eq(#right, 1)
  eq(right[1][2], 3)
  eq(right[1][4].virt_lines[2][2][1], "head-side note")
end

---@param child_ table
---@param bufnr integer
---@param mode string
---@param lhs string
---@return boolean
local function has_buf_map(child_, bufnr, mode, lhs)
  return child_.lua(
    [[
      local bufnr, mode, lhs = ...
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
        if m.lhs == lhs then
          return true
        end
      end
      return false
    ]],
    { bufnr, mode, lhs }
  )
end

T["comments: owned buffers get comment keys (x-mode add included); real and placeholder buffers don't"] = function()
  local built = build(child, "worktree")

  new_view(child)
  view_open(child, built.spec, entry_by_path(built.entries, paths.modified))

  -- Owned left blob: single-key comment family, including the visual-range add and the
  -- resolved-remote toggle.
  local left = buf_of(child, "left_win")
  eq(has_buf_map(child, left, "n", "ca"), true)
  eq(has_buf_map(child, left, "x", "ca"), true)
  eq(has_buf_map(child, left, "n", "ce"), true)
  eq(has_buf_map(child, left, "n", "cY"), true)
  eq(has_buf_map(child, left, "n", "cr"), true)

  -- Real right buffer: leader-prefixed universal family ONLY, never single keys.
  local right = buf_of(child, "right_win")
  eq(has_buf_map(child, right, "n", "ca"), false)
  eq(has_buf_map(child, right, "n", [[\ca]]), true)
  eq(has_buf_map(child, right, "x", [[\ca]]), true)
  eq(has_buf_map(child, right, "n", "cr"), false)
  eq(has_buf_map(child, right, "n", [[\cr]]), true)

  -- Binary placeholder: no comment keys in either layer (side == nil).
  view_open(child, built.spec, {
    path = "bin.dat",
    status = "M",
    untracked = false,
    binary = true,
    additions = 0,
    deletions = 0,
    base_sha = "aaaaaaa",
    head_sha = "bbbbbbb",
  })
  local placeholder = buf_of(child, "left_win")
  eq(has_buf_map(child, placeholder, "n", "ca"), false)
  eq(has_buf_map(child, placeholder, "n", [[\ca]]), false)
  eq(has_buf_map(child, placeholder, "n", "v"), true, "non-comment diff keys still apply")
end

T["comments: moving to another file strips comment marks from the previous real buffer"] = function()
  local built = build(child, "worktree")

  new_view(child)
  child.lua("_G.__fake_threads = ...", {
    { [paths.modified] = { fake_thread(paths.modified, "head", 4, "note") } },
  })
  view_open(child, built.spec, entry_by_path(built.entries, paths.modified))

  local real_buf = buf_of(child, "right_win")
  eq(#comment_marks(child, real_buf), 1)

  view_open(child, built.spec, entry_by_path(built.entries, paths.new))
  eq(comment_marks(child, real_buf), {}, "moving on must leave no diffly marks on a real buffer")
end

return T
