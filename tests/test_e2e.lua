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

--- Replace `vim.notify` inside the child with one that records every call -- mirrors
--- tests/test_session.lua's/tests/test_panel.lua's own `install_notify_capture` helpers
--- (this file otherwise inlines the same few lines at each of its two pre-existing call
--- sites; new cases below use this instead of adding a third/fourth copy).
---@param child table
local function install_notify_capture(child)
  child.lua([[
    _G.__notifications = {}
    vim.notify = function(msg, level)
      table.insert(_G.__notifications, { msg = msg, level = level })
    end
  ]])
end

---@param child table
---@return table[]
local function notifications(child)
  return child.lua_get("_G.__notifications")
end

--- Stub `vim.ui.select` inside the child to record every call (items formatted via the
--- caller-supplied `opts.format_item`, plus `opts.prompt`) into `_G.__select_log`, then
--- invoke `on_choice` with whatever `pick` returns for that call's `items` -- lets tests
--- assert exactly what `run_sweep_selector` (init.lua) offered, without a real interactive
--- picker in the loop. `pick` defaults to "always cancel" (`function() return nil end`),
--- the safest default for tests that only care THAT/whether a menu appeared.
---@param child table
---@param pick_body string?  -- Lua source for a `function(items) return <chosen item>|nil end`
---  expression, evaluated INSIDE the child (a real Lua function can't cross the RPC
---  boundary) -- defaults to always cancelling.
local function stub_ui_select(child, pick_body)
  child.lua(
    [[
      local pick_body = ...
      local pick = pick_body and assert(loadstring("return " .. pick_body))() or function()
        return nil
      end
      _G.__select_log = {}
      vim.ui.select = function(items, opts, on_choice)
        local formatted = {}
        for _, item in ipairs(items) do
          table.insert(formatted, opts.format_item(item))
        end
        table.insert(_G.__select_log, { prompt = opts.prompt, formatted = formatted })
        on_choice(pick(items))
      end
    ]],
    { pick_body }
  )
end

