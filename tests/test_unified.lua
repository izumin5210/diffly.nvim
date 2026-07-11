-- Tests for lua/difit/ui/unified.lua: the inline-overlay unified diff view (the inline-overlay design, now implemented (docs/architecture.md "Rendering")).
-- Runs in a child Neovim (real buffers/windows) against the standard fixture repo plus a
-- handful of purpose-built ones for overlay-anchoring edge cases; git is never mocked --
-- entry/spec data comes from real `difit.git` calls, and the anchoring math below was
-- confirmed against REAL `git diff -U3` output (see the comments on each edge-case test).

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

--- 0-based rows carrying a line-level `hl_group == group` extmark (i.e. `hl_eol`
--- highlights -- `DifitOverlayAdd`/`DifitOverlayDelete`'s "every line" case), sorted.
---@param marks table[]  -- from `nvim_buf_get_extmarks(..., { details = true })`
---@param group string
---@return integer[]
local function hl_rows(marks, group)
  local rows = {}
  for _, m in ipairs(marks) do
    if m[4].hl_group == group then
      -- Regression guard: a point mark (no end_row) with hl_eol paints NOTHING on
      -- screen even though the extmark "exists" -- only line-spanning ranges count.
      if m[4].end_row == nil or m[4].end_row <= m[2] then
        error(
          string.format(
            "extmark at row %d is zero-width (end_row=%s) -- it would render no highlight",
            m[2],
            tostring(m[4].end_row)
          )
        )
      end
      table.insert(rows, m[2])
    end
  end
  table.sort(rows)
  return rows
end

---@param marks table[]
---@return integer[]
local function add_rows(marks)
  return hl_rows(marks, "DifitOverlayAdd")
end

--- Every `virt_lines` extmark (one per contiguous "-" run), as `{ row, above, lines }`
--- with `lines` flattened back to plain strings (each chunk list has exactly one
--- `{text, "DifitOverlayDelete"}` pair per rendered virtual line).
---@param marks table[]
---@return { row: integer, above: boolean, lines: string[] }[]
local function delete_runs(marks)
  local runs = {}
  for _, m in ipairs(marks) do
    local details = m[4]
    if details.virt_lines then
      local lines = {}
      for _, vl in ipairs(details.virt_lines) do
        table.insert(lines, vl[1][1])
      end
      table.insert(runs, { row = m[2], above = details.virt_lines_above, lines = lines })
    end
  end
  return runs
end

local repo, paths, child

--- Build a real difit.RepoIdentity + entries map (keyed by path) + a difit.DiffSpec
--- (`right = "worktree"`, matching config.lua's own default) for the fixture's
--- `main`...`feature` comparison, and stash them as globals in the child so later
--- `child.lua(...)` calls (one per assertion) can all see the same view instance.
--
--- `_G.ctx` (docs/architecture.md "View contract") is the `difit.ui.ViewCtx` the view is built with:
--- `anchor` is whatever window is current when this runs (never touched -- this view only
--- ever splits rightward from it); `actions` records every call into `_G.__actions_log`
--- instead of driving a real session.
local function setup_child()
  child.lua([[
    _G.git = require("difit.git")
    _G.unified = require("difit.ui.unified")

    _G.repo = git.repo_identity(vim.fn.getcwd())
    _G.base_sha = vim.trim(vim.fn.system({ "git", "-C", repo.toplevel, "rev-parse", "main" }))

    local entries = git.diff_files(repo, base_sha, "worktree", { include_untracked = true })
    _G.entries = {}
    for _, e in ipairs(entries) do
      _G.entries[e.path] = e
    end

    _G.spec = {
      repo = repo,
      base_ref = "main",
      merge_base = base_sha,
      right = "worktree",
      review_key = { kind = "branch", repo = repo.id, base = "main", head = "feature" },
    }
    _G.spec_head = vim.tbl_extend("force", {}, spec, { right = "head" })

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

--- Open `path` (via `_G[spec_name]`, `"spec"` by default) in the shared view, returning
--- the resulting window/buffer/overlay state.
---@param path string
---@param spec_name string?
local function open(path, spec_name)
  return child.lua(
    [[
      local path, spec_name = ...
      view:open(entries[path], _G[spec_name])
      local buf = vim.api.nvim_get_current_buf()
      return {
        win = vim.api.nvim_get_current_win(),
        buf = buf,
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        filetype = vim.bo[buf].filetype,
        buftype = vim.bo[buf].buftype,
        modifiable = vim.bo[buf].modifiable,
        bufname = vim.api.nvim_buf_get_name(buf),
        win_count = #vim.api.nvim_tabpage_list_wins(0),
        marks = vim.api.nvim_buf_get_extmarks(buf, view.ns, 0, -1, { details = true }),
      }
    ]],
    { path, spec_name or "spec" }
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
    return {
      buf = buf,
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      marks = vim.api.nvim_buf_get_extmarks(buf, view.ns, 0, -1, {}),
    }
  ]])
end

---@param child table
---@param max integer|false
local function set_max_file_size(child, max)
  child.lua("require('difit.config').setup({ max_file_size = ... })", { max })
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

---------------------------------------------------------------------------------------
-- worktree mode: the real file, with the +/- overlay drawn on top of it. Expected rows
-- below are computed straight from tests/helpers.lua's fixture content -- confirmed
-- against real `git diff main feature -- src/mod.lua` output:
--
--   @@ -1,7 +1,11 @@
--    local M = {}
--
--    function M.hello()
--   -  return "hello"
--   +  return "hello, world"
--   +end
--   +
--   +function M.extra()
--   +  return true
--    end
--
--    return M
--   \ No newline at end of file
--
-- so the real (post-change) file's 11 lines are: 1 local M={}, 2 blank, 3 function
-- M.hello(), 4 return "hello, world", 5 end, 6 blank, 7 function M.extra(), 8 return
-- true, 9 end, 10 blank, 11 return M -- rows 3..7 (0-based) are "+", and the deleted
-- `  return "hello"` sits right before row 3 (i.e. anchored AT row 3, virt_lines_above).
---------------------------------------------------------------------------------------

T["open(): worktree mode shows the real file -- editable, real filetype (LSP-able), correct bufname"] = function()
  local result = open(paths.modified)

  eq(realpath(result.bufname), realpath(repo.dir .. "/" .. paths.modified))
  eq(result.buftype, "", "a real file buffer, not a difit:// scratch buffer")
  eq(result.modifiable, true)
  eq(result.filetype, "lua", "the real file keeps its own filetype -- LSP/syntax works")
end

T["open(): '+' lines get DifitOverlayAdd line extmarks at the exact expected rows"] = function()
  local result = open(paths.modified)
  eq(add_rows(result.marks), { 3, 4, 5, 6, 7 })
end

T["open(): the deleted line renders as ONE virt_lines run anchored right before its replacement"] = function()
  local result = open(paths.modified)
  local runs = delete_runs(result.marks)

  eq(#runs, 1)
  eq(runs[1].row, 3)
  eq(runs[1].above, true)
  eq(runs[1].lines, { '  return "hello"' })
end

T["open(): context lines carry no overlay marks"] = function()
  local result = open(paths.modified)
  local added, deleted = {}, {}
  for _, r in ipairs(add_rows(result.marks)) do
    added[r] = true
  end
  for _, run in ipairs(delete_runs(result.marks)) do
    deleted[run.row] = true
  end

  for _, row in ipairs({ 0, 1, 2, 8, 9, 10 }) do
    eq(added[row], nil, "row " .. row .. " is context -- must not be DifitOverlayAdd")
    eq(deleted[row], nil, "row " .. row .. " is context -- must not anchor a deleted run")
  end
end

T["open(): re-rendering the same file clears stale marks instead of accumulating them"] = function()
  local first = open(paths.modified)
  local second = open(paths.modified)

  -- If `render_overlay` failed to clear the namespace before redrawing, re-opening the
  -- same hunks a second time would DOUBLE the mark count instead of reproducing it --
  -- this is `session:refresh()`'s own call path (reopen `current_path` through the same
  -- view instance), so this also stands in for "refresh re-renders the overlay".
  eq(#second.marks, #first.marks)
  eq(#second.marks > 0, true)
end

T["worktree mode: editing the real buffer then :write persists to disk"] = function()
  open(paths.modified)
  child.lua([[
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "-- edited during review" })
    vim.cmd("write")
  ]])

  local content = vim.fn.readfile(repo.dir .. "/" .. paths.modified)
  eq(content[#content], "-- edited during review")
end

---------------------------------------------------------------------------------------
-- Added file: every line is "+" (git.hunks against merge_base naturally returns a
-- single, all-"+" hunk for a path that doesn't exist at merge_base -- no special-casing
-- needed beyond the general overlay algorithm above).
---------------------------------------------------------------------------------------

T["open(): an added file gets DifitOverlayAdd on every line, no deleted runs"] = function()
  local result = open(paths.new)

  local expected = {}
  for i = 0, #result.lines - 1 do
    expected[i + 1] = i
  end
  eq(add_rows(result.marks), expected)
  eq(delete_runs(result.marks), {})
end

---------------------------------------------------------------------------------------
-- Deleted file: a read-only blob of entry.base_sha, entirely painted DifitOverlayDelete
-- (line-level marks, no virt_lines -- there is no "new file" to anchor deletions inside).
---------------------------------------------------------------------------------------

T["open(): a deleted file shows a read-only base blob, entirely DifitOverlayDelete"] = function()
  local result = open(paths.deleted)

  eq(result.buftype, "nofile")
  eq(result.modifiable, false)
  eq(vim.startswith(result.bufname, "difit://"), true)
  eq(delete_runs(result.marks), {}, "no virt_lines -- the whole buffer IS the deleted content")

  local expected = {}
  for i = 0, #result.lines - 1 do
    expected[i + 1] = i
  end
  eq(hl_rows(result.marks, "DifitOverlayDelete"), expected)
end

---------------------------------------------------------------------------------------
-- Binary and head mode.
---------------------------------------------------------------------------------------

T["open(): binary entries render a single placeholder line, no overlay"] = function()
  local result = open_binary()
  eq(result.lines, { "binary file" })
  eq(#result.marks, 0)
end

T["open(): head mode shows a read-only HEAD blob with the overlay computed against HEAD"] = function()
  local result = open(paths.modified, "spec_head")

  eq(result.buftype, "nofile")
  eq(result.modifiable, false)
  eq(vim.startswith(result.bufname, "difit://"), true)
  eq(add_rows(result.marks), { 3, 4, 5, 6, 7 })
  eq(delete_runs(result.marks)[1].lines, { '  return "hello"' })

  local head_lines = vim.fn.systemlist({ "git", "-C", repo.dir, "show", "HEAD:" .. paths.modified })
  eq(result.lines, head_lines)
end

T["open(): renamed files open the real (new-path) file without error"] = function()
  local result = open(paths.renamed_to)

  eq(result.buftype, "")
  eq(vim.endswith(result.bufname, "/" .. paths.renamed_to), true)
end

---------------------------------------------------------------------------------------
-- Large-file guard (config.max_file_size, ui/size_guard.lua): an entry whose content
-- would exceed the configured limit renders a placeholder styled like `show_binary`'s
-- (owned buffer, no overlay) instead of loading it, with a `L` key to force-load it for
-- the rest of this view instance. Binary detection always takes precedence.
---------------------------------------------------------------------------------------

T["open(): an oversized file renders a placeholder with the size text instead of its real content"] = function()
  set_max_file_size(child, 64)

  local result = open(paths.modified)

  eq(result.buftype, "nofile")
  eq(result.modifiable, false)
  eq(#result.lines, 1)
  eq(result.lines[1]:find("file too large", 1, true) ~= nil, true)
  eq(result.lines[1]:find("press L to load", 1, true) ~= nil, true)
  eq(#result.marks, 0, "no overlay for a placeholder")
end

T["open(): pressing L on the oversized placeholder force-loads the file and its overlay, and it stays loaded on reopen"] = function()
  set_max_file_size(child, 64)
  local placeholder = open(paths.modified)
  eq(placeholder.lines[1]:find("file too large", 1, true) ~= nil, true)

  child.type_keys("L")

  local state = child.lua([[
    local buf = vim.api.nvim_get_current_buf()
    return {
      bufname = vim.api.nvim_buf_get_name(buf),
      buftype = vim.bo[buf].buftype,
      overlay_marks = #vim.api.nvim_buf_get_extmarks(buf, view.ns, 0, -1, {}),
    }
  ]])

  eq(
    vim.endswith(state.bufname, "/" .. paths.modified),
    true,
    "the real worktree file is now shown"
  )
  eq(state.buftype, "", "a real file buffer now, not the placeholder scratch")
  eq(state.overlay_marks > 0, true, "the +/- overlay is drawn once the real file loads")

  -- Reopening the same path later (e.g. navigating away and back) must not show the
  -- placeholder again -- `force_loaded` persists for the rest of this view instance.
  local second = open(paths.modified)
  eq(vim.endswith(second.bufname, "/" .. paths.modified), true)
end

T["open(): max_file_size = false disables the guard entirely"] = function()
  set_max_file_size(child, false)

  local result = open(paths.modified)

  eq(result.buftype, "", "the real file loads normally, not a placeholder")
  eq(vim.endswith(result.bufname, "/" .. paths.modified), true)
end

T["open(): binary entries take precedence over the size guard -- no size text, no L key"] = function()
  set_max_file_size(child, 1) -- tiny enough that even "binary file" would exceed it, if checked

  local result = open_binary()

  eq(result.lines, { "binary file" })
  eq(mapped(buf_maparg(child, result.buf, "L")), false)
end

---------------------------------------------------------------------------------------
-- Window ownership (docs/architecture.md "View contract"): unchanged from the pre-overlay view, since
-- neither `ensure_window` nor the owned-window contract changed.
---------------------------------------------------------------------------------------

T["open(): reuses the same window across multiple opens, across different buffer kinds"] = function()
  local first = open(paths.modified) -- real buffer
  local before = child.lua([[return #vim.api.nvim_list_wins()]])
  local second = open(paths.deleted) -- owned blob buffer
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

--- Regression (the "focus lands on the panel after switching modes on a binary file"
--- bug): `ui/sidebyside.lua`'s and this view's binary placeholder buffers are named
--- identically for the same file (`ui/scratch.lua` naming has no per-view component), so
--- a fresh sidebyside view sharing this test's `_G.ctx` reproduces the exact collision
--- `Session:set_mode` creates in production -- opening the incoming (this) view before
--- closing the outgoing (sidebyside) one (docs/architecture.md "View contract"). Before
--- the `close()` fix (win_findbuf guard on the owned-buffer delete loop), the outgoing
--- view's `close()` force-deleted that shared buffer out from under this view's
--- already-focused window, and Neovim closes every window still showing a buffer it
--- deletes -- silently destroying this view's window and dropping focus back to
--- `ctx.anchor` (the panel, in production).
T["regression: an outgoing sidebyside view's close() must not steal this view's window when both show the same binary placeholder"] = function()
  child.lua([[
    local sidebyside = require("difit.ui.sidebyside")
    _G.__old_view = sidebyside.new(_G.ctx)

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
    _G.__entry = entry

    -- Mirrors Session:set_mode's order: the outgoing view opens first...
    _G.__old_view:open(entry, spec)
  ]])

  -- ...then the incoming view (this test's shared `view`) opens the SAME entry BEFORE
  -- the outgoing one closes.
  child.lua([[ view:open(_G.__entry, spec) ]])
  local view_win_before_close = child.lua_get("view.win")

  child.lua([[ _G.__old_view:close() ]])

  eq(
    child.lua_get("vim.api.nvim_get_current_win()"),
    view_win_before_close,
    "focus must stay on this view's window, not fall back to ctx.anchor"
  )
  eq(child.lua_get("vim.api.nvim_win_is_valid(...)", { view_win_before_close }), true)
  eq(
    child.lua_get("view.win"),
    view_win_before_close,
    "this view's own window bookkeeping is untouched"
  )
end

---------------------------------------------------------------------------------------
-- close(): a real buffer must retain NO trace (extmarks, keymaps) after close() -- it is
-- never wiped (it isn't difit-owned), only released; owned scratch buffers ARE wiped.
---------------------------------------------------------------------------------------

T["close(): the real buffer survives but loses its overlay marks and keymaps.universal"] = function()
  local result = open(paths.modified)
  local ns = child.lua_get("view.ns")

  child.lua([[view:close()]])

  eq(child.lua("return vim.api.nvim_buf_is_valid(...)", { result.buf }), true, "never wiped")
  eq(child.lua("return #vim.api.nvim_buf_get_extmarks(...)", { result.buf, ns, 0, -1, {} }), 0)
  eq(mapped(buf_maparg(child, result.buf, "<leader>v")), false)
end

T["close(): owned scratch buffers are wiped and the window is closed, leaving ctx.anchor untouched"] = function()
  local deleted = open(paths.deleted)

  child.lua([[view:close()]])

  eq(child.lua("return vim.api.nvim_buf_is_valid(...)", { deleted.buf }), false)
  eq(child.lua("return vim.api.nvim_win_is_valid(...)", { deleted.win }), false)
  eq(child.lua_get("vim.api.nvim_win_is_valid(_G.ctx.anchor)"), true)
end

T["release_real_buf(): switching from the real worktree buffer to an owned buffer clears its overlay + keymaps immediately (not just at close())"] = function()
  local worktree_result = open(paths.modified)
  local ns = child.lua_get("view.ns")

  open(paths.deleted) -- switches the SAME window to an owned blob buffer

  eq(
    child.lua("return #vim.api.nvim_buf_get_extmarks(...)", { worktree_result.buf, ns, 0, -1, {} }),
    0,
    "the real buffer's overlay is gone the moment the view moves on, not just at close()"
  )
  eq(mapped(buf_maparg(child, worktree_result.buf, "<leader>v")), false)
end

---------------------------------------------------------------------------------------
-- keymaps: the real-buffer rule (design.md) -- worktree mode gets ONLY keymaps.universal,
-- never keymaps.diff's single-key shortcuts. Difit-owned buffers (deleted/head blobs,
-- binary) get both, exactly like ui/sidebyside.lua's own owned buffers.
---------------------------------------------------------------------------------------

T["open(): worktree mode's real buffer gets keymaps.universal only, never keymaps.diff"] = function()
  local result = open(paths.modified)

  for _, key in ipairs({ "<leader>v", "<leader>s", "<leader>e" }) do
    eq(mapped(buf_maparg(child, result.buf, key)), true, key .. " missing on the real buffer")
  end
  for _, key in ipairs({ "v", "s", "q" }) do
    eq(
      mapped(buf_maparg(child, result.buf, key)),
      false,
      key .. " must not be mapped on a real buffer"
    )
  end
end

T["open(): a difit-owned buffer gets keymaps.diff's v/s/<leader>e/q in addition to keymaps.universal"] = function()
  local result = open(paths.deleted)

  for _, key in ipairs({ "v", "s", "<leader>e", "q", "<leader>v", "<leader>s" }) do
    eq(mapped(buf_maparg(child, result.buf, key)), true, key .. " missing on an owned buffer")
  end
end

T["open(): keymaps are set with nowait, on both the real buffer and owned buffers"] = function()
  local real = open(paths.modified)
  for _, key in ipairs({ "<leader>v", "<leader>s", "<leader>e" }) do
    eq(buf_maparg(child, real.buf, key).nowait, 1)
  end

  local owned = open(paths.deleted)
  for _, key in ipairs({ "v", "s", "<leader>e", "q", "<leader>v" }) do
    eq(buf_maparg(child, owned.buf, key).nowait, 1)
  end
end

T["keymaps.universal.toggle_mode = false disables only that key, leaving keymaps.diff's own toggle_mode intact on an owned buffer"] = function()
  child.lua(
    [[require("difit.config").setup({ keymaps = { universal = { toggle_mode = false } } })]]
  )

  local result = open(paths.deleted)

  eq(mapped(buf_maparg(child, result.buf, "<leader>s")), false, "keymaps.universal.toggle_mode")
  eq(mapped(buf_maparg(child, result.buf, "s")), true, "keymaps.diff.toggle_mode is unaffected")
  eq(
    mapped(buf_maparg(child, result.buf, "<leader>v")),
    true,
    "other universal keys are unaffected"
  )
end

T["toggle_mode/focus_panel/close actions fire when their keys are pressed on an owned buffer"] = function()
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

  open(paths.deleted)

  child.type_keys("s")
  child.type_keys([[\e]]) -- the literal keys `<leader>e` sends with the default mapleader
  child.type_keys("q")

  eq(child.lua_get("_G.__calls"), { toggle_mode = 1, focus_panel = 1, close = 1 })
end

T["universal actions (leader-prefixed) fire from the real worktree buffer"] = function()
  child.lua([[
    _G.__calls = { toggle_mode = 0, focus_panel = 0 }
    _G.ctx.actions.toggle_mode = function()
      _G.__calls.toggle_mode = _G.__calls.toggle_mode + 1
    end
    _G.ctx.actions.focus_panel = function()
      _G.__calls.focus_panel = _G.__calls.focus_panel + 1
    end
  ]])

  open(paths.modified)

  child.type_keys([[\s]])
  child.type_keys([[\e]])

  eq(child.lua_get("_G.__calls"), { toggle_mode = 1, focus_panel = 1 })
end

---------------------------------------------------------------------------------------
-- Blob-loading / hunks error honesty (docs/architecture.md "Rendering"): a REAL git failure (a sha
-- that doesn't resolve to an object) must notify once instead of silently degrading to
-- an empty/truncated render indistinguishable from ordinary "nothing to show" cases.
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

T["show_head_blob(): a bogus head_sha notifies WARN once and still opens an empty read-only blob"] = function()
  child.lua(
    [[
      local path, sha = ...
      entries[path].head_sha = sha
    ]],
    { paths.modified, BOGUS_SHA }
  )
  install_notify_capture(child)

  local result = open(paths.modified, "spec_head")

  eq(result.buftype, "nofile")
  eq(result.lines, { "" }, "UI still renders (empty) instead of erroring")

  local notes = child.lua_get("_G.__notifications")
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
end

T["show_deleted(): a bogus base_sha notifies WARN once and still opens an empty, fully DifitOverlayDelete blob"] = function()
  child.lua(
    [[
      local path, sha = ...
      entries[path].base_sha = sha
    ]],
    { paths.deleted, BOGUS_SHA }
  )
  install_notify_capture(child)

  local result = open(paths.deleted)

  eq(result.lines, { "" })
  eq(hl_rows(result.marks, "DifitOverlayDelete"), { 0 })

  local notes = child.lua_get("_G.__notifications")
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
end

T["open(): a bogus merge_base notifies WARN once and still renders the real buffer with no overlay"] = function()
  child.lua([[spec.merge_base = ...]], { BOGUS_SHA })
  install_notify_capture(child)

  local result = open(paths.modified)

  eq(result.buftype, "", "the real file itself still opens fine")
  eq(#result.marks, 0, "no overlay -- hunks defaulted to {} instead of erroring")

  local notes = child.lua_get("_G.__notifications")
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
end

---------------------------------------------------------------------------------------
-- Overlay anchoring edge cases (empirically verified against real `git diff -U3`
-- output -- see the shell transcript referenced in the PR/commit description; summarized
-- per case below). Each builds its own tiny throwaway repo: the anchoring math
-- (`compute_overlay`/`render_overlay`) is identical whether the target buffer is a real
-- worktree file or a read-only blob, so these all use `right = "head"` for simplicity --
-- nothing here depends on the worktree also having this content.
---------------------------------------------------------------------------------------

--- `helpers.Repo:write` (via `vim.fn.writefile(..., "b")`) never adds a trailing newline
--- (see tests/test_e2e.lua's own note on the same quirk) -- fine for the standard fixture,
--- but it would silently corrupt these purpose-built edge cases: a non-empty `after`
--- whose last line happens to equal `before`'s last line would still show as a spurious
--- delete+add pair, since one copy has a trailing newline (mid-file in `before`) and the
--- other doesn't (last line of the file). Appending an extra "" line forces `writefile` to
--- emit a real trailing newline instead (confirmed empirically: `{"a","b",""}` writes
--- `"a\nb\n"`), i.e. an ordinary file with no `\ No newline at end of file` marker at all.
--- Left alone for a genuinely EMPTY `after` (`{}`) -- that must stay a true 0-byte file.
---@param lines string[]
---@return string[]
local function with_trailing_newline(lines)
  if #lines == 0 then
    return lines
  end
  local out = vim.deepcopy(lines)
  table.insert(out, "")
  return out
end

--- Build a single-file repo (`f.lua`, `before` on `main`, `after` on `feature`), open it
--- through a fresh `unified.new(ctx)` view in HEAD mode, and return the resulting overlay
--- marks alongside a `cleanup()` the caller must call afterwards.
---@param before string[]
---@param after string[]
---@return { lines: string[], marks: table[] } result
---@return fun() cleanup
local function overlay_for_change(before, after)
  local r = helpers.new_repo()
  r:write("f.lua", with_trailing_newline(before))
  r:commit("chore: base")
  r:branch("feature")
  r:write("f.lua", with_trailing_newline(after))
  r:commit("feat: change")

  local c = helpers.new_child(r.dir)
  c.lua([[
    local git2 = require("difit.git")
    local unified2 = require("difit.ui.unified")

    local repo2 = git2.repo_identity(vim.fn.getcwd())
    local base_sha2 = vim.trim(vim.fn.system({ "git", "-C", repo2.toplevel, "rev-parse", "main" }))
    local entries = git2.diff_files(repo2, base_sha2, "head", { include_untracked = true })

    _G.entry2 = entries[1]
    _G.spec2 = {
      repo = repo2,
      base_ref = "main",
      merge_base = base_sha2,
      right = "head",
      review_key = { kind = "branch", repo = repo2.id, base = "main", head = "feature" },
    }
    _G.ctx2 = {
      anchor = vim.api.nvim_get_current_win(),
      claim = nil,
      actions = {
        toggle_viewed = function() end,
        toggle_mode = function() end,
        focus_panel = function() end,
        close = function() end,
      },
    }
    _G.view2 = unified2.new(_G.ctx2)
  ]])

  local result = c.lua([[
    view2:open(entry2, spec2)
    local buf = vim.api.nvim_get_current_buf()
    return {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      marks = vim.api.nvim_buf_get_extmarks(buf, view2.ns, 0, -1, { details = true }),
    }
  ]])

  return result, function()
    c.stop()
    r:destroy()
  end
end

-- git diff -U3 for L1..L10 -> L1,L2,L3,L4,L8,L9,L10 (delete L5,L6,L7 mid-file):
--   @@ -2,9 +2,6 @@
--    L2
--    L3
--    L4
--   -L5
--   -L6
--   -L7
--    L8
--    L9
--    L10
-- new_start=2 (context lines still land at real rows 1,2,3); the run flushes right
-- before "L8" (now at 1-based line 5, row 4) -- exactly where L5..L7 used to be.
T["overlay edge case: pure deletion in the middle of the file anchors exactly where the text was removed"] = function()
  local numbered = {}
  for i = 1, 10 do
    numbered[i] = "L" .. i
  end
  local after = { "L1", "L2", "L3", "L4", "L8", "L9", "L10" }

  local result, cleanup = overlay_for_change(numbered, after)
  eq(result.lines, after)

  local runs = delete_runs(result.marks)
  eq(#runs, 1)
  eq(runs[1].row, 4)
  eq(runs[1].above, true)
  eq(runs[1].lines, { "L5", "L6", "L7" })
  eq(add_rows(result.marks), {})

  cleanup()
end

-- git diff -U3 for L1..L10 -> L4..L10 (delete the first 3 lines):
--   @@ -1,6 +1,3 @@
--   -L1
--   -L2
--   -L3
--    L4
--    L5
--    L6
-- new_start=1: the run flushes at raw_row = new_start - 1 = 0 BEFORE any real line has
-- been consumed -- row 0 falls out naturally here, no clamping needed (contrast with the
-- "whole file emptied" case below, where new_start itself is 0 and clamping IS needed).
T["overlay edge case: deletion at the very top of the file anchors at row 0"] = function()
  local numbered = {}
  for i = 1, 10 do
    numbered[i] = "L" .. i
  end
  local after = { "L4", "L5", "L6", "L7", "L8", "L9", "L10" }

  local result, cleanup = overlay_for_change(numbered, after)
  eq(result.lines, after)

  local runs = delete_runs(result.marks)
  eq(#runs, 1)
  eq(runs[1].row, 0)
  eq(runs[1].above, true)
  eq(runs[1].lines, { "L1", "L2", "L3" })

  cleanup()
end

-- git diff -U3 for L1..L10 -> L1..L7 (delete the last 3 lines):
--   @@ -5,6 +5,3 @@
--    L5
--    L6
--    L7
--   -L8
--   -L9
--   -L10
-- new_start=5, new_count=3: after the 3 context lines cur_new reaches 8, one past the
-- new file's last real line (7) -- raw_row (7) exceeds the last valid row (6), so the
-- run clamps to the last line with virt_lines_above = false (renders BELOW it).
T["overlay edge case: deletion at EOF anchors on the last line, rendered below it"] = function()
  local numbered = {}
  for i = 1, 10 do
    numbered[i] = "L" .. i
  end
  local after = { "L1", "L2", "L3", "L4", "L5", "L6", "L7" }

  local result, cleanup = overlay_for_change(numbered, after)
  eq(result.lines, after)

  local runs = delete_runs(result.marks)
  eq(#runs, 1)
  eq(runs[1].row, 6, "clamped to the last real line (0-based row 6 == line 7)")
  eq(runs[1].above, false, "renders BELOW the last line, not overlapping it")
  eq(runs[1].lines, { "L8", "L9", "L10" })

  cleanup()
end

-- git diff -U3 for L1,L2,L3 -> "" (the file still exists, tracked, but is now 0 bytes):
--   @@ -1,3 +0,0 @@
--   -L1
--   -L2
--   -L3
-- Confirmed empirically (never guessed): with -U3, git reports "+0,0" -- new_start = 0,
-- i.e. "before line 1" -- ONLY when the new side has literally zero lines; anything short
-- of that always carries at least one line of surrounding context (see the top-of-file
-- case above, which still gets new_start = 1). `cur_new - 1 == -1` here, genuinely
-- needing the row-0 clamp (contrast with the top-of-file case, where row 0 falls out
-- without clamping). The buffer itself still has exactly one (empty) line -- Neovim
-- buffers are never truly 0 lines -- so the anchor is valid at row 0.
T["overlay edge case: the whole file emptied (new_start == 0) clamps to row 0"] = function()
  local result, cleanup = overlay_for_change({ "L1", "L2", "L3" }, {})

  eq(result.lines, { "" })

  local runs = delete_runs(result.marks)
  eq(#runs, 1)
  eq(runs[1].row, 0)
  eq(runs[1].above, true)
  eq(runs[1].lines, { "L1", "L2", "L3" })
  eq(add_rows(result.marks), {})

  cleanup()
end

return T
