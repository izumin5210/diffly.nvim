-- End-to-end tests for the WP-I integration layer (`require("difit")` + `plugin/difit.lua`):
-- drives the real `:Difit` command against fixture repos in a child Neovim, exercising the
-- full tabpage/panel/view wiring together rather than any single module in isolation. Git
-- is never mocked (see tests/helpers.lua); only `gh` is faked, via the same PATH-shim
-- pattern tests/test_github.lua uses. Screenshot goldens live in tests/screenshots/.
--
-- Covers the 10 scenarios from docs/plan.md's WP-I section, in order, plus one bonus case
-- for `<Plug>(difit-toggle-viewed)` (part of the WP-I contract but not one of the 10), plus
-- (further down) the R1 session-registry cases from docs/refactor-v1.md.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

---------------------------------------------------------------------------------------
-- local test helpers
---------------------------------------------------------------------------------------

--- `make test` runs with `--noplugin` (see Makefile), so `plugin/difit.lua` is never
--- auto-sourced the way a real plugin manager would; `runtime!` finds it on 'runtimepath'
--- regardless of the child's cwd (which `helpers.new_child` points at the fixture repo,
--- not this repo).
---@param child table
local function source_plugin(child)
  child.cmd("runtime! plugin/difit.lua")
  -- R1 (docs/refactor-v1.md) replaced `require("difit")._session`/`._panel` with a
  -- registry keyed by tabpage handle (`require("difit")._entries`); every test helper
  -- below that used to read the old singleton fields now goes through this one place
  -- instead, mirroring how `init.lua`'s own `current_entry()` resolves "the" session.
  child.lua([[
    _G.__difit_entry = function()
      return require("difit")._entries[vim.api.nvim_get_current_tabpage()]
    end
  ]])
end

--- Point the child's `difit.state` at an isolated temp dir (the documented `_dir` test
--- seam) so these runs never touch the developer's real `stdpath('data')`.
---@param child table
---@param dir string
local function point_state_dir(child, dir)
  child.lua("require('difit.state')._dir = ...", { dir })
end

--- `tests/helpers.lua` doesn't wrap `MiniTest.new_child_neovim()` with a `set_size` helper
--- (unlike mini.nvim's own test suite); screenshot tests need a fixed size for
--- deterministic goldens, so this is inlined here instead.
---@param child table
---@param lines integer
---@param columns integer
--- The default tabline renders the full (fixture-repo-relative) path of the buffer in
--- each tab, which embeds `vim.fn.tempname()`'s random component -- fine for a human, but
--- it would make every screenshot golden flaky across runs. Screenshot tests hide it.
---@param child table
---@param lines integer
---@param columns integer
local function set_size(child, lines, columns)
  child.o.lines = lines
  child.o.columns = columns
  child.o.showtabline = 0
end

--- Like `helpers.path_shim`, but targets *the child's* PATH: mirrors
--- tests/test_github.lua's file-local `child_path_shim` (small enough, and file-local
--- there too, that duplicating it is preferable to widening tests/helpers.lua's public
--- API just for this).
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

---@param v any
---@return any
local function denil(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---@param child table
---@return boolean
local function is_open(child)
  return child.lua_get([[__difit_entry() ~= nil]])
end

--- Current text of the panel buffer, or `nil` when no session (hence no panel) is open
--- on the current tabpage.
---@param child table
---@return string[]|nil
local function panel_lines(child)
  return denil(child.lua_get([[
    (function()
      local entry = __difit_entry()
      if not entry then
        return vim.NIL
      end
      return vim.api.nvim_buf_get_lines(entry.panel.buf, 0, -1, false)
    end)()
  ]]))
end

---@param child table
---@return integer
local function tab_count(child)
  return child.lua_get("#vim.api.nvim_list_tabpages()")
end

---@param child table
---@return integer
local function current_tab(child)
  return child.lua_get("vim.api.nvim_get_current_tabpage()")
end

--- Move the panel's cursor to `lnum` without necessarily focusing it (mirrors
--- tests/test_panel.lua's own `set_cursor`); several actions (open_file, toggle_viewed,
--- set_mode) hand focus over to a diff window afterwards, so callers that need to drive
--- the panel *again* must `focus_panel` first.
---@param child table
---@param lnum integer
local function set_cursor(child, lnum)
  child.lua(
    "local lnum = ...; vim.api.nvim_win_set_cursor(__difit_entry().panel.win, { lnum, 0 })",
    { lnum }
  )