---@param child table
---@return {prompt: string, formatted: string[]}[]
local function select_log(child)
  return child.lua_get("_G.__select_log")
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
--- shows a `difit://panel/...` buffer, plus exactly one unified window showing `path` and
--- nothing else. Unlike the pre-overlay design, the unified window's buffer is the REAL
--- file in worktree mode (docs/refactor-v1.md's now-implemented inline-overlay note) --
--- not a `difit://unified/...` scratch buffer -- so this asserts `path`'s own name instead,
--- mirroring `assert_sidebyside_layout`'s right-hand check.
---@param child table
---@param path string
local function assert_unified_layout(child, path)
  local snap = layout_snapshot(child)
  eq(snap.mode, "unified")
  eq(vim.startswith(snap.panel_bufname, "difit://panel/"), true)
  eq(snap.win_count, 2, "panel + the unified window, nothing orphaned")
  eq(vim.endswith(snap.unified_bufname or "", "/" .. path), true)
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

  local restore_gh = helpers.child_path_shim(
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

-- 7. `s` switches to unified mode, which shows the real file inline with its overlay -----

T["7. `s` switches to unified mode, showing the real file inline with its overlay"] = function()
  set_size(child, 24, 100)
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>")
  eq(session_field(child, "current_path"), paths.modified)

  focus_panel(child)
  child.type_keys("s")
  eq(session_field(child, "mode"), "unified")

  -- Unlike every other difit-owned buffer in these screenshots, the unified window now
  -- shows the REAL worktree file (docs/refactor-v1.md's inline-overlay note) at its actual
  -- absolute path -- which embeds `vim.fn.tempname()`'s random component, same as the
  -- tabline problem `set_size` already works around, just via the default ruler/statusline
  -- instead. `%t` (tail-of-filename only) keeps the golden deterministic without losing
  -- anything this test actually cares about (the buffer's own name is asserted below).
  child.o.statusline = "%<%t %m"
  expect_screenshot(child)

  -- `set_mode` always builds a fresh view whose own `close()` destroys the outgoing
  -- view's windows (docs/refactor-v1.md R2), so the only non-panel window left in the tab
  -- is the unified one, and pressing `s` already focused it (unified.lua's `open()`
  -- always takes focus for itself). Unlike the old patch-buffer design, that window now
  -- shows the real worktree file directly (docs/refactor-v1.md's now-implemented
  -- inline-overlay note) -- no jump needed -- with the +/- diff painted on top of it via
  -- its own dedicated extmark namespace.
  local state = child.lua([[
    local entry = __difit_entry()
    local view = entry.session._view
    local buf = vim.api.nvim_win_get_buf(view.win)
    return {
      bufname = vim.api.nvim_buf_get_name(buf),
      filetype = vim.bo[buf].filetype,
      modifiable = vim.bo[buf].modifiable,
      overlay_marks = #vim.api.nvim_buf_get_extmarks(buf, view.ns, 0, -1, {}),
    }
  ]])

  eq(vim.endswith(state.bufname, "/" .. paths.modified), true)
  eq(state.filetype, "lua", "the real file keeps its own filetype -- LSP/syntax works")
  eq(state.modifiable, true)
  eq(state.overlay_marks > 0, true, "the +/- overlay is drawn on top of the real buffer")
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

-- Regression (finding 1, docs/refactor-v1.md R2): difit must never touch a window it
-- doesn't own. This used to require a `reap_stray_windows` sweep that recognized "my
-- windows" by name/registry and left everything else alone; now it holds trivially,
-- since no such sweep exists at all -- views only ever create/close windows they
-- themselves opened via their explicit `ctx.anchor`/`ctx.claim`, so a user's own split can
-- never even be mistaken for one of difit's.
-----------------------------------------------------------------------------------------

T["a user's real-file split survives a refresh and a mode switch; the outgoing view's own windows are still closed"] = function()
  set_size(child, 24, 100)
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- opens the sidebyside view (2 windows)

  -- Simulate the user opening their own split on a real, unrelated file inside the
  -- viewer tabpage (e.g. :vsplit or :help) -- difit has no business ever closing this.
  child.cmd("vsplit " .. vim.fn.fnameescape(repo.dir .. "/README.md"))
  local user_win = child.lua_get("vim.api.nvim_get_current_win()")
  eq(vim.endswith(child.lua_get("vim.api.nvim_buf_get_name(0)"), "/README.md"), true)

  focus_panel(child)
  child.type_keys("R") -- refresh -> session:refresh()

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

  -- Mode switch: the outgoing sidebyside view's own windows must be closed by its own
  -- `close()` (docs/refactor-v1.md R2), same end result as the old reaper, but as a
  -- direct consequence of the view owning its windows rather than a separate sweep.
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

-- Regression (finding 2, OBSOLETE as of the inline-overlay unified view): this used to
-- guard `ui/unified.lua`'s own `target_window()` helper, which resolved a window to jump
-- a real file INTO when `<CR>` was pressed on a patch-buffer line. docs/refactor-v1.md's
-- inline-overlay rewrite deleted that whole jump mechanism -- the unified window already
-- IS the real file in worktree mode, so there is nothing left to jump to, and no
-- "previous window" ambiguity for it to fall into. See tests/test_unified.lua for the
-- current window-ownership coverage (`ensure_window`/`ctx.claim`/`ctx.anchor`).

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
-- keymaps.universal / keymaps.diff's new toggle_mode/focus_panel/close actions, and
-- `:Difit focus` -- the fix for "no discoverable way back to the panel, and no way to
-- toggle mode or mark viewed from the real file buffer". Default mapleader is backslash
-- (never overridden here), so `<leader>x` is sent as the literal two keys `\x` below
-- (mirrors tests/test_sidebyside.lua and tests/test_unified.lua).
---------------------------------------------------------------------------------------

T["from the side-by-side right buffer, <leader>s (keymaps.universal.toggle_mode) switches to unified"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- focus lands on the real worktree right buffer
  eq(session_field(child, "current_path"), paths.modified)

  child.type_keys([[\s]])

  eq(session_field(child, "mode"), "unified")
end

T["<leader>v (keymaps.universal.toggle_viewed) from the real file buffer marks viewed, auto-advances, and syncs the panel's cursor"] = function()
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

T["<leader>e (keymaps.universal.focus_panel) from the real file buffer focuses the panel"] = function()
  child.cmd("Difit")

  set_cursor(child, 5)
  child.type_keys("<CR>")
  eq(panel_is_current_win(child), false, "sanity: focus is on the real file buffer, not the panel")

  child.type_keys([[\e]])

  eq(panel_is_current_win(child), true)
end

T["<leader>v (keymaps.universal.toggle_viewed) pressed IN THE PANEL marks the row and auto-advances exactly like v"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys([[\v]]) -- the literal keys `<leader>v` sends with the default mapleader

  eq(is_viewed(child, paths.modified), true)
  eq(panel_lines(child)[2], "1/4 viewed")
  -- Same auto-advance target as the `v` key (scenario 2 above): next_unviewed wraps to
  -- src/new.lua, and the panel's own cursor follows it (on_toggle_viewed manages this
  -- directly, since the toggle originated in the panel itself).
  eq(session_field(child, "current_path"), paths.new)
  eq(panel_cursor_row(child), 6)
end

T["q in the unified buffer (keymaps.diff.close) closes the entire viewer"] = function()
  -- `right = "head"` so the unified window is a difit-owned HEAD blob (gets
  -- `keymaps.diff`'s bare `q`) rather than the real worktree file -- worktree mode's real
  -- buffer only ever gets `keymaps.universal` (no local `q`; see tests/test_unified.lua's
  -- "real buffer rule" coverage), by the same design as `ui/sidebyside.lua`'s own
  -- worktree right-hand window.
  child.lua([[require("difit.config").setup({ right = "head" })]])
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
  assert_unified_layout(child, paths.modified)

  focus_panel(child)
  child.type_keys("s")
  assert_sidebyside_layout(child, paths.modified)

  -- (b) from the unified buffer itself, `<leader>s` -> side-by-side (first get back into
  -- unified via the panel, then press `<leader>s` from inside the unified buffer --
  -- unified's own `open()` already focuses itself, so no `focus_panel` before this second
  -- toggle). In worktree mode (the default here) the unified window IS the real file, so
  -- only `keymaps.universal`'s leader-prefixed toggle applies -- unlike the pre-overlay
  -- design, bare `s` (`keymaps.diff`) is never mapped there (see tests/test_unified.lua's
  -- "real buffer rule" coverage).
  focus_panel(child)
  child.type_keys("s")
  assert_unified_layout(child, paths.modified)

  child.type_keys([[\s]]) -- keymaps.universal.toggle_mode, pressed from inside the unified buffer
  assert_sidebyside_layout(child, paths.modified)

  -- (c) from the side-by-side real right buffer, `<leader>s` -> unified -> (in the
  -- unified buffer) `<leader>s` -> side-by-side. `open()`/`set_mode` already leave focus
  -- on the real right buffer in worktree mode, so no extra navigation is needed here.
  child.type_keys([[\s]]) -- keymaps.universal.toggle_mode
  assert_unified_layout(child, paths.modified)

  child.type_keys([[\s]]) -- keymaps.universal.toggle_mode, from inside the unified buffer
  assert_sidebyside_layout(child, paths.modified)
end

-- Regression (bug report): switching side-by-side <-> unified changed the panel's own
-- width. Both views split rightward FROM the panel window (ctx.anchor -- see
-- ui/sidebyside.lua's `ensure_windows`/ui/unified.lua's `ensure_window`), so every mode
-- switch closes/reopens diff-area windows right next to the panel; without 'winfixwidth'
-- Neovim's default 'equalalways' re-equalizes every non-fixed window (including the panel)
-- at that moment, and the fresh split also transiently carves space straight out of the
-- panel while it's being created. A non-default `panel.width` (30, distinct from this
-- file's other scenarios' default 35) makes the drift impossible to miss by coincidence.
T["panel width survives repeated mode switches and diff-area window churn"] = function()
  set_size(child, 24, 100)
  child.lua([[require("difit.config").setup({ panel = { width = 30 } })]])

  child.cmd("Difit")

  local function panel_width()
    return child.lua_get("vim.api.nvim_win_get_width(__difit_entry().panel.win)")
  end

  eq(panel_width(), 30, "initial width matches config.panel.width")

  for i = 1, 2 do
    focus_panel(child)
    child.type_keys("s") -- -> unified
    eq(session_field(child, "mode"), "unified")
    eq(panel_width(), 30, "unchanged after switching to unified (round " .. i .. ")")

    focus_panel(child)
    child.type_keys("s") -- -> sidebyside
    eq(session_field(child, "mode"), "sidebyside")
    eq(panel_width(), 30, "unchanged after switching back to sidebyside (round " .. i .. ")")
  end

  -- Window churn in the diff area alone (opening different files, no mode switch) must
  -- not disturb the panel's width either.
  focus_panel(child)
  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>")
  eq(panel_width(), 30, "unchanged after opening src/mod.lua")

  focus_panel(child)
  set_cursor(child, 6) -- src/new.lua
  child.type_keys("<CR>")
  eq(panel_width(), 30, "unchanged after opening src/new.lua")
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
-- `]f`/`[f` (keymaps.universal.next_file/prev_file): plain file navigation, distinct
-- from `v`'s "next UN-VIEWED file" -- covers ALL files (fixture file_order: gone.lua <
-- mod.lua < new.lua < renamed.lua, rows 4-7, matching the header comment above), works
-- from both the real side-by-side buffer and the panel itself, wraps at both ends, and
-- is reachable via <Plug> too. `H` (keymaps.panel.toggle_hide_viewed) is a pure display
-- filter on the panel -- covered separately below.
---------------------------------------------------------------------------------------

T["]f/[f from the side-by-side real buffer cycle through the fixture's files, following bufname/panel cursor, and wrap"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- focus lands on the real worktree right buffer
  eq(session_field(child, "current_path"), paths.modified)
  local prev_bufname = child.lua_get("vim.api.nvim_buf_get_name(0)")

  child.type_keys("]f")
  eq(session_field(child, "current_path"), paths.new)
  eq(panel_cursor_row(child), 6)
  local bufname = child.lua_get("vim.api.nvim_buf_get_name(0)")
  eq(bufname ~= prev_bufname, true, "bufname changed to the next file")
  eq(
    vim.endswith(bufname, "/" .. paths.new),
    true,
    "src/new.lua exists in the worktree -- shown as the real file"
  )
  prev_bufname = bufname

  child.type_keys("]f")
  eq(session_field(child, "current_path"), paths.renamed_to)
  eq(panel_cursor_row(child), 7)
  bufname = child.lua_get("vim.api.nvim_buf_get_name(0)")
  eq(bufname ~= prev_bufname, true, "bufname changed again")
  eq(vim.endswith(bufname, "/" .. paths.renamed_to), true)

  child.type_keys("]f") -- wraps from the last file (renamed.lua) back to the first (gone.lua)
  eq(session_field(child, "current_path"), paths.deleted)
  eq(panel_cursor_row(child), 4)

  child.type_keys("[f") -- wraps back to the last file
  eq(session_field(child, "current_path"), paths.renamed_to)
  eq(panel_cursor_row(child), 7)
end

T["]f from the panel opens the next file (relative to the row under the cursor) and moves the panel's own cursor there"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua row
  child.type_keys("]f")

  eq(session_field(child, "current_path"), paths.new)
  eq(panel_cursor_row(child), 6)
end

T["bonus: <Plug>(difit-next-file) and <Plug>(difit-prev-file) work as user-mappable Plug targets"] = function()
  child.cmd("Difit")
  child.lua([[
    vim.keymap.set("n", "<F5>", "<Plug>(difit-next-file)")
    vim.keymap.set("n", "<F6>", "<Plug>(difit-prev-file)")
  ]])

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- move away from the panel; current_path = src/mod.lua
  eq(session_field(child, "current_path"), paths.modified)

  child.type_keys("<F5>")
  eq(session_field(child, "current_path"), paths.new)

  child.type_keys("<F6>")
  eq(session_field(child, "current_path"), paths.modified)
end

T["H in the panel hides a viewed file and shows it again"] = function()
  child.cmd("Difit")

  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("v") -- mark viewed (auto-advance moves the diff on, panel stays put)
  eq(is_viewed(child, paths.modified), true)

  focus_panel(child)
  child.type_keys("H")

  local hidden_lines = panel_lines(child)
  for _, l in ipairs(hidden_lines) do
    eq(l:find("mod.lua", 1, true), nil, "the viewed file's row is hidden")
  end
  eq(hidden_lines[2]:find("hidden", 1, true) ~= nil, true, "header gains the hidden-filter suffix")

  child.type_keys("H")

  local shown_lines = panel_lines(child)
  local found = false
  for _, l in ipairs(shown_lines) do
    if l:find("mod.lua", 1, true) then
      found = true
    end
  end
  eq(found, true, "the file's row is shown again")
  eq(shown_lines[2]:find("hidden", 1, true), nil, "header suffix is gone once the filter is off")
end

---------------------------------------------------------------------------------------
-- viewed_patterns / S (sweep) / V (subtree): bulk viewed-marking, explicit-trigger only
-- (README.md/doc/difit.txt's "no automatic marking" note still holds -- this feature is
-- just another manual trigger, same spirit as `v`). Uses a purpose-built repo, `tcd`-ed
-- into like the R1 "two concurrent reviews" tests below, rather than the shared
-- `fixture_branch_repo` -- a lockfile-style glob needs to pick out exactly ONE file,
-- distinct from "every file under src/", to prove the pattern (not just "mark everything")
-- is actually doing the matching.
---------------------------------------------------------------------------------------

--- main with one commit, `feature` adding both a generated-style lockfile and an
--- unrelated source file -- entries sort by path: "src/app.lua" (row 4, under dir "src"
--- at row 3), "yarn.lock" (row 5).
---@return difit.test.Repo
local function lock_pattern_repo()
  local r = helpers.new_repo()
  r:write("README.md", "base\n")
  r:commit("chore: base")
  r:branch("feature")
  r:write("yarn.lock", "lockfile v1\n")
  r:write("src/app.lua", "return {}\n")
  r:commit("feat: add app.lua + a generated lockfile")
  return r
end

T["viewed_patterns: S marks matching files, updates progress, and auto-advances; S again unmarks them"] = function()
  local lock_repo = lock_pattern_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(lock_repo.dir))
  child.lua([[require("difit.config").setup({ viewed_patterns = { "*.lock" } })]])

  child.cmd("Difit")
  eq(panel_lines(child)[2], "0/2 viewed")
  eq(session_field(child, "current_path"), "src/app.lua", "the only un-viewed file auto-opens")
  eq(panel_is_current_win(child), true, "sanity: panel already has focus right after :Difit opens")

  child.type_keys("S")

  eq(is_viewed(child, "yarn.lock"), true)
  eq(is_viewed(child, "src/app.lua"), false, "the pattern only matches the lockfile")
  eq(panel_lines(child)[2], "1/2 viewed")
  eq(
    session_field(child, "current_path"),
    "src/app.lua",
    "auto-advance (marking batch): next_unviewed(nil) re-resolves the only remaining un-viewed file"
  )

  focus_panel(child)
  child.type_keys("S") -- "*.lock" only ever matches yarn.lock, and it's now fully viewed -> unmark

  eq(is_viewed(child, "yarn.lock"), false)
  eq(panel_lines(child)[2], "0/2 viewed")

  lock_repo:destroy()
end

T["viewed_patterns: V on the src dir marks its files; V again unmarks them"] = function()
  local lock_repo = lock_pattern_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(lock_repo.dir))

  child.cmd("Difit")
  focus_panel(child)
  set_cursor(child, 3) -- "src" dir row
  child.type_keys("V")

  eq(is_viewed(child, "src/app.lua"), true)
  eq(is_viewed(child, "yarn.lock"), false, "V on a dir only touches that subtree")
  eq(panel_lines(child)[2], "1/2 viewed")

  focus_panel(child) -- the marking batch's auto-advance moved focus to yarn.lock's diff
  set_cursor(child, 3)
  child.type_keys("V")

  eq(is_viewed(child, "src/app.lua"), false)
  eq(panel_lines(child)[2], "0/2 viewed")

  lock_repo:destroy()
end

T["`:Difit sweep` works from the diff buffer, same effect as pressing S in the panel"] = function()
  local lock_repo = lock_pattern_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(lock_repo.dir))
  child.lua([[require("difit.config").setup({ viewed_patterns = { "*.lock" } })]])

  child.cmd("Difit")
  set_cursor(child, 4) -- src/app.lua
  child.type_keys("<CR>") -- move focus onto the real diff buffer, away from the panel
  eq(panel_is_current_win(child), false)

  child.cmd("Difit sweep")

  eq(is_viewed(child, "yarn.lock"), true)
  eq(panel_lines(child)[2], "1/2 viewed")

  lock_repo:destroy()
end

T["`:Difit sweep` notifies when viewed_patterns is not configured, without marking anything"] = function()
  child.cmd("Difit")

  child.lua([[
    _G.__notifications = {}
    vim.notify = function(msg, level)
      table.insert(_G.__notifications, { msg = msg, level = level })
    end
  ]])

  child.cmd("Difit sweep")

  local notes = child.lua_get("_G.__notifications")
  eq(#notes, 1)
  eq(notes[1].msg, "difit: viewed_patterns is not configured")
  eq(is_viewed(child, paths.modified), false)
end

---------------------------------------------------------------------------------------
-- Named pattern GROUPS (`viewed_patterns` items shaped `{name=, patterns=}`): the shared
-- 0/1/N-group selector flow behind both `S` and `:Difit sweep [name]` -- see init.lua's
-- `run_sweep_selector`/`perform_sweep`. `lock_pattern_repo()` above (a single flat string
-- list, one implicit "default" group) already covers the 1-group "no menu" case for the
-- pre-groups behavior it was written against; `two_group_repo()` below adds a second,
-- disjoint group so the 2+-group menu path has something real to pick between.
---------------------------------------------------------------------------------------

--- main with one commit, `feature` adding a lockfile, a generated-style file, and an
--- unrelated source file -- entries sort by path: "generated/out.txt" (row 4, under dir
--- "generated" at row 3), "src/app.lua" (row 6, under dir "src" at row 5), "yarn.lock"
--- (row 7).
---@return difit.test.Repo
local function two_group_repo()
  local r = helpers.new_repo()
  r:write("README.md", "base\n")
  r:commit("chore: base")
  r:branch("feature")
  r:write("yarn.lock", "lockfile v1\n")
  r:write("generated/out.txt", "generated\n")
  r:write("src/app.lua", "return {}\n")
  r:commit("feat: add app.lua + generated output + a lockfile")
  return r
end

---@param child table
local function configure_two_groups(child)
  child.lua([[
    require("difit.config").setup({
      viewed_patterns = {
        { name = "lock files", patterns = { "*.lock" } },
        { name = "generated", patterns = { "generated/**" } },
      },
    })
  ]])
end

T["exactly one configured group sweeps immediately on `S`/`:Difit sweep`, without ever calling vim.ui.select"] = function()
  local lock_repo = lock_pattern_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(lock_repo.dir))
  child.lua([[require("difit.config").setup({ viewed_patterns = { "*.lock" } })]])
  stub_ui_select(child)

  child.cmd("Difit")
  child.cmd("Difit sweep")

  eq(#select_log(child), 0, "a single group must sweep directly, never opening a menu")
  eq(is_viewed(child, "yarn.lock"), true)

  lock_repo:destroy()
end

T["2+ configured groups open a vim.ui.select menu: 'all groups' first, then each group, formatted with counts"] = function()
  local repo = two_group_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(repo.dir))
  configure_two_groups(child)
  stub_ui_select(child) -- default: cancels

  child.cmd("Difit")
  child.cmd("Difit sweep")

  local log = select_log(child)
  eq(#log, 1)
  eq(log[1].prompt, "Sweep pattern group:")
  eq(log[1].formatted, {
    "all groups (2 files, 2 unviewed)",
    "lock files (1 files, 1 unviewed)",
    "generated (1 files, 1 unviewed)",
  })

  -- Cancelling out of the menu must be a complete no-op.
  eq(is_viewed(child, "yarn.lock"), false)
  eq(is_viewed(child, "generated/out.txt"), false)
  eq(panel_lines(child)[2], "0/3 viewed")

  repo:destroy()
end

T["picking a specific group from the menu sweeps only that group and updates progress"] = function()
  local repo = two_group_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(repo.dir))
  configure_two_groups(child)
  -- items[1] is "all groups"; items[2] is the first configured group, "lock files".
  stub_ui_select(child, "function(items) return items[2] end")

  child.cmd("Difit")
  eq(panel_lines(child)[2], "0/3 viewed")

  child.cmd("Difit sweep")

  eq(is_viewed(child, "yarn.lock"), true)
  eq(is_viewed(child, "generated/out.txt"), false, "only the picked group was swept")
  eq(panel_lines(child)[2], "1/3 viewed")

  repo:destroy()
end

T["picking 'all groups' from the menu sweeps the union of every group"] = function()
  local repo = two_group_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(repo.dir))
  configure_two_groups(child)
  stub_ui_select(child, "function(items) return items[1] end")

  child.cmd("Difit")
  child.cmd("Difit sweep")

  eq(is_viewed(child, "yarn.lock"), true)
  eq(is_viewed(child, "generated/out.txt"), true)
  eq(is_viewed(child, "src/app.lua"), false, "src/app.lua matches neither group")
  eq(panel_lines(child)[2], "2/3 viewed")

  repo:destroy()
end

T["`S` in the panel opens the exact same menu as `:Difit sweep`"] = function()
  local repo = two_group_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(repo.dir))
  configure_two_groups(child)
  stub_ui_select(child, "function(items) return items[2] end")

  child.cmd("Difit")
  focus_panel(child)
  child.type_keys("S")

  local log = select_log(child)
  eq(#log, 1)
  eq(log[1].formatted[1]:find("all groups", 1, true) ~= nil, true)
  eq(is_viewed(child, "yarn.lock"), true)

  repo:destroy()
end

T["`:Difit sweep {name}` with a multi-word group name sweeps just that group, no menu"] = function()
  local repo = two_group_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(repo.dir))
  configure_two_groups(child)
  stub_ui_select(child)

  child.cmd("Difit")
  child.cmd("Difit sweep lock files")

  eq(#select_log(child), 0, "an explicit name must never open the menu")
  eq(is_viewed(child, "yarn.lock"), true)
  eq(is_viewed(child, "generated/out.txt"), false)
end

T["`:Difit sweep {name}` resolves a unique prefix when no exact match exists"] = function()
  local repo = two_group_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(repo.dir))
  configure_two_groups(child)
  stub_ui_select(child)

  child.cmd("Difit")
  child.cmd("Difit sweep lock")

  eq(is_viewed(child, "yarn.lock"), true, "'lock' is a unique prefix of 'lock files'")
end

T["`:Difit sweep {unknown}` notifies WARN listing the available groups, without marking anything"] = function()
  local repo = two_group_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(repo.dir))
  configure_two_groups(child)
  child.cmd("Difit")
  install_notify_capture(child)

  child.cmd("Difit sweep nonexistent")

  local notes = notifications(child)
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.WARN)
  eq(notes[1].msg:find("nonexistent", 1, true) ~= nil, true)
  eq(notes[1].msg:find("lock files", 1, true) ~= nil, true)
  eq(notes[1].msg:find("generated", 1, true) ~= nil, true)
  eq(is_viewed(child, "yarn.lock"), false)
