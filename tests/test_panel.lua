-- Tests for lua/diffly/ui/panel.lua + lua/diffly/ui/hl.lua (WP-H). Panel rendering and
-- keymaps run in a child Neovim (real buffers/windows/keymaps are needed); panel.lua is
-- driven only through the documented `diffly.Session` interface (see docs/architecture.md),
-- so a scripted fake session -- never `lua/diffly/session.lua` -- stands in here and
-- records every call into `_G.calls` for the assertions below.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

---@return string dir
local function new_tempdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

-- Fixture entries chosen to exercise: a compressible root file (depth 0), a
-- single-file directory ("docs", depth 1 child), a multi-child directory ("lua/diffly",
-- depth 1 children covering every status letter), and a pre-viewed file (state.lua) so
-- rendering the `[ ]`/`[✓]` split doesn't need any keypress. Row numbers below (used by
-- `set_cursor`) assume this exact fixture and no folds:
--   1 header, 2 progress,
--   3 docs, 4 docs/guide.md,
--   5 lua/diffly, 6 gone.lua, 7 new.lua, 8 renamed.lua, 9 state.lua,
--   10 README.md
local FAKE_SESSION_SETUP = [[
  _G.calls = {
    open_file = {},
    toggle_viewed = {},
    toggle_viewed_batch = {},
    sweep = 0,
    next_unviewed = {},
    -- `table.insert(list, nil)` is invisible to `#list` (Lua can't distinguish "absent"
    -- from "present but nil" in the array part), which the batch actions below rely on:
    -- their auto-advance calls `next_unviewed(nil)` ("from the start" -- no single file to
    -- resume from after a scattered batch). This separate counter is the only way tests
    -- can reliably assert "next_unviewed WAS/WAS NOT called" once a nil argument is in play.
    next_unviewed_count = 0,
    next_file = {},
    prev_file = {},
    set_mode = {},
    refresh = 0,
    close = 0,
    subscribe = 0,
  }
  _G.subscribers = {}
  _G.viewed = { ["lua/diffly/state.lua"] = true }

  local entries = {
    { path = "README.md", status = "M", untracked = false, binary = false, additions = 1, deletions = 1 },
    { path = "docs/guide.md", status = "A", untracked = false, binary = false, additions = 5, deletions = 0 },
    {
      path = "lua/diffly/state.lua",
      status = "M",
      untracked = false,
      binary = false,
      additions = 42,
      deletions = 3,
    },
    { path = "lua/diffly/new.lua", status = "A", untracked = false, binary = false, additions = 10, deletions = 0 },
    { path = "lua/diffly/gone.lua", status = "D", untracked = false, binary = false, additions = 0, deletions = 7 },
    {
      path = "lua/diffly/renamed.lua",
      old_path = "lua/diffly/old_name.lua",
      status = "R",
      untracked = false,
      binary = false,
      additions = 2,
      deletions = 1,
    },
  }

  _G.session = {
    spec = {
      repo = { id = "example/repo", toplevel = "/tmp/x" },
      base_ref = "origin/main",
      merge_base = "deadbeef",
      right = "worktree",
      review_key = { kind = "branch", repo = "example/repo", base = "main", head = "feature/x" },
    },
    entries = entries,
    state = { version = 1, key = {}, last_opened = "", viewed = {} },
    mode = "sidebyside",
    current_path = nil,
    _progress = { viewed = 1, total = 6 },
    _next_unviewed_answer = nil,
  }

  function _G.session:subscribe(fn)
    _G.calls.subscribe = _G.calls.subscribe + 1
    table.insert(_G.subscribers, fn)
  end

  function _G.session:open_file(path)
    table.insert(_G.calls.open_file, path)
    self.current_path = path
  end

  function _G.session:toggle_viewed(path)
    table.insert(_G.calls.toggle_viewed, path)
    _G.viewed[path] = not _G.viewed[path]
    for _, fn in ipairs(_G.subscribers) do
      fn()
    end
    return _G.viewed[path]
  end

  -- Same tri-state rule as `lua/diffly/session.lua`'s real `Session:toggle_viewed_batch`:
  -- mark every un-viewed path in the batch if any is un-viewed, else unmark them all.
  -- Fires the subscriber list ONCE per call (never once per path), mirroring the real
  -- method's ONE-save/ONE-notify contract.
  function _G.session:toggle_viewed_batch(paths)
    table.insert(_G.calls.toggle_viewed_batch, paths)

    local any_unviewed = false
    for _, p in ipairs(paths) do
      if not _G.viewed[p] then
        any_unviewed = true
        break
      end
    end

    local marked, unmarked = 0, 0
    if any_unviewed then
      for _, p in ipairs(paths) do
        if not _G.viewed[p] then
          _G.viewed[p] = true
          marked = marked + 1
        end
      end
    else
      for _, p in ipairs(paths) do
        _G.viewed[p] = false
        unmarked = unmarked + 1
      end
    end

    for _, fn in ipairs(_G.subscribers) do
      fn()
    end

    return { marked = marked, unmarked = unmarked, matched = #paths }
  end

  function _G.session:is_viewed(path)
    return _G.viewed[path] == true
  end

  function _G.session:next_unviewed(after_path)
    _G.calls.next_unviewed_count = _G.calls.next_unviewed_count + 1
    table.insert(_G.calls.next_unviewed, after_path)
    return self._next_unviewed_answer
  end

  -- Real `tree.file_order(tree.build(...))` ordering (mirrors `lua/diffly/session.lua`'s
  -- own `next_file`/`prev_file`) rather than another scripted stub: these two need to
  -- actually cycle through `entries` in a realistic order for the wrap/reference-point
  -- assertions below to mean anything.
  function _G.session:next_file(after_path)
    table.insert(_G.calls.next_file, after_path)
    local tree = require("diffly.tree")
    local order = tree.file_order(tree.build(self.entries))
    local n = #order
    if n == 0 then
      return nil
    end
    local start_idx = 0
    if after_path then
      for i, p in ipairs(order) do
        if p == after_path then
          start_idx = i
          break
        end
      end
    end
    return order[(start_idx % n) + 1]
  end

  function _G.session:prev_file(before_path)
    table.insert(_G.calls.prev_file, before_path)
    local tree = require("diffly.tree")
    local order = tree.file_order(tree.build(self.entries))
    local n = #order
    if n == 0 then
      return nil
    end
    local start_idx = n + 1
    if before_path then
      for i, p in ipairs(order) do
        if p == before_path then
          start_idx = i
          break
        end
      end
    end
    return order[((start_idx - 2) % n) + 1]
  end

  function _G.session:progress()
    return self._progress
  end

  function _G.session:set_mode(mode)
    table.insert(_G.calls.set_mode, mode)
    self.mode = mode
    for _, fn in ipairs(_G.subscribers) do
      fn()
    end
  end

  function _G.session:refresh()
    _G.calls.refresh = _G.calls.refresh + 1
    for _, fn in ipairs(_G.subscribers) do
      fn()
    end
  end

  function _G.session:close()
    _G.calls.close = _G.calls.close + 1
  end

  -- The real `sweep` action (`init.lua`'s `run_sweep_selector`, using `vim.ui.select` and
  -- the real `Session:pattern_groups()`/`sweep_patterns()`) is exercised end-to-end in
  -- tests/test_e2e.lua -- panel.lua itself only needs to prove `S` reaches WHATEVER was
  -- injected as `opts.sweep` (see ui/panel.lua's `M.open`/`on_sweep` docs for why the flow
  -- lives in init.lua, not here), so this fake just counts calls.
  _G.__sweep_action = function()
    _G.calls.sweep = _G.calls.sweep + 1
  end

  _G.panel = require("diffly.ui.panel").open(_G.session, { sweep = _G.__sweep_action })
]]

local EXPECTED_LINES = {
  "diffly  main…feature/x",
  "1/6 viewed",
  "▾ docs",
  "    [ ] A guide.md  +5 −0",
  "▾ lua/diffly",
  "    [ ] D gone.lua  +0 −7",
  "    [ ] A new.lua  +10 −0",
  "    [ ] R lua/diffly/old_name.lua → lua/diffly/renamed.lua  +2 −1",
  "    [✓] M state.lua  +42 −3",
  "  [ ] M README.md  +1 −1",
}

local dir, child

local function lines()
  return child.lua_get("vim.api.nvim_buf_get_lines(_G.panel.buf, 0, -1, false)")
end

local function cursor()
  return child.lua_get("vim.api.nvim_win_get_cursor(_G.panel.win)")
end

local function set_cursor(lnum)
  child.lua("local lnum = ...; vim.api.nvim_win_set_cursor(_G.panel.win, { lnum, 0 })", { lnum })
end

--- `vim.fn.maparg(key, "n", false, true)` for `_G.panel.buf`, stripped of its
--- (unserializable) `callback` field before crossing the RPC boundary -- mirrors
--- tests/test_sidebyside.lua's helper of the same purpose.
---@param key string
---@return table
local function buf_maparg(key)
  return child.lua(
    [[
      local key = ...
      local m = vim.api.nvim_buf_call(_G.panel.buf, function()
        return vim.fn.maparg(key, "n", false, true)
      end)
      return { buffer = m.buffer, nowait = m.nowait, lhs = m.lhs }
    ]],
    { key }
  )
end

--- True iff `m` (from `buf_maparg`) describes an actual BUFFER-LOCAL mapping.
---@param m table
---@return boolean
local function mapped(m)
  return m ~= nil and next(m) ~= nil and m.buffer == 1
end

--- Replace `vim.notify` inside the child with one that records every call, so tests can
--- assert on `on_sweep`/`on_toggle_viewed_subtree`'s compact result messages -- mirrors
--- tests/test_session.lua's helper of the same purpose.
local function install_notify_capture()
  child.lua([[
    _G.__notifications = {}
    vim.notify = function(msg, level)
      table.insert(_G.__notifications, { msg = msg, level = level })
    end
  ]])
end

---@return table[]
local function notifications()
  return child.lua_get("_G.__notifications")
end

--- 1-indexed row numbers carrying a `DifflyCurrentFile` extmark in the panel buffer --
--- queried across every namespace (rather than reaching into panel.lua's private `ns`
--- local) so this stays a black-box assertion against the documented rendering behavior.
---@return integer[]
local function current_file_rows()
  return child.lua_get([[
    (function()
      local marks = vim.api.nvim_buf_get_extmarks(_G.panel.buf, -1, 0, -1, { details = true })
      local rows = {}
      for _, m in ipairs(marks) do
        if m[4].hl_group == "DifflyCurrentFile" then
          table.insert(rows, m[2] + 1)
        end
      end
      return rows
    end)()
  ]])
end

--- Every `hl_group` of an extmark STARTING on 1-indexed row `lnum` -- used to check that
--- more than one highlight (e.g. `DifflyViewed` and `DifflyCurrentFile`) coexist on the same
--- row without one clobbering the other.
---@param lnum integer
---@return string[]
local function hl_groups_on_row(lnum)
  return child.lua(
    [[
      local lnum = ...
      local marks = vim.api.nvim_buf_get_extmarks(_G.panel.buf, -1, 0, -1, { details = true })
      local groups = {}
      for _, m in ipairs(marks) do
        if m[2] == lnum - 1 then
          table.insert(groups, m[4].hl_group)
        end
      end
      return groups
    ]],
    { lnum }
  )
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = new_tempdir()
      child = helpers.new_child(dir)
      -- Deterministic rows: no icon provider noise, and a width distinct enough from
      -- the default (35) that the width assertion can't pass by coincidence.
      child.lua([[require("diffly.config").setup({ icons = false, panel = { width = 40 } })]])
      child.lua(FAKE_SESSION_SETUP)
    end,
    post_case = function()
      child.stop()
      vim.fn.delete(dir, "rf")
    end,
  },
})