end

---@param child table
local function focus_panel(child)
  child.lua([[__difit_entry().panel:focus()]])
end

---@param child table
---@return integer
local function panel_cursor_row(child)
  -- `child.lua` (unlike `lua_get`, which prepends its own `return `) is required here:
  -- the body needs its own `local` before the `return`, and also avoids `lua_get`'s
  -- `[[...)[1]]]` trap -- Lua's `[[ ]]` long-bracket string terminates at the first
  -- literal `]]`, which a trailing `[1]]]` would supply one character early.
  return child.lua([[
    local pos = vim.api.nvim_win_get_cursor(__difit_entry().panel.win)
    return pos[1]
  ]])
end

---@param child table
---@return boolean
local function panel_is_current_win(child)
  return child.lua_get([[vim.api.nvim_get_current_win() == __difit_entry().panel.win]])
end

---@param child table
---@param expr string @Lua expression relative to the current tabpage's `entry.session`
local function session_field(child, expr)
  return denil(child.lua_get([[__difit_entry().session.]] .. expr))
end

---@param child table
---@param path string
---@return boolean
local function is_viewed(child, path)
  return child.lua("return __difit_entry().session:is_viewed(...)", { path })
end

--- Additions count (`+N`) of the first panel row whose text contains `filename_substr`,
-- used instead of hardcoding absolute git-diff stats (robust to exactly how git's diff
-- algorithm represents a given edit).
---@param lines string[]
---@param filename_substr string
---@return integer|nil
local function additions_for(lines, filename_substr)
  for _, l in ipairs(lines) do
    if l:find(filename_substr, 1, true) then
      return tonumber(l:match("%+(%d+)"))
    end
  end
  return nil
end

---@param child table
local function expect_screenshot(child)
  MiniTest.expect.reference_screenshot(child.get_screenshot())
end

--- Layout/mode snapshot for the round-trip regression below: reads everything needed to
--- assert both "the panel is intact" (the actual bug -- see ui/sidebyside.lua's
--- `ensure_windows`) and "the diff area looks like the current mode says it should" in one
--- child round-trip.
---@param child table
---@return {
---  mode: "sidebyside"|"unified",
---  panel_bufname: string,
---  win_count: integer,
---  left_diff: boolean?, right_diff: boolean?,
---  left_bufname: string?, right_bufname: string?,
---  unified_bufname: string?,
--- }
local function layout_snapshot(child)
  return child.lua([[
    local entry = __difit_entry()
    local view = entry.session._view
    local snap = {
      mode = entry.session.mode,
      panel_bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(entry.panel.win)),
      win_count = #vim.api.nvim_tabpage_list_wins(0),
    }
    if view.left_win then
      snap.left_diff = vim.wo[view.left_win].diff
      snap.right_diff = vim.wo[view.right_win].diff
      snap.left_bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(view.left_win))
      snap.right_bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(view.right_win))
    end
    if view.win then
      snap.unified_bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(view.win))
    end
    return snap
  ]])
end