end

T["notifications from a sweep include the resolved scope: the group name, or 'all groups' for the union"] = function()
  local repo = two_group_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(repo.dir))
  configure_two_groups(child)
  install_notify_capture(child)

  child.cmd("Difit")
  child.cmd("Difit sweep lock files")

  local notes = notifications(child)
  eq(#notes, 1)
  eq(notes[1].msg, "difit: marked 1 files as viewed (lock files)")
end

T["`:Difit sweep <Tab>` completion offers the live review's group names, spaces backslash-escaped"] = function()
  local repo = two_group_repo()
  child.cmd("tcd " .. vim.fn.fnameescape(repo.dir))
  configure_two_groups(child)
  child.cmd("Difit")

  local candidates = child.lua_get([[vim.fn.getcompletion("Difit sweep ", "cmdline")]])
  table.sort(candidates)
  local expected = { "generated", "lock\\ files" }
  table.sort(expected)
  eq(candidates, expected)
end

T["`:Difit sweep <Tab>` completion offers no candidates outside a viewer tabpage"] = function()
  local candidates = child.lua_get([[vim.fn.getcompletion("Difit sweep ", "cmdline")]])
  eq(candidates, {})
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

-- Buffer-name collision across sessions (found in R2 testing, fixed in R4): two
-- concurrent reviews sharing identical blob content used to collide on the exact same
-- `difit://<sha>/<path>` buffer name -- the second session's `nvim_buf_set_name` would
-- silently repoint the FIRST session's buffer, and that view's own `close()` would then
-- force-close windows the other session still owned. Unlike commit shas (which vary with
-- author/committer timestamps -- see the comment on the mode-switch isolation test
-- below), a git BLOB sha is a pure hash of content, so writing byte-identical file
-- content into two otherwise-unrelated repos deterministically reproduces the same
-- `entry.head_sha` in both, regardless of timing. `ui/scratch.lua` now embeds a
-- per-session discriminator (`ctx.anchor`) in every owned buffer name, so this must no
-- longer collide.
T["registry: two concurrent sessions with byte-identical blob content never collide on the same difit:// buffer; closing one leaves the other intact"] = function()
  set_size(child, 24, 100)

  local function make_repo()
    local r = helpers.new_repo()
    r:write("shared.txt", "identical content\n")
    r:commit("chore: base")
    r:branch("feature")
    r:write("shared.txt", "identical content\nplus a change\n")
    r:commit("feat: change shared.txt")
    return r
  end
  local repoA = make_repo()
  local repoB = make_repo()

  eq(
    repoA:git({ "rev-parse", "feature:shared.txt" }),
    repoB:git({ "rev-parse", "feature:shared.txt" }),
    "sanity: both repos produce the identical blob sha for shared.txt"
  )

  -- `right = "head"` makes BOTH diff windows blob-backed (keyed purely by sha, no
  -- worktree real-file window in the mix), so the collision is exercised on both sides.
  child.lua([[require("difit.config").setup({ right = "head" })]])

  local origin_tab = current_tab(child)

  child.cmd("tcd " .. vim.fn.fnameescape(repoA.dir))
  child.cmd("Difit")
  local tab_a = current_tab(child)
  eq(session_field(child, "current_path"), "shared.txt", "sanity: the only changed file auto-opens")
  local before = layout_snapshot(child)

  child.lua("vim.api.nvim_set_current_tabpage(...)", { origin_tab })
  child.cmd("tcd " .. vim.fn.fnameescape(repoB.dir))
  child.cmd("Difit")
  local tab_b = current_tab(child)
  eq(tab_b ~= tab_a, true)
  eq(session_field(child, "current_path"), "shared.txt")

  local snap_b = layout_snapshot(child)
  eq(snap_b.left_bufname ~= before.left_bufname, true, "left blob buffers must not collide")
  eq(snap_b.right_bufname ~= before.right_bufname, true, "right blob buffers must not collide")

  -- Closing repoB's review must not disturb repoA's still-open windows/buffers.
  child.cmd("Difit close")
  eq(tab_count(child), 2)

  child.lua("vim.api.nvim_set_current_tabpage(...)", { tab_a })
  eq(is_open(child), true, "repoA's review is untouched by closing repoB's")
  eq(layout_snapshot(child), before, "repoA's own layout/buffers are byte-for-byte unchanged")

  child.cmd("Difit close")
  eq(tab_count(child), 1)

  repoA:destroy()
  repoB:destroy()
end

---------------------------------------------------------------------------------------
-- R2/R3 (docs/refactor-v1.md): each session's `view_factory` closure captures its own
-- `ctx` (anchor/claim/actions -- see `ui/keymaps.lua`'s `difit.ui.ViewCtx`), so nothing
-- about one review's windows or buffer-local keymap wiring can leak into another's.
---------------------------------------------------------------------------------------

T["registry: switching mode in one concurrent review never touches the other's windows"] = function()
  set_size(child, 24, 100)
  -- Deliberately NOT `helpers.fixture_branch_repo()` again: that fixture's commits are
  -- byte-identical (same paths/content/messages) across separate calls, and git commit
  -- SHAs only vary by author/committer timestamp -- two calls landing in the same wall-
  -- clock second (routine on a fast machine) produce the SAME merge-base commit SHA, and
  -- therefore the SAME `difit://<sha>/src/mod.lua` buffer name in both reviews. That's a
  -- pre-existing buffer-naming gap (buffer names carry no repo identity) unrelated to
  -- what this test is actually about, so it uses a repo with a distinct path/content
  -- instead of fighting that collision.
  local repo2 = helpers.new_repo()
  repo2:write("a.txt", "1\n")
  repo2:commit("chore: base")
  repo2:branch("feature")
  repo2:write("src/one.lua", "one\n")
  repo2:commit("feat: add one")
  local repo2_path = "src/one.lua"

  local origin_tab = current_tab(child)
  child.cmd("Difit")
  local viewer1_tab = current_tab(child)
  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>")
  assert_sidebyside_layout(child, paths.modified)
  local before = layout_snapshot(child)

  child.lua("vim.api.nvim_set_current_tabpage(...)", { origin_tab })
  child.cmd("tcd " .. vim.fn.fnameescape(repo2.dir))
  child.cmd("Difit")
  local viewer2_tab = current_tab(child)
  eq(viewer2_tab ~= viewer1_tab, true)

  -- repo2's tree is a single "src" dir (one child, so it does NOT compress) containing
  -- one file: row 1 header, row 2 progress, row 3 "src", row 4 "src/one.lua".
  set_cursor(child, 4)
  child.type_keys("<CR>")
  eq(session_field(child, "current_path"), repo2_path)
  focus_panel(child)
  child.type_keys("s") -- toggle_mode fires ONLY in viewer2
  assert_unified_layout(child, repo2_path)

  -- viewer1's own layout/windows are byte-for-byte the same as before viewer2 ever
  -- switched modes -- nothing about viewer2's `set_mode` reached across.
  child.lua("vim.api.nvim_set_current_tabpage(...)", { viewer1_tab })
  eq(layout_snapshot(child), before)
  assert_sidebyside_layout(child, paths.modified)

  child.cmd("Difit close")
  child.lua("vim.api.nvim_set_current_tabpage(...)", { viewer2_tab })
  child.cmd("Difit close")

  repo2:destroy()
end

T["actions resolve at call time: a stale action captured before close() notifies instead of erroring"] = function()
  child.cmd("Difit")
  set_cursor(child, 5) -- src/mod.lua
  child.type_keys("<CR>") -- sidebyside opens; ctx.actions is wired for real from here on

  child.lua([[
    _G.__stale_actions = __difit_entry().session._view.ctx.actions
    _G.__notifications = {}
    vim.notify = function(msg, level)
      table.insert(_G.__notifications, { msg = msg, level = level })
    end
  ]])

  child.cmd("Difit close")

  -- Every action captured from the now-closed review must degrade to a no-op notify,
  -- never raise, when invoked after the fact (docs/refactor-v1.md R3).
  local ok_toggle_viewed =
    child.lua([[return pcall(_G.__stale_actions.toggle_viewed, ...)]], { paths.modified })
  local ok_toggle_mode = child.lua([[return pcall(_G.__stale_actions.toggle_mode)]])
  local ok_focus_panel = child.lua([[return pcall(_G.__stale_actions.focus_panel)]])
  local ok_close = child.lua([[return pcall(_G.__stale_actions.close)]])

  eq(ok_toggle_viewed, true, "stale toggle_viewed must not error")
  eq(ok_toggle_mode, true, "stale toggle_mode must not error")
  eq(ok_focus_panel, true, "stale focus_panel must not error")
  eq(ok_close, true, "stale close must not error")

  local notes = child.lua_get("_G.__notifications")
  eq(#notes, 4, "every stale action call notifies instead of silently erroring")
  for _, n in ipairs(notes) do
    eq(n.level, vim.log.levels.WARN)
  end
end

return T