T["render() shows header, progress, and tree rows in flatten order"] = function()
  eq(lines(), EXPECTED_LINES)
end

T["viewed file shows [✓], un-viewed files show [ ]"] = function()
  local got = lines()
  eq(got[9], "    [✓] M state.lua  +42 −3")
  eq(got[4]:find("^%s*%[ %] A", 1), 1)
  eq(got[10]:find("^%s*%[ %] M", 1), 1)
end

T["render() preserves the cursor's logical file across a background refresh that reshuffles rows"] = function()
  set_cursor(7) -- lua/diffly/new.lua
  eq(child.lua_get("_G.panel.row_nodes[7].path"), "lua/diffly/new.lua")

  -- Simulate a background refresh/subscriber notification (e.g. BufWritePost) that adds
  -- a file sorting *above* the cursor's file within the same directory -- every row
  -- number in "lua/diffly" below it shifts down by one.
  child.lua([[
    table.insert(_G.session.entries, {
      path = "lua/diffly/00_early.lua",
      status = "A",
      untracked = false,
      binary = false,
      additions = 1,
      deletions = 0,
    })
    _G.panel:render()
  ]])

  local new_lnum = child.lua_get([[
    (function()
      for lnum, node in pairs(_G.panel.row_nodes) do
        if node.path == "lua/diffly/new.lua" then
          return lnum
        end
      end
    end)()
  ]])

  eq(new_lnum ~= 7, true, "sanity check: the row actually moved")
  eq(cursor(), { new_lnum, 0 }, "the cursor followed new.lua to its new row")