--- Assert the viewer tabpage looks like a healthy side-by-side layout: the panel window
--- still shows a `difit://panel/...` buffer (the regression this guards against -- see
--- ui/sidebyside.lua's `ensure_windows`; the numeric suffix is R1's fix for the panel
--- buffer name colliding across concurrent reviews, see ui/panel.lua's `M.open`), plus
--- exactly the two `&diff` windows (one difit-owned blob, one the real file at `path`)
--- and nothing else.
---@param child table
---@param path string
local function assert_sidebyside_layout(child, path)
  local snap = layout_snapshot(child)
  eq(snap.mode, "sidebyside")
  eq(vim.startswith(snap.panel_bufname, "difit://panel/"), true)
  eq(snap.win_count, 3, "panel + left + right, nothing orphaned")
  eq(snap.left_diff, true)
  eq(snap.right_diff, true)
  eq(vim.startswith(snap.left_bufname, "difit://"), true)
  eq(vim.startswith(snap.right_bufname, "difit://"), false)
  eq(vim.endswith(snap.right_bufname, "/" .. path), true)
end

--- Assert the viewer tabpage looks like a healthy unified layout: the panel window still
--- shows a `difit://panel/...` buffer, plus exactly one `difit://unified/...` window and
--- nothing else.
---@param child table
local function assert_unified_layout(child)
  local snap = layout_snapshot(child)
  eq(snap.mode, "unified")
  eq(vim.startswith(snap.panel_bufname, "difit://panel/"), true)
  eq(snap.win_count, 2, "panel + the unified window, nothing orphaned")
  eq(vim.startswith(snap.unified_bufname or "", "difit://unified/"), true)
end

---------------------------------------------------------------------------------------
-- shared fixture: a fresh `helpers.fixture_branch_repo()` + child + sourced plugin +
-- isolated state dir per case, matching the panel/session/sidebyside test files' style.
--
-- Row numbers below (used by `set_cursor`) assume this exact fixture with no folds and no
-- prior toggling: the diff has a single top-level "src" directory (no compression, since
-- it has 4 file children, not a single child dir), so:
--   1 header, 2 progress,
--   3 "src", 4 gone.lua (D), 5 mod.lua (M), 6 new.lua (A), 7 renamed row (R)
---------------------------------------------------------------------------------------

local repo, paths, child, tmp_state

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      repo, paths = helpers.fixture_branch_repo()
      child = helpers.new_child(repo.dir)
      source_plugin(child)

      tmp_state = vim.fn.tempname()
      vim.fn.mkdir(tmp_state, "p")
      point_state_dir(child, tmp_state)

      -- `deps/mini.nvim` (on 'runtimepath' for every test child) bundles `mini.icons`,
      -- so panel rows would otherwise carry whatever glyph that dependency's checked-out
      -- commit happens to resolve for "*.lua" -- disable icons for deterministic rows/
      -- screenshots, exactly like tests/test_panel.lua already does.
      child.lua([[require("difit.config").setup({ icons = false })]])
    end,
    post_case = function()
      child.stop()
      repo:destroy()
      vim.fn.delete(tmp_state, "rf")
    end,
  },
})

-- 1. `:Difit` opens a dedicated tabpage: panel left, diff on the right -------------------

