-- End-to-end tests for the WP-I integration layer (`require("difit")` + `plugin/difit.lua`):
-- drives the real `:Difit` command against fixture repos in a child Neovim, exercising the
-- full tabpage/panel/view wiring together rather than any single module in isolation. Git
-- is never mocked (see tests/helpers.lua); only `gh` is faked, via the same PATH-shim
-- pattern tests/test_github.lua uses. Screenshot goldens live in tests/screenshots/.
--
-- Covers the 10 scenarios from docs/plan.md's WP-I section, in order, plus one bonus case
-- for `<Plug>(difit-toggle-viewed)` (part of the WP-I contract but not one of the 10).

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
  return child.lua_get([[require("difit")._session ~= nil]])
end

--- Current text of the panel buffer, or `nil` when no session (hence no panel) is open.
---@param child table
---@return string[]|nil
local function panel_lines(child)
  return denil(child.lua_get([[
    (function()
      local difit = require("difit")
      if not difit._panel then
        return vim.NIL
      end
      return vim.api.nvim_buf_get_lines(difit._panel.buf, 0, -1, false)
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
    "local lnum = ...; vim.api.nvim_win_set_cursor(require('difit')._panel.win, { lnum, 0 })",
    { lnum }
  )
end

---@param child table
local function focus_panel(child)
  child.lua([[require("difit")._panel:focus()]])
end

---@param child table
---@param expr string @Lua expression relative to `require("difit")._session`
local function session_field(child, expr)
  return denil(child.lua_get([[require("difit")._session.]] .. expr))
end

---@param child table
---@param path string
---@return boolean
local function is_viewed(child, path)
  return child.lua("return require('difit')._session:is_viewed(...)", { path })
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
    child.lua_get([[require('difit.state').file_path(require('difit')._session.spec.review_key)]])
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
    child.lua_get([[require('difit.state').file_path(require('difit')._session.spec.review_key)]])
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

return T