end

T["render() clamps the cursor to the nearest valid row when its file disappears"] = function()
  set_cursor(6) -- lua/diffly/gone.lua
  eq(child.lua_get("_G.panel.row_nodes[6].path"), "lua/diffly/gone.lua")

  child.lua([[
    for i, e in ipairs(_G.session.entries) do
      if e.path == "lua/diffly/gone.lua" then
        table.remove(_G.session.entries, i)
        break
      end
    end
    _G.panel:render()
  ]])

  local total_lines = #lines()
  local got = cursor()
  eq(got[1] >= 1 and got[1] <= total_lines, true)
end

T["toggle_viewed key calls session:toggle_viewed and auto-advances to next_unviewed"] = function()
  child.lua([[_G.session._next_unviewed_answer = "lua/diffly/new.lua"]])

  set_cursor(4) -- docs/guide.md
  child.type_keys("v")

  eq(child.lua_get("_G.calls.toggle_viewed"), { "docs/guide.md" })
  eq(child.lua_get("_G.calls.next_unviewed"), { "docs/guide.md" })
  eq(cursor(), { 7, 0 }) -- row for lua/diffly/new.lua
  eq(child.lua_get("_G.calls.open_file"), { "lua/diffly/new.lua" })
end

T["toggle_viewed does not auto-advance when config.auto_advance is false"] = function()
  child.lua([[require("diffly.config").setup({ auto_advance = false })]])
  child.lua([[_G.session._next_unviewed_answer = "lua/diffly/new.lua"]])

  set_cursor(4) -- docs/guide.md
  child.type_keys("v")

  eq(child.lua_get("_G.calls.toggle_viewed"), { "docs/guide.md" })
  eq(child.lua_get("_G.calls.next_unviewed"), {})
  eq(child.lua_get("_G.calls.open_file"), {})