T["1. `:Difit` opens a new tabpage with the panel left and a diff on the right"] = function()
  set_size(child, 24, 100)
  eq(tab_count(child), 1)

  child.cmd("Difit")

  eq(is_open(child), true)
  eq(tab_count(child), 2)

  local lines = panel_lines(child)
  eq(lines[1], "difit  main…feature")
  eq(lines[2], "0/4 viewed")

  -- The dedicated tab has (at least) the panel plus the first file's diff windows.
  eq(#child.lua_get("vim.api.nvim_tabpage_list_wins(0)") >= 2, true)

  expect_screenshot(child)
end

-- 2. Marking a file viewed updates progress and auto-advances ---------------------------

T["2. marking a file viewed via the panel updates progress and auto-advances"] = function()
  set_size(child, 24, 100)
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("v")

  eq(is_viewed(child, paths.modified), true)
  eq(panel_lines(child)[2], "1/4 viewed")
  -- next_unviewed(after="src/mod.lua") skips the just-viewed file and wraps to the next
  -- un-viewed one in file_order (gone < mod < new < renamed): src/new.lua.
  eq(session_field(child, "current_path"), paths.new)

  expect_screenshot(child)
end

-- 3. `:Difit close` restores the original tabpage ----------------------------------------

T["3. `:Difit close` restores the original tabpage/layout"] = function()
  local origin_tab = current_tab(child)
  eq(tab_count(child), 1)

  child.cmd("Difit")
  eq(tab_count(child), 2)

  child.cmd("Difit close")

  eq(is_open(child), false)
  eq(tab_count(child), 1)
  eq(current_tab(child), origin_tab)
end

-- 4. Viewed marks persist across close/reopen (same branch key, no gh) -------------------

T["4. viewed marks persist across close and reopen (same branch key, no gh)"] = function()
  child.cmd("Difit")
  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("v")
  eq(is_viewed(child, paths.modified), true)

  child.cmd("Difit close")
  eq(is_open(child), false)

  child.cmd("Difit")
  eq(is_open(child), true)
  eq(is_viewed(child, paths.modified), true)
end

-- 5. A new commit invalidates only the file it touched -----------------------------------

T["5. a new commit un-views only the file it touched; untouched viewed files stay viewed"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("v") -- marks mod.lua; auto-advance moves the panel cursor to new.lua's
  -- row and focuses its diff (sidebyside always focuses the right window on open).
  focus_panel(child)
  child.type_keys("v") -- marks src/new.lua too (cursor already parked there)

  eq(is_viewed(child, paths.modified), true)
  eq(is_viewed(child, paths.new), true)

  child.cmd("Difit close")

  repo:write(paths.modified, {
    "local M = {}",
    "",
    "function M.hello()",
    '  return "hello, world, again"',
    "end",
    "",
    "function M.extra()",
    "  return true",
    "end",
    "",
    "return M",
  })
  repo:commit("feat: touch mod.lua again")

  child.cmd("Difit")
  eq(is_viewed(child, paths.modified), false, "modified file's blob changed -> un-viewed again")
  eq(is_viewed(child, paths.new), true, "untouched file keeps its mark")
end

-- 6. A detected PR shows in the header and uses a separate viewed-state key -------------

T["6. a detected PR shows `(PR #N)` in the header and keys viewed state separately"] = function()
  child.cmd("Difit")
  local branch_key_path =
    child.lua_get([[require('difit.state').file_path(__difit_entry().session.spec.review_key)]])
  child.cmd("Difit close")

  local restore_gh = child_path_shim(
    child,
    "gh",
    [[printf '%s' '{"number":7,"baseRefName":"main","url":"https://github.com/acme/widgets/pull/7"}']]
  )

  child.cmd("Difit")

  eq(session_field(child, "spec.review_key.kind"), "pr")
  eq(session_field(child, "spec.review_key.pr_number"), 7)
  eq(panel_lines(child)[1]:find("(PR #7)", 1, true) ~= nil, true)

  local pr_key_path =
    child.lua_get([[require('difit.state').file_path(__difit_entry().session.spec.review_key)]])
  eq(pr_key_path ~= branch_key_path, true)

  -- Mark something under the PR key too and close, so its state file actually gets
  -- written (state.save only runs on toggle/close, not on session.new's plain load).
  set_cursor(child, 5)
  child.type_keys("v")
  child.cmd("Difit close")

  eq(vim.uv.fs_stat(pr_key_path) ~= nil, true)
  eq(vim.uv.fs_stat(branch_key_path) ~= nil, true)

  restore_gh()
end

-- 7. `s` switches to unified mode; `<CR>` jumps from it -----------------------------------

T["7. `s` switches to unified mode and <CR> jumps to the real file"] = function()
  set_size(child, 24, 100)
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>")
  eq(session_field(child, "current_path"), paths.modified)

  focus_panel(child)
  child.type_keys("s")
  eq(session_field(child, "mode"), "unified")

  expect_screenshot(child)

  -- `set_mode` always builds a fresh view (see init.lua's `reap_stray_windows`), so the
  -- only non-panel window left in the tab is the unified one, and pressing `s` already
  -- focused it (unified.lua's `open()` always takes focus for itself) -- so the current
  -- window/buffer already *is* the unified view; jump straight from it.
  local target_lnum = child.lua_get([[
    (function()
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      for i, l in ipairs(lines) do
        if l == '+  return "hello, world"' then
          return i
        end
      end
    end)()
  ]])
  eq(type(target_lnum), "number")

  child.api.nvim_win_set_cursor(0, { target_lnum, 0 })
  child.type_keys("<CR>")

  local jumped = child.lua_get([[
    { bufname = vim.api.nvim_buf_get_name(0), cursor = vim.api.nvim_win_get_cursor(0) }
  ]])
  eq(vim.endswith(jumped.bufname, "/" .. paths.modified), true)
  eq(jumped.cursor[1], 4)
end

-- 8. `BufWritePost` refreshes the panel after the debounce --------------------------------

T["8. editing and writing a file in the diff refreshes the panel after the debounce"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- focus lands on the real worktree buffer (right_win)

  local before = additions_for(panel_lines(child), "mod.lua")
  eq(type(before), "number")

  child.lua([[
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "-- edited during review" })
    vim.cmd("write")
  ]])

  -- The refresh is debounced 200ms; the child keeps running its own event loop
  -- independently of this process, so sleeping here (not inside the child) is enough.
  vim.uv.sleep(350)

  -- Asserting an exact delta (rather than just "it grew") is intentionally avoided:
  -- tests/helpers.lua's `Repo:write` (via `vim.fn.writefile(..., "b")`) leaves fixture
  -- files without a trailing newline, so appending one line here can make git additionally
  -- count the previously-last line as changed (its newline-less byte gained a newline) --
  -- an artifact of the fixture, not of the refresh this test actually cares about.
  local after = additions_for(panel_lines(child), "mod.lua")
  eq(after ~= nil and after > before, true)
end

-- 9. `:Difit main` (explicit base) beats an overridden config.base ----------------------

T["9. `:Difit main` (explicit base) beats an overridden config.base"] = function()
  repo:git({ "branch", "decoy-base" })
  child.lua([[require("difit.config").setup({ base = "decoy-base" })]])

  child.cmd("Difit main")

  eq(session_field(child, "spec.base_ref"), "main")
end

-- 10. Deleted and renamed files open without error in both modes ------------------------

T["10. deleted and renamed files open without error in both diff modes"] = function()
  child.cmd("Difit")

  set_cursor(child, 4) -- src/gone.lua (deleted)
  child.type_keys("<CR>")
  eq(session_field(child, "current_path"), paths.deleted)

  focus_panel(child)
  set_cursor(child, 7) -- renamed row (src/renamed.lua)
  child.type_keys("<CR>")
  eq(session_field(child, "current_path"), paths.renamed_to)

  focus_panel(child)
  child.type_keys("s") -- unified mode
  eq(session_field(child, "mode"), "unified")

  focus_panel(child)
  set_cursor(child, 4)
  child.type_keys("<CR>")
  eq(session_field(child, "current_path"), paths.deleted)

  focus_panel(child)
  set_cursor(child, 7)
  child.type_keys("<CR>")
  eq(session_field(child, "current_path"), paths.renamed_to)
end

-- Bonus (not one of the 10, but part of the WP-I contract): <Plug>(difit-toggle-viewed) --

T["bonus: <Plug>(difit-toggle-viewed) toggles viewed for a real file buffer"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- focus lands on the real worktree buffer

  child.lua([[vim.keymap.set("n", "<F2>", "<Plug>(difit-toggle-viewed)")]])
  child.type_keys("<F2>")

  eq(is_viewed(child, paths.modified), true)
end

-- Regression (finding 1): reap_stray_windows must not kill user-created splits -----------

T["reap_stray_windows: a user's real-file split survives a refresh; an orphaned view window is still reaped after a mode switch"] = function()
  set_size(child, 24, 100)
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- opens the sidebyside view (2 windows)

  -- Simulate the user opening their own split on a real, unrelated file inside the
  -- viewer tabpage (e.g. :vsplit or :help) -- this must never be treated as "stray".
  child.cmd("vsplit " .. vim.fn.fnameescape(repo.dir .. "/README.md"))
  local user_win = child.lua_get("vim.api.nvim_get_current_win()")
  eq(vim.endswith(child.lua_get("vim.api.nvim_buf_get_name(0)"), "/README.md"), true)

  focus_panel(child)
  child.type_keys("R") -- refresh -> session:refresh() -> notify -> reap_stray_windows

  eq(
    child.lua_get("vim.api.nvim_win_is_valid(...)", { user_win }),
    true,
    "the user's split survives a refresh"
  )
  eq(
    vim.endswith(
      child.lua("return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(...))", { user_win }),
      "/README.md"
    ),
    true,
    "the user's split still shows the real file, not hijacked"
  )

  -- Mode switch: the previous sidebyside view's own windows are now orphaned (nothing in
  -- `keep`, since a fresh view was built) -- these must still be reaped, same as before
  -- this fix (this is what init.lua's per-entry `known_view_wins` is for).
  focus_panel(child)
  child.type_keys("s")
  eq(session_field(child, "mode"), "unified")

  eq(
    child.lua_get("vim.api.nvim_win_is_valid(...)", { user_win }),
    true,
    "the user's split survives the mode switch too"
  )

  local remaining = child.lua_get("vim.api.nvim_tabpage_list_wins(0)")
  eq(#remaining, 3, "exactly panel + user split + the fresh unified window remain")
end

-- Regression (finding 2): target_window must never hijack a difit-owned window (e.g. the
-- panel) that happens to be Vim's "previous window" ------------------------------------

T["target_window regression: panel-focused mode switch then <CR> in unified never lands the real file in the panel"] = function()
  set_size(child, 24, 100)
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>")
  focus_panel(child) -- panel current; Vim's "previous window" is the sidebyside right window

  -- Mode switch while the panel is focused: unified.lua's `ensure_window()` runs
  -- `vsplit` while the panel is the current window, which makes the panel Vim's
  -- "previous window" (`CTRL-W p`) from this point on -- exactly the trap
  -- `target_window()` must not fall into.
  child.type_keys("s")
  eq(session_field(child, "mode"), "unified")

  local target_lnum = child.lua_get([[
    (function()
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      for i, l in ipairs(lines) do
        if l == '+  return "hello, world"' then
          return i
        end
      end
    end)()
  ]])
  eq(type(target_lnum), "number")

  child.api.nvim_win_set_cursor(0, { target_lnum, 0 })
  child.type_keys("<CR>")

  eq(
    vim.startswith(
      child.lua_get(
        [[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(__difit_entry().panel.win))]]
      ),
      "difit://panel/"
    ),
    true,
    "the panel window must still show the panel buffer, not the real file"
  )

  local jumped = child.lua_get([[
    {
      bufname = vim.api.nvim_buf_get_name(0),
      win = vim.api.nvim_get_current_win(),
      cursor = vim.api.nvim_win_get_cursor(0),
    }
  ]])
  eq(vim.endswith(jumped.bufname, "/" .. paths.modified), true)
  eq(jumped.cursor[1], 4)
  eq(jumped.win ~= child.lua_get([[__difit_entry().panel.win]]), true)
end

-- Regression (finding 5): auto-advance fires only on MARKING, never on un-marking --------

T["auto-advance fires only when marking a file viewed, not when un-marking it"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("v") -- mark: auto-advances to src/new.lua and opens it
  eq(is_viewed(child, paths.modified), true)
  eq(session_field(child, "current_path"), paths.new)

  focus_panel(child)
  set_cursor(child, 5) -- back on src/mod.lua's row (now viewed)
  child.type_keys("v") -- un-mark: must NOT auto-advance
  eq(is_viewed(child, paths.modified), false)
  eq(
    session_field(child, "current_path"),
    paths.new,
    "un-marking must not change which file is open"
  )
end

T["bonus regression: <Plug>(difit-toggle-viewed) un-marking a real file buffer does not auto-advance"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("v") -- mark via the panel; auto-advances to src/new.lua
  eq(session_field(child, "current_path"), paths.new)

  focus_panel(child)
  set_cursor(child, 5) -- src/mod.lua, now viewed
  child.type_keys("<CR>") -- open it directly (not through toggle) so current_path tracks it
  eq(session_field(child, "current_path"), paths.modified)

  child.lua([[vim.keymap.set("n", "<F2>", "<Plug>(difit-toggle-viewed)")]])
  child.type_keys("<F2>") -- un-mark src/mod.lua from its own real-file buffer

  eq(is_viewed(child, paths.modified), false)
  eq(
    session_field(child, "current_path"),
    paths.modified,
    "un-marking from a real file buffer must not auto-advance away from it"
  )
end

---------------------------------------------------------------------------------------
-- keymaps.file / keymaps.diff's new toggle_mode/focus_panel/close actions, and
-- `:Difit focus` -- the fix for "no discoverable way back to the panel, and no way to
-- toggle mode or mark viewed from the real file buffer". Default mapleader is backslash
-- (never overridden here), so `<leader>x` is sent as the literal two keys `\x` below
-- (mirrors tests/test_sidebyside.lua and tests/test_unified.lua).
---------------------------------------------------------------------------------------

T["from the side-by-side right buffer, <leader>s (keymaps.file.toggle_mode) switches to unified"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- focus lands on the real worktree right buffer
  eq(session_field(child, "current_path"), paths.modified)

  child.type_keys([[\s]])

  eq(session_field(child, "mode"), "unified")
end

T["<leader>v (keymaps.file.toggle_viewed) from the real file buffer marks viewed, auto-advances, and syncs the panel's cursor"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>")

  child.type_keys([[\v]])

  eq(is_viewed(child, paths.modified), true)
  -- auto_advance opens the next un-viewed file in file_order (gone < mod < new < renamed):
  -- src/new.lua, row 6 per this file's fixed fixture layout.
  eq(session_field(child, "current_path"), paths.new)
  eq(
    panel_cursor_row(child),
    6,
    "the panel's own cursor follows the diff-originated auto-advance (Panel:set_cursor)"
  )
end

T["<leader>e (keymaps.file.focus_panel) from the real file buffer focuses the panel"] = function()
  child.cmd("Difit")

  set_cursor(child, 5)
  child.type_keys("<CR>")
  eq(panel_is_current_win(child), false, "sanity: focus is on the real file buffer, not the panel")

  child.type_keys([[\e]])

  eq(panel_is_current_win(child), true)
end

T["q in the unified buffer (keymaps.diff.close) closes the entire viewer"] = function()
  child.cmd("Difit")

  child.type_keys("s") -- panel's own toggle_mode key -> unified, focuses the new view
  eq(session_field(child, "mode"), "unified")

  child.type_keys("q")

  eq(is_open(child), false)
end

T["`:Difit focus` focuses the panel from wherever the cursor currently is"] = function()
  child.cmd("Difit")

  set_cursor(child, 5)
  child.type_keys("<CR>")
  eq(panel_is_current_win(child), false)

  child.cmd("Difit focus")

  eq(panel_is_current_win(child), true)
end

T["`:Difit focus` does not error when no review is open"] = function()
  eq(is_open(child), false)
  eq(pcall(child.cmd, "Difit focus"), true)
end

-- Regression: side-by-side -> unified -> side-by-side must be reachable from every entry
-- point (bug report: after switching side-by-side -> unified, switching back was
-- impossible from ANY entry point -- see ui/sidebyside.lua's `ensure_windows`). Root
-- cause: the outgoing unified view's close() closes its own window, focus falls back to
-- the panel, and the old `ensure_windows` claimed whatever window was current as its left
-- window -- fatal once the panel got 'winfixbuf' (E1513), because `session.mode` was
-- already flipped to "sidebyside" before the view failed to open, so the very next `s`
-- press only flipped back to "unified" without ever producing a working split again.
T["round-trip regression: side-by-side <-> unified is reachable from every entry point"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- panel `open` -> sidebyside, focuses the real right buffer
  eq(session_field(child, "current_path"), paths.modified)
  assert_sidebyside_layout(child, paths.modified)

  -- (a) panel `s` -> unified -> panel `s` -> back to side-by-side.
  focus_panel(child)
  child.type_keys("s")
  assert_unified_layout(child)

  focus_panel(child)
  child.type_keys("s")
  assert_sidebyside_layout(child, paths.modified)

  -- (b) from the unified buffer itself, `s` -> side-by-side (first get back into unified
  -- via the panel, then press `s` from inside the unified buffer -- unified's own
  -- `open()` already focuses itself, so no `focus_panel` before this second `s`).
  focus_panel(child)
  child.type_keys("s")
  assert_unified_layout(child)

  child.type_keys("s") -- keymaps.diff.toggle_mode, pressed from inside the unified buffer
  assert_sidebyside_layout(child, paths.modified)

  -- (c) from the side-by-side real right buffer, `<leader>s` -> unified -> (in the
  -- unified buffer) `s` -> side-by-side. `open()`/`set_mode` already leave focus on the
  -- real right buffer in worktree mode, so no extra navigation is needed here.
  child.type_keys([[\s]]) -- keymaps.file.toggle_mode
  assert_unified_layout(child)

  child.type_keys("s") -- keymaps.diff.toggle_mode, from inside the unified buffer
  assert_sidebyside_layout(child, paths.modified)
end

T["bonus: <Plug>(difit-toggle-mode) and <Plug>(difit-focus-panel) work as user-mappable Plug targets"] = function()
  child.cmd("Difit")
  child.lua([[
    vim.keymap.set("n", "<F3>", "<Plug>(difit-toggle-mode)")
    vim.keymap.set("n", "<F4>", "<Plug>(difit-focus-panel)")
  ]])

  set_cursor(child, 5)
  child.type_keys("<CR>") -- move away from the panel first

  child.type_keys("<F3>")
  eq(session_field(child, "mode"), "unified")

  child.type_keys("<F4>")
  eq(panel_is_current_win(child), true)
end

---------------------------------------------------------------------------------------
-- R1 (docs/refactor-v1.md): the session registry replacing the old M._session/M._panel/
-- M._viewer_tab singletons. Covers the four scenarios called out for this phase: focusing
-- an existing review instead of duplicating it, `:Difit close` from inside the viewer
-- (twice), a manual `:tabclose` reconciling the registry, and the `WinClosed` teardown
-- path when only the panel window closes. A fifth (two concurrent reviews) is included
-- too -- cheap enough to arrange with a second temp repo + `:tcd`.
---------------------------------------------------------------------------------------

--- Resolve symlinks on both sides before comparing paths (mirrors tests/test_git.lua):
--- on macOS `$TMPDIR` resolves through a `/private` symlink, so git's (already-resolved)
--- toplevel can otherwise differ textually from a freshly `tempname()`d dir while still
--- pointing at the same directory.
---@param path string
---@return string
local function realpath(path)
  return vim.uv.fs_realpath(path)
end

T["registry: `:Difit` twice for the same repo/branch focuses the existing viewer instead of duplicating it"] = function()
  local origin_tab = current_tab(child)
  eq(tab_count(child), 1)

  child.cmd("Difit")
  local viewer_tab = current_tab(child)
  eq(tab_count(child), 2)
  eq(viewer_tab ~= origin_tab, true)

  -- Navigate back to the origin tabpage before asking again, so this actually exercises
  -- "an existing entry with the same review key elsewhere" rather than the separate
  -- "already inside a viewer" shortcut in `M.open`.
  child.lua("vim.api.nvim_set_current_tabpage(...)", { origin_tab })
  eq(current_tab(child), origin_tab)

  child.cmd("Difit")

  eq(tab_count(child), 2, "no duplicate viewer tabpage for the same review key")
  eq(current_tab(child), viewer_tab, "the existing viewer's tabpage is focused instead")
end

T["registry: `:Difit close` from inside the viewer returns to the origin tab; a second `:Difit close` is a harmless no-op"] = function()
  local origin_tab = current_tab(child)

  child.cmd("Difit")
  eq(tab_count(child), 2)

  child.cmd("Difit close")
  eq(is_open(child), false)
  eq(tab_count(child), 1)
  eq(current_tab(child), origin_tab)

  eq(pcall(child.cmd, "Difit close"), true, "closing again from the origin tab must not error")
  eq(tab_count(child), 1)
  eq(current_tab(child), origin_tab)
end

T["registry: manually `:tabclose`-ing the viewer tab cleans the registry; a following `:Difit` opens fresh"] = function()
  child.cmd("Difit")
  eq(tab_count(child), 2)

  child.cmd("tabclose")
  eq(tab_count(child), 1)
  eq(is_open(child), false, "TabClosed reconciled the registry entry away")

  eq(pcall(child.cmd, "Difit"), true, "re-opening after a manual :tabclose must not error")
  eq(is_open(child), true)
  eq(tab_count(child), 2)
end

T["registry: closing the panel window with `:q` tears the whole review down (WinClosed path)"] = function()
  local origin_tab = current_tab(child)

  child.cmd("Difit")
  eq(tab_count(child), 2)
  -- Sanity: a diff view is open alongside the panel (3 windows), so this exercises the
  -- WinClosed path with OTHER difit windows still present in the tab -- distinct from
  -- `:tabclose` above, which never leaves the panel window closing on its own.
  eq(#child.lua_get("vim.api.nvim_tabpage_list_wins(0)") >= 2, true)

  focus_panel(child)
  eq(pcall(child.type_keys, "q"), true, "no error from closing just the panel window")

  eq(is_open(child), false)
  eq(tab_count(child), 1)
  eq(current_tab(child), origin_tab)
end

T["registry: two concurrent reviews (different repos) get independent tabpages and close independently"] = function()
  local repo2 = helpers.fixture_branch_repo()

  local origin_tab = current_tab(child)
  child.cmd("Difit")
  local viewer1_tab = current_tab(child)
  eq(tab_count(child), 2)

  child.lua("vim.api.nvim_set_current_tabpage(...)", { origin_tab })
  child.cmd("tcd " .. vim.fn.fnameescape(repo2.dir))

  child.cmd("Difit")
  local viewer2_tab = current_tab(child)
  eq(tab_count(child), 3, "a second, distinct review key gets its own tabpage")
  eq(viewer2_tab ~= viewer1_tab, true)
  eq(realpath(session_field(child, "spec.repo.toplevel")), realpath(repo2.dir))

  -- Closing the second review must not disturb the first.
  child.cmd("Difit close")
  eq(tab_count(child), 2)
  eq(current_tab(child), origin_tab)

  child.lua("vim.api.nvim_set_current_tabpage(...)", { viewer1_tab })
  eq(is_open(child), true, "the other review is untouched by closing this one")
  eq(is_viewed(child, paths.modified), false)

  child.cmd("Difit close")
  eq(tab_count(child), 1)

  repo2:destroy()
end

return T