end

T["toggle_viewed un-marking an already-viewed file does not auto-advance"] = function()
  child.lua([[_G.session._next_unviewed_answer = "lua/diffly/new.lua"]])

  set_cursor(9) -- lua/diffly/state.lua (starts viewed = true, per FAKE_SESSION_SETUP)
  child.type_keys("v")

  eq(child.lua_get("_G.calls.toggle_viewed"), { "lua/diffly/state.lua" })
  eq(
    child.lua_get("_G.calls.next_unviewed"),
    {},
    "un-marking must never trigger the auto-advance lookup"
  )
  eq(child.lua_get("_G.calls.open_file"), {})
  eq(cursor(), { 9, 0 }, "cursor stays on the row that was just un-marked")
  eq(lines()[9], "    [ ] M state.lua  +42 −3", "row re-renders as un-viewed")
end

T["<CR> on a file row calls session:open_file"] = function()
  set_cursor(9) -- lua/diffly/state.lua
  child.type_keys("<CR>")

  eq(child.lua_get("_G.calls.open_file"), { "lua/diffly/state.lua" })
end

T["<CR> on a dir row folds it, hiding descendants after re-render"] = function()
  set_cursor(5) -- lua/diffly
  child.type_keys("<CR>")

  eq(lines(), {
    "diffly  main…feature/x",
    "1/6 viewed",
    "▾ docs",
    "    [ ] A guide.md  +5 −0",
    "▸ lua/diffly",
    "  [ ] M README.md  +1 −1",
  })
end

T["za on a dir row folds it, hiding descendants"] = function()
  set_cursor(3) -- docs
  child.type_keys("za")

  local got = lines()
  eq(got[3], "▸ docs")
  eq(#got, 9)
  for _, l in ipairs(got) do
    eq(l:find("guide.md", 1, true), nil)
  end
end

T["za on a file row folds its parent directory"] = function()
  set_cursor(4) -- docs/guide.md (only child of docs)
  child.type_keys("za")

  eq(lines()[3], "▸ docs")
end

T["R key calls session:refresh"] = function()
  child.type_keys("R")
  eq(child.lua_get("_G.calls.refresh"), 1)
end

T["s key calls session:set_mode with the flipped mode"] = function()
  child.type_keys("s")
  eq(child.lua_get("_G.calls.set_mode"), { "unified" })
  eq(child.lua_get("_G.session.mode"), "unified")
end

T["q key calls session:close and closes the panel"] = function()
  local buf = child.lua_get("_G.panel.buf")

  child.type_keys("q")

  eq(child.lua_get("_G.calls.close"), 1)
  eq(child.lua_get("vim.api.nvim_buf_is_valid(...)", { buf }), false)
end

---------------------------------------------------------------------------------------
-- keymaps.universal on the panel (docs/design.md "Interface", the two-layer model): the
-- same leader-prefixed keys that work everywhere else in diffly (owned diff buffers, real
-- file buffers -- see tests/test_sidebyside.lua/tests/test_unified.lua) must also work on
-- the panel itself, reusing the exact same handlers as the single-key `v`/`s` above.
---------------------------------------------------------------------------------------

T["keymaps.universal (<leader>v/<leader>s/<leader>e) are buffer-local nowait maps on the panel"] = function()
  for _, key in ipairs({ "<leader>v", "<leader>s", "<leader>e" }) do
    local m = buf_maparg(key)
    eq(mapped(m), true, key .. " missing on the panel buffer")
    eq(m.nowait, 1, key .. " is not nowait")
  end
end

T["<leader>v (keymaps.universal.toggle_viewed) on a file row calls session:toggle_viewed and auto-advances, same as v"] = function()
  child.lua([[_G.session._next_unviewed_answer = "lua/diffly/new.lua"]])

  set_cursor(4) -- docs/guide.md
  child.type_keys([[\v]]) -- the literal keys `<leader>v` sends with the default mapleader

  eq(child.lua_get("_G.calls.toggle_viewed"), { "docs/guide.md" })
  eq(child.lua_get("_G.calls.next_unviewed"), { "docs/guide.md" })
  eq(cursor(), { 7, 0 }) -- row for lua/diffly/new.lua
  eq(child.lua_get("_G.calls.open_file"), { "lua/diffly/new.lua" })
end

T["<leader>s (keymaps.universal.toggle_mode) calls session:set_mode with the flipped mode, same as s"] = function()
  child.type_keys([[\s]]) -- the literal keys `<leader>s` sends with the default mapleader

  eq(child.lua_get("_G.calls.set_mode"), { "unified" })
  eq(child.lua_get("_G.session.mode"), "unified")
end

T["<leader>e (keymaps.universal.focus_panel) is a harmless no-op when the panel is already focused"] = function()
  child.cmd("vsplit")
  local moved_away = child.lua_get("vim.api.nvim_get_current_win() ~= _G.panel.win")
  eq(moved_away, true)

  child.lua("vim.api.nvim_set_current_win(_G.panel.win)")
  child.type_keys([[\e]])

  eq(child.lua_get("vim.api.nvim_get_current_win() == _G.panel.win"), true)
end

T["keymaps.universal.toggle_mode = false disables only that key on the panel, leaving keymaps.panel's own s intact"] = function()
  child.lua([[
    require("diffly.config").setup({ keymaps = { universal = { toggle_mode = false } } })
    _G.panel = require("diffly.ui.panel").open(_G.session)
  ]])

  eq(mapped(buf_maparg("<leader>s")), false, "keymaps.universal.toggle_mode")
  eq(mapped(buf_maparg("s")), true, "keymaps.panel.toggle_mode is unaffected")
  eq(mapped(buf_maparg("<leader>v")), true, "other universal keys are unaffected")
end

---------------------------------------------------------------------------------------
-- ]f/[f (keymaps.universal.next_file/prev_file) in the panel: unlike the universal
-- toggle_viewed/toggle_mode keys above (which reuse the panel's OWN `v`/`s` handlers
-- verbatim), these get panel-local handlers that reference the ROW UNDER THE CURSOR
-- (not `session.current_path`), same idiom as `on_open`/`on_fold` -- see
-- `reference_path` in ui/panel.lua. file_order for this fixture (dirs first, then files,
-- alphabetical; matches EXPECTED_LINES row order above): docs/guide.md (row 4),
-- lua/diffly/gone.lua (6), lua/diffly/new.lua (7), lua/diffly/renamed.lua (8),
-- lua/diffly/state.lua (9), README.md (10).
---------------------------------------------------------------------------------------

T["]f (keymaps.universal.next_file) in the panel opens the next file relative to the cursor's row and moves the cursor there, wrapping at the end"] = function()
  set_cursor(4) -- docs/guide.md
  child.type_keys("]f")

  eq(child.lua_get("_G.calls.open_file"), { "lua/diffly/gone.lua" })
  eq(cursor(), { 6, 0 })
  eq(child.lua_get("_G.session.current_path"), "lua/diffly/gone.lua")

  set_cursor(10) -- README.md, the last file in file_order
  child.type_keys("]f")

  eq(child.lua_get("_G.calls.open_file")[2], "docs/guide.md", "wraps back to the first file")
  eq(cursor(), { 4, 0 })
end

T["[f (keymaps.universal.prev_file) in the panel opens the previous file relative to the cursor's row, wrapping at the start"] = function()
  set_cursor(6) -- lua/diffly/gone.lua
  child.type_keys("[f")

  eq(child.lua_get("_G.calls.open_file"), { "docs/guide.md" })
  eq(cursor(), { 4, 0 })

  child.type_keys("[f") -- cursor is now on docs/guide.md, the first file in file_order

  eq(child.lua_get("_G.calls.open_file")[2], "README.md", "wraps back to the last file")
  eq(cursor(), { 10, 0 })
end

T["]f in the panel falls back to session.current_path when the cursor isn't on a file row"] = function()
  child.lua([[_G.session.current_path = "lua/diffly/new.lua"]])
  set_cursor(1) -- header row: current_node() has no file node here

  child.type_keys("]f")

  eq(child.lua_get("_G.calls.open_file"), { "lua/diffly/renamed.lua" })
end

---------------------------------------------------------------------------------------
-- H (keymaps.panel.toggle_hide_viewed): a display-only filter, never touching
-- navigation (next_unviewed/next_file/prev_file) or the header's progress counts.
---------------------------------------------------------------------------------------

T["H (keymaps.panel.toggle_hide_viewed) hides already-viewed rows and adds a header suffix; pressing again restores them"] = function()
  eq(lines()[9], "    [✓] M state.lua  +42 −3", "sanity: state.lua starts viewed and visible")

  child.type_keys("H")

  local got = lines()
  eq(got[2], "1/6 viewed (hidden)", "progress counts stay global; only the wording gains a suffix")
  for _, l in ipairs(got) do
    eq(l:find("state.lua", 1, true), nil, "the viewed file's row is gone")
  end

  child.type_keys("H")

  eq(lines(), EXPECTED_LINES, "toggling back restores the exact original rows/header")
end

T["marking a file viewed while hide_viewed is on makes its row vanish too; auto-advance still works and the cursor lands on a valid row"] = function()
  child.lua([[_G.session._next_unviewed_answer = "lua/diffly/new.lua"]])
  child.type_keys("H") -- hide_viewed on: state.lua's row disappears

  set_cursor(4) -- docs/guide.md (still visible: not viewed yet)
  child.type_keys("v")

  eq(child.lua_get("_G.calls.toggle_viewed"), { "docs/guide.md" })
  -- next_unviewed is session state, not panel rows -- entirely unaffected by the filter.
  eq(child.lua_get("_G.calls.next_unviewed"), { "docs/guide.md" })
  eq(child.lua_get("_G.calls.open_file"), { "lua/diffly/new.lua" })

  local got = lines()
  for _, l in ipairs(got) do
    eq(l:find("guide.md", 1, true), nil, "the just-viewed file's row is gone too, now hidden")
  end

  local total_lines = #got
  local cur = cursor()
  eq(cur[1] >= 1 and cur[1] <= total_lines, true, "cursor stays on a valid row")
  eq(
    child.lua_get("_G.panel.row_nodes[" .. cur[1] .. "].path"),
    "lua/diffly/new.lua",
    "auto-advance's own cursor-move landed on the right (still-visible) row"
  )
end

T["keymaps.panel.toggle_hide_viewed = false disables the H mapping"] = function()
  child.lua([[
    require("diffly.config").setup({ keymaps = { panel = { toggle_hide_viewed = false } } })
    _G.panel = require("diffly.ui.panel").open(_G.session)
  ]])

  eq(mapped(buf_maparg("H")), false, "keymaps.panel.toggle_hide_viewed")
  eq(mapped(buf_maparg("v")), true, "other panel keys are unaffected")
end

---------------------------------------------------------------------------------------
-- V (keymaps.panel.toggle_viewed_subtree): tri-state bulk toggle over a directory's
-- files, single-file passthrough to `v` on a file row. "lua/diffly" (row 5) has
-- state.lua (viewed) plus gone/new/renamed (un-viewed), in `entries` iteration order --
-- see FAKE_SESSION_SETUP's comment on `toggle_viewed_batch` for why path SET ORDER below
-- matches that array's literal order, not tree/alphabetical order.
---------------------------------------------------------------------------------------

local LUA_DIFFLY_SUBTREE = {
  "lua/diffly/state.lua",
  "lua/diffly/new.lua",
  "lua/diffly/gone.lua",
  "lua/diffly/renamed.lua",
}

T["V on a dir row marks every un-viewed file under it in one batch call"] = function()
  set_cursor(5) -- lua/diffly
  child.type_keys("V")

  eq(child.lua_get("_G.calls.toggle_viewed_batch"), { LUA_DIFFLY_SUBTREE })
  eq(child.lua_get("_G.viewed['lua/diffly/new.lua']"), true)
  eq(child.lua_get("_G.viewed['lua/diffly/gone.lua']"), true)
  eq(child.lua_get("_G.viewed['lua/diffly/renamed.lua']"), true)
  eq(child.lua_get("_G.viewed['lua/diffly/state.lua']"), true, "already-viewed file stays viewed")

  local got = lines()
  eq(got[6], "    [✓] D gone.lua  +0 −7")
  eq(got[7], "    [✓] A new.lua  +10 −0")
  eq(got[8], "    [✓] R lua/diffly/old_name.lua → lua/diffly/renamed.lua  +2 −1")
end

T["V again unmarks the whole subtree once every file in it is viewed"] = function()
  set_cursor(5)
  child.type_keys("V") -- marks new/gone/renamed (state.lua already viewed)
  child.type_keys("V") -- all four now viewed -> unmark all four

  eq(#child.lua_get("_G.calls.toggle_viewed_batch"), 2)
  eq(child.lua_get("_G.viewed['lua/diffly/state.lua']"), false)
  eq(child.lua_get("_G.viewed['lua/diffly/new.lua']"), false)
  eq(child.lua_get("_G.viewed['lua/diffly/gone.lua']"), false)
  eq(child.lua_get("_G.viewed['lua/diffly/renamed.lua']"), false)
end

T["V on a file row behaves exactly like v (single toggle, never a batch call)"] = function()
  set_cursor(9) -- lua/diffly/state.lua
  child.type_keys("V")

  eq(child.lua_get("_G.calls.toggle_viewed"), { "lua/diffly/state.lua" })
  eq(child.lua_get("_G.calls.toggle_viewed_batch"), {})
end

T["V with hide_viewed on still batches the full subtree, including the currently-hidden viewed file"] = function()
  child.type_keys("H") -- hide_viewed on: state.lua's row disappears; "lua/diffly" stays at row 5

  set_cursor(5) -- lua/diffly (dir row itself is unaffected by the filter)
  child.type_keys("V")

  eq(
    child.lua_get("_G.calls.toggle_viewed_batch"),
    { LUA_DIFFLY_SUBTREE },
    "the batch is computed from session.entries directly, filter-independent"
  )
end

T["V on a dir row auto-advances to the next un-viewed file after a marking batch"] = function()
  child.lua([[_G.session._next_unviewed_answer = "docs/guide.md"]])

  set_cursor(5) -- lua/diffly
  child.type_keys("V")

  eq(child.lua_get("_G.calls.next_unviewed_count"), 1)
  eq(child.lua_get("_G.calls.open_file"), { "docs/guide.md" })
  eq(cursor(), { 4, 0 }) -- row for docs/guide.md
end

T["V again (an unmark batch) does not auto-advance"] = function()
  child.lua([[_G.session._next_unviewed_answer = "docs/guide.md"]])

  set_cursor(5)
  child.type_keys("V") -- marks: auto-advances (moves the cursor off row 5)
  set_cursor(5) -- back on lua/diffly's row, now every file under it is viewed
  child.type_keys("V") -- unmark batch: must not advance again

  eq(
    child.lua_get("_G.calls.next_unviewed_count"),
    1,
    "only the marking batch triggered next_unviewed"
  )
end

T["keymaps.panel.toggle_viewed_subtree = false disables the V mapping"] = function()
  child.lua([[
    require("diffly.config").setup({ keymaps = { panel = { toggle_viewed_subtree = false } } })
    _G.panel = require("diffly.ui.panel").open(_G.session)
  ]])

  eq(mapped(buf_maparg("V")), false, "keymaps.panel.toggle_viewed_subtree")
  eq(mapped(buf_maparg("v")), true, "other panel keys are unaffected")
end

---------------------------------------------------------------------------------------
-- S (keymaps.panel.sweep): reaches whatever was injected as `M.open`'s `opts.sweep`
-- (`init.lua`'s `run_sweep_selector` in the real plugin -- see ui/panel.lua's `on_sweep`
-- doc for why that flow is injected rather than implemented in this module). The actual
-- 0/1/N-pattern-group selector behavior (menu items, `vim.ui.select`, notifications,
-- auto-advance) is exercised end-to-end against the real session/init.lua in
-- tests/test_e2e.lua; this file only needs to prove the keymap wiring itself.
---------------------------------------------------------------------------------------

T["S calls the injected sweep action exactly once per press"] = function()
  eq(child.lua_get("_G.calls.sweep"), 0)

  child.type_keys("S")
  eq(child.lua_get("_G.calls.sweep"), 1)

  child.type_keys("S")
  eq(child.lua_get("_G.calls.sweep"), 2)
end

T["S is a harmless no-op when M.open() was never given a sweep action"] = function()
  child.lua([[_G.panel = require("diffly.ui.panel").open(_G.session)]])

  eq(pcall(child.type_keys, "S"), true)
  eq(child.lua_get("_G.calls.sweep"), 0)
end

T["keymaps.panel.sweep = false disables the S mapping"] = function()
  child.lua([[
    require("diffly.config").setup({ keymaps = { panel = { sweep = false } } })
    _G.panel = require("diffly.ui.panel").open(_G.session, { sweep = _G.__sweep_action })
  ]])

  eq(mapped(buf_maparg("S")), false, "keymaps.panel.sweep")
  eq(mapped(buf_maparg("v")), true, "other panel keys are unaffected")
end

T["buffer is not modifiable outside render"] = function()
  eq(child.lua_get("vim.bo[_G.panel.buf].modifiable"), false)
end

T["panel window width matches config.panel.width"] = function()
  eq(child.lua_get("vim.api.nvim_win_get_width(_G.panel.win)"), 40)
end

T["panel window has cursorline on and no number/signcolumn"] = function()
  eq(child.lua_get("vim.wo[_G.panel.win].cursorline"), true)
  eq(child.lua_get("vim.wo[_G.panel.win].number"), false)
  eq(child.lua_get("vim.wo[_G.panel.win].signcolumn"), "no")
end

T["focus() moves the current window back to the panel"] = function()
  child.cmd("vsplit")
  local moved_away = child.lua_get("vim.api.nvim_get_current_win() ~= _G.panel.win")
  eq(moved_away, true)

  child.lua("_G.panel:focus()")
  eq(child.lua_get("vim.api.nvim_get_current_win() == _G.panel.win"), true)
end

---------------------------------------------------------------------------------------
-- DifflyCurrentFile: the row for `session.current_path` (the file the diff view currently
-- shows) gets a whole-row background highlight, so the panel always shows where the
-- review currently is. Set directly on the fake session and `render()`ed explicitly
-- (rather than routed through `session:open_file`, whose subscriber-notify semantics
-- belong to tests/test_session.lua, and the `]f`-follows-the-highlight regression to
-- tests/test_e2e.lua) -- these cases are purely about `Panel:render()`'s own logic given a
-- `current_path`.
---------------------------------------------------------------------------------------

T["render() adds no DifflyCurrentFile extmark when current_path is nil"] = function()
  eq(
    child.lua_get("_G.session.current_path == nil"),
    true,
    "sanity: the fixture starts with no current file"
  )
  eq(current_file_rows(), {})
end

T["render() highlights only the row matching session.current_path"] = function()
  child.lua([[_G.session.current_path = "lua/diffly/new.lua"; _G.panel:render()]])
  eq(current_file_rows(), { 7 }) -- row for lua/diffly/new.lua, per this file's fixed fixture layout
end

T["a viewed AND current file's row carries both DifflyViewed and DifflyCurrentFile"] = function()
  child.lua([[_G.session.current_path = "lua/diffly/state.lua"; _G.panel:render()]])
  eq(current_file_rows(), { 9 }, "state.lua's row -- pre-viewed per FAKE_SESSION_SETUP")

  local groups = hl_groups_on_row(9)
  eq(vim.tbl_contains(groups, "DifflyViewed"), true, "the viewed row-wide style is still applied")
  eq(
    vim.tbl_contains(groups, "DifflyCurrentFile"),
    true,
    "the current-file background is layered under it"
  )
end

T["dir rows never get DifflyCurrentFile, even if current_path happens to equal a dir's path"] = function()
  child.lua([[_G.session.current_path = "lua/diffly"; _G.panel:render()]]) -- "lua/diffly" is a DIR node's path, not any file's entry.path
  eq(current_file_rows(), {})
end

T["hide_viewed filtering the current file away leaves no DifflyCurrentFile extmark and does not error"] = function()
  child.lua([[_G.session.current_path = "lua/diffly/state.lua"]]) -- pre-viewed; H below hides its row
  eq(pcall(child.type_keys, "H"), true)

  eq(current_file_rows(), {})
  local got = lines()
  for _, l in ipairs(got) do
    eq(l:find("state.lua", 1, true), nil, "sanity: the current file's row really is hidden")
  end
end

T["hl.setup() links the documented groups with default = true"] = function()
  local hl = require("diffly.ui.hl")
  hl.setup()

  local expected = {
    DifflyPanelHeader = "Title",
    DifflyPanelDir = "Directory",
    DifflyStatusAdded = "Added",
    DifflyStatusModified = "Changed",
    DifflyStatusDeleted = "Removed",
    DifflyStatusRenamed = "Special",
    DifflyViewed = "Comment",
    DifflyCurrentFile = "QuickFixLine",
    DifflyCounts = "Comment",
    DifflyCheckbox = "Special",
  }
  for name, link in pairs(expected) do
    local def = vim.api.nvim_get_hl(0, { name = name })
    eq(def.link, link)
  end
end

return T
