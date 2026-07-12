-- Tests for lua/diffly/ui/comments.lua: placement math (direct + base-line-to-unified-row
-- mapping) and extmark rendering. Placement mapping is pinned against REAL `git diff`
-- hunks (helpers.new_repo), mirroring tests/test_unified.lua's empirical approach to the
-- overlay anchors; rendering uses plain in-process scratch buffers. The compose float has
-- its own cases further down.

local helpers = dofile("tests/helpers.lua")
local ui_comments = require("diffly.ui.comments")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

--- A minimal thread shaped like diffly.CommentThread; only what placement/rendering read.
---@param overrides table?
---@return diffly.CommentThread
local function thread(overrides)
  local t = {
    id = "c1",
    path = "src/a.lua",
    anchor = { side = "head", start_line = 2, end_line = 2, sha = "sha", snapshot = { "x" } },
    messages = { { body = "note", created_at = "2026-07-12T00:00:00Z" } },
  }
  for k, v in pairs(overrides or {}) do
    if k == "anchor" then
      t.anchor = vim.tbl_extend("force", t.anchor, v)
    else
      t[k] = v
    end
  end
  return t
end

-- direct_placements() --------------------------------------------------------

T["direct_placements(): anchors below end_line, filtered by side, skipping outdated"] = function()
  local threads = {
    thread({ id = "c1", anchor = { side = "head", start_line = 2, end_line = 4 } }),
    thread({ id = "c2", anchor = { side = "base", start_line = 3, end_line = 3 } }),
    thread({ id = "c3", anchor = { side = "head", start_line = 5, end_line = 5, outdated = true } }),
  }

  local placements = ui_comments.direct_placements(threads, "head", 10)
  eq(#placements, 1)
  eq(placements[1].thread.id, "c1")
  eq(placements[1].row, 3) -- 0-based row of end_line 4
  eq(placements[1].above, false)

  local base = ui_comments.direct_placements(threads, "base", 10)
  eq(#base, 1)
  eq(base[1].thread.id, "c2")
  eq(base[1].row, 2)
end

T["direct_placements(): clamps a row past EOF to the last line"] = function()
  local threads = { thread({ anchor = { side = "head", start_line = 9, end_line = 9 } }) }
  local placements = ui_comments.direct_placements(threads, "head", 4)
  eq(placements[1].row, 3)
end

-- base_target() / mapped_base_placements() -- pinned against real git hunks ---

--- One repo, three files, each exercising a mapping shape. Returns hunks per file plus
--- the worktree line counts a unified buffer would have.
local function mapping_fixture()
  local repo = helpers.new_repo()

  local map_lines = {}
  for i = 1, 30 do
    map_lines[i] = "line " .. i
  end
  repo:write("map.txt", map_lines)
  -- Newline-terminated strings, NOT lists: Repo:write's binary-mode writefile leaves the
  -- last list item without a trailing newline, which would turn "delete the tail lines"
  -- into "also rewrite the new last line's newline" and change the hunk shape entirely.
  repo:write("eof.txt", "e1\ne2\ne3\ne4\ne5\n")
  repo:write("empty.txt", { "z1", "z2" })
  repo:commit("chore: base")

  local git = require("diffly.git")
  local id = git.repo_identity(repo.dir)
  local base_sha = vim.trim(repo:git({ "rev-parse", "HEAD" }))

  -- map.txt: replace line 5 (one hunk), delete line 20 (another).
  local changed = vim.deepcopy(map_lines)
  changed[5] = "line 5 CHANGED"
  table.remove(changed, 20)
  repo:write("map.txt", changed)
  -- eof.txt: delete the last two lines (a deletion run ending at EOF).
  repo:write("eof.txt", "e1\ne2\ne3\n")
  -- empty.txt: empty the whole file.
  repo:write("empty.txt", "")

  local hunks = {}
  for _, path in ipairs({ "map.txt", "eof.txt", "empty.txt" }) do
    local entry
    for _, e in ipairs(git.diff_files(id, base_sha, "worktree", {})) do
      if e.path == path then
        entry = e
      end
    end
    hunks[path] = git.hunks(id, entry, base_sha, "worktree")
  end

  return repo, hunks
end

T["base_target(): maps context/changed/out-of-hunk base lines onto unified rows"] = function()
  local repo, hunks = mapping_fixture()
  local h = hunks["map.txt"]
  local line_count = 29 -- 30 base lines, one deleted

  -- Before every hunk: identity mapping.
  eq(ui_comments.base_target(h, line_count, 1), { row = 0, above = false })
  -- Context line inside the first hunk: still identity here (the hunk only replaces).
  eq(ui_comments.base_target(h, line_count, 4), { row = 3, above = false })
  -- The replaced line itself: anchored where its deletion run renders (above the
  -- replacement text at new line 5).
  eq(ui_comments.base_target(h, line_count, 5), { row = 4, above = true })
  -- Between the two hunks: the first hunk's replace keeps the offset at zero.
  eq(ui_comments.base_target(h, line_count, 12), { row = 11, above = false })
  -- The deleted line 20: anchored where the deletion run renders.
  eq(ui_comments.base_target(h, line_count, 20), { row = 19, above = true })
  -- After every hunk: shifted up by the one deleted line.
  eq(ui_comments.base_target(h, line_count, 25), { row = 23, above = false })

  repo:destroy()
end

T["base_target(): a deletion running to EOF clamps below the last line"] = function()
  local repo, hunks = mapping_fixture()

  -- eof.txt's worktree has 3 lines; base lines 4 and 5 were deleted past its end.
  eq(ui_comments.base_target(hunks["eof.txt"], 3, 4), { row = 2, above = false })
  eq(ui_comments.base_target(hunks["eof.txt"], 3, 5), { row = 2, above = false })

  repo:destroy()
end

T["base_target(): a whole-file deletion anchors at the very top"] = function()
  local repo, hunks = mapping_fixture()

  -- empty.txt's worktree buffer is a single empty line; git reports new_start == 0.
  eq(ui_comments.base_target(hunks["empty.txt"], 1, 1), { row = 0, above = true })
  eq(ui_comments.base_target(hunks["empty.txt"], 1, 2), { row = 0, above = true })

  repo:destroy()
end

T["mapped_base_placements(): filters to base side and applies base_target"] = function()
  local repo, hunks = mapping_fixture()
  local threads = {
    thread({ id = "c1", anchor = { side = "base", start_line = 5, end_line = 5 } }),
    thread({ id = "c2", anchor = { side = "head", start_line = 1, end_line = 1 } }),
    thread({ id = "c3", anchor = { side = "base", start_line = 1, end_line = 1, outdated = true } }),
  }

  local placements = ui_comments.mapped_base_placements(threads, hunks["map.txt"], 29)
  eq(#placements, 1)
  eq(placements[1].thread.id, "c1")
  eq(placements[1].row, 4)
  eq(placements[1].above, true)

  repo:destroy()
end

-- render() --------------------------------------------------------------------

---@param buf integer
---@param ns integer
---@return table[]
local function marks(buf, ns)
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

---@param lines integer @how many filler lines the buffer should have
---@return integer buf, integer ns
local function scratch_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  local content = {}
  for i = 1, lines do
    content[i] = "content " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  return buf, vim.api.nvim_create_namespace("")
end

T["render(): expanded comments are boxed virt_lines below their anchor"] = function()
  local buf, ns = scratch_buf(6)
  local t = thread({ messages = { { body = "first\nsecond", created_at = "x" } } })

  ui_comments.render(buf, ns, {
    { row = 1, above = false, thread = t },
  }, { collapsed = false })

  local got = marks(buf, ns)
  eq(#got, 1)
  eq(got[1][2], 1) -- anchored at row 1
  local details = got[1][4]
  eq(details.virt_lines_above, false)
  -- header + one line per body line + footer: the box is what keeps two adjacent
  -- threads on the same anchor visually separate.
  eq(#details.virt_lines, 4)
  eq(details.virt_lines[1][1][1], "╭─ ")
  eq(details.virt_lines[1][2][1], "✎ draft")
  eq(details.virt_lines[2][2][1], "first")
  eq(details.virt_lines[3][2][1], "second")
  eq(details.virt_lines[4][1][1], "╰─")
  eq(details.virt_lines[2][1][2], "DifflyCommentMarker")
  eq(details.virt_lines[2][2][2], "DifflyCommentBody")

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["render(): collapsed mode paints an eol indicator instead of virt_lines"] = function()
  local buf, ns = scratch_buf(6)

  ui_comments.render(buf, ns, {
    { row = 2, above = false, thread = thread() },
  }, { collapsed = true })

  local got = marks(buf, ns)
  eq(#got, 1)
  local details = got[1][4]
  eq(details.virt_lines, nil)
  eq(details.virt_text[1][2], "DifflyCommentMarker")
  eq(details.virt_text_pos, "eol")

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- compose() -------------------------------------------------------------------

--- Find a compose-buffer mapping by its `desc` (lhs notation for keys like <C-s> is
--- normalization-dependent; desc is the stable handle) and return its callback.
---@param buf integer
---@param mode string
---@param desc string
---@return fun()
local function mapping_by_desc(buf, mode, desc)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if map.desc == desc then
      return map.callback
    end
  end
  error(string.format("no %s-mode mapping with desc %q", mode, desc))
end

--- compose() with recording callbacks; returns win/buf plus the records.
---@param opts table?
local function composed(opts)
  local record = { submitted = nil, submit_count = 0, cancel_count = 0 }
  local win, buf = ui_comments.compose(vim.tbl_extend("force", {
    title = "src/a.lua:L3",
    on_submit = function(lines)
      record.submit_count = record.submit_count + 1
      record.submitted = lines
    end,
    on_cancel = function()
      record.cancel_count = record.cancel_count + 1
    end,
  }, opts or {}))
  return win, buf, record
end

T["compose(): a markdown float scratch that never sets 'filetype'"] = function()
  local win, buf, _ = composed()

  eq(vim.api.nvim_win_is_valid(win), true)
  -- `relative = "cursor"` is normalized to a win-relative position once created; any
  -- non-empty `relative` means "a floating window".
  eq(vim.api.nvim_win_get_config(win).relative ~= "", true)
  -- 'acwrite', not 'nofile': :w/:wq must route through BufWriteCmd (see the cases below).
  eq(vim.bo[buf].buftype, "acwrite")
  -- The hard invariant: markdown highlighting WITHOUT a FileType event (LSP didOpen on a
  -- non-file buffer can crash servers) -- treesitter when available, 'syntax' otherwise.
  eq(vim.bo[buf].filetype, "")
  eq(vim.treesitter.highlighter.active[buf] ~= nil or vim.bo[buf].syntax == "markdown", true)

  vim.api.nvim_win_close(win, true)
  vim.cmd("stopinsert")
end

T["compose(): submit hands over the body lines exactly once and closes the float"] = function()
  local win, buf, record = composed()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first line", "second line" })

  mapping_by_desc(buf, "n", "diffly: submit comment")()

  eq(record.submit_count, 1)
  eq(record.submitted, { "first line", "second line" })
  eq(record.cancel_count, 0, "WinClosed firing after submit must not also cancel")
  eq(vim.api.nvim_win_is_valid(win), false)
  vim.cmd("stopinsert")
end

T["compose(): q cancels exactly once"] = function()
  local win, buf, record = composed()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "draft" })

  mapping_by_desc(buf, "n", "diffly: cancel comment")()

  eq(record.submit_count, 0)
  eq(record.cancel_count, 1)
  eq(vim.api.nvim_win_is_valid(win), false)
  vim.cmd("stopinsert")
end

T["compose(): an empty body submits as a cancel"] = function()
  local win, buf, record = composed()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "   " })

  mapping_by_desc(buf, "n", "diffly: submit comment")()

  eq(record.submit_count, 0)
  eq(record.cancel_count, 1)
  eq(vim.api.nvim_win_is_valid(win), false)
  vim.cmd("stopinsert")
end

T["compose(): closing the window externally funnels into cancel (teardown-safe)"] = function()
  local win, _, record = composed()

  vim.api.nvim_win_close(win, true)

  eq(record.submit_count, 0)
  eq(record.cancel_count, 1)
  vim.cmd("stopinsert")
end

T["compose(): :w submits exactly once and closes the float"] = function()
  -- Ctrl keys are hostage to the terminal stack (flow control, multiplexers); vim's own
  -- save gesture must work everywhere.
  local win, buf, record = composed()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "written body" })

  vim.api.nvim_win_call(win, function()
    vim.cmd("write")
  end)
  vim.wait(200, function()
    return not vim.api.nvim_win_is_valid(win)
  end, 10)

  eq(record.submit_count, 1)
  eq(record.submitted, { "written body" })
  eq(record.cancel_count, 0)
  eq(vim.api.nvim_win_is_valid(win), false)
  vim.cmd("stopinsert")
end

T["compose(): :wq submits and quits without touching any other window"] = function()
  local wins_before = #vim.api.nvim_tabpage_list_wins(0)
  local win, buf, record = composed()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "written body" })
  vim.cmd("stopinsert")

  -- The float is the current window (compose enters it); :wq = write (submit via
  -- BufWriteCmd) then quit THIS window -- the quit must consume the float, never the
  -- window focus falls back to.
  vim.api.nvim_set_current_win(win)
  vim.cmd("wq")
  vim.wait(200, function()
    return not vim.api.nvim_win_is_valid(win)
  end, 10)

  eq(record.submit_count, 1)
  eq(record.cancel_count, 0)
  eq(vim.api.nvim_win_is_valid(win), false)
  eq(#vim.api.nvim_tabpage_list_wins(0), wins_before, "no other window was quit")
end

T["compose(): :q warns on an unsaved body (E37); :q! cancels; a pristine :q cancels silently"] = function()
  -- A typed-but-unsaved comment is real work: quitting without submitting warns exactly
  -- like an unsaved file, and :q! is the explicit discard.
  local win, buf, record = composed()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "precious draft" })
  vim.cmd("stopinsert")
  vim.api.nvim_set_current_win(win)

  local ok, err = pcall(vim.cmd, "q")
  eq(ok, false)
  eq(tostring(err):find("E37") ~= nil, true)
  eq(record.submit_count, 0)
  eq(record.cancel_count, 0)
  eq(vim.api.nvim_win_is_valid(win), true, "the float survives the refused quit")

  vim.cmd("q!")
  eq(record.cancel_count, 1)
  eq(vim.api.nvim_win_is_valid(win), false)

  -- Untouched float (prefill included): plain :q cancels without complaining.
  local win2, _, record2 = composed({ initial = { "existing body" } })
  vim.api.nvim_set_current_win(win2)
  vim.cmd("q")
  eq(record2.cancel_count, 1)
  eq(vim.api.nvim_win_is_valid(win2), false)
end

T["compose(): allow_empty submits an empty body (the review-summary flow)"] = function()
  local win, buf, record = composed({ allow_empty = true })

  mapping_by_desc(buf, "n", "diffly: submit comment")()

  eq(record.submit_count, 1)
  eq(record.submitted, { "" })
  eq(record.cancel_count, 0)
  eq(vim.api.nvim_win_is_valid(win), false)
  vim.cmd("stopinsert")
end

T["compose(): initial prefills the buffer for the edit flow"] = function()
  local win, buf, _ = composed({ initial = { "existing body" } })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "existing body" })
  vim.api.nvim_win_close(win, true)
end

--- A minimal diffly.RemoteThread for render tests.
---@param opts {resolved: boolean?, messages: table[]}
local function remote(opts)
  return {
    id = "T1",
    path = "src/a.lua",
    remote = true,
    resolved = opts.resolved == true,
    anchor = { side = "head", start_line = 2, end_line = 2 },
    messages = opts.messages,
  }
end

T["render(): remote threads box the author into the header and keep every message"] = function()
  local buf, ns = scratch_buf(6)
  local t = remote({
    messages = {
      { author = "alice", body = "first point\nsecond line" },
      { author = "bob", body = "reply" },
    },
  })

  ui_comments.render(buf, ns, { { row = 1, above = false, thread = t } }, { collapsed = false })

  local got = marks(buf, ns)
  eq(#got, 1)
  local lines = got[1][4].virt_lines
  -- header(@alice) / body / body / @bob / body / footer.
  eq(#lines, 6)
  eq(lines[1][1][1], "╭─ ")
  eq(lines[1][1][2], "DifflyCommentRemoteMarker", "remote threads use the remote marker group")
  eq(lines[1][2][1], "@alice")
  eq(lines[1][2][2], "DifflyCommentAuthor")
  eq(lines[2][2][1], "first point")
  eq(lines[3][2][1], "second line")
  eq(lines[4][2][1], "@bob")
  eq(lines[4][2][2], "DifflyCommentAuthor")
  eq(lines[5][2][1], "reply")
  eq(lines[6][1][1], "╰─")

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["render(): a resolved remote thread is tagged in its header"] = function()
  local buf, ns = scratch_buf(6)
  local t = remote({ resolved = true, messages = { { author = "alice", body = "done" } } })

  ui_comments.render(buf, ns, { { row = 1, above = false, thread = t } }, { collapsed = false })

  local lines = marks(buf, ns)[1][4].virt_lines
  eq(lines[1][2][1], "@alice")
  eq(lines[1][3][1], " [resolved]")
  eq(lines[1][3][2], "DifflyCommentResolved")

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["render(): two threads on the same anchor stay visually separate (adjacent boxes)"] = function()
  -- The regression this design exists for: a local draft and a remote thread on the SAME
  -- line used to fuse into one uniform gutter block.
  local buf, ns = scratch_buf(6)
  local local_thread = thread({ messages = { { body = "my draft", created_at = "x" } } })
  local remote_thread = remote({ messages = { { author = "alice", body = "her point" } } })

  ui_comments.render(buf, ns, {
    { row = 1, above = false, thread = local_thread },
    { row = 1, above = false, thread = remote_thread },
  }, { collapsed = false })

  local got = marks(buf, ns)
  eq(#got, 2)
  local first, second = got[1][4].virt_lines, got[2][4].virt_lines
  -- Each block is self-delimited: ...body, ╰─ | ╭─ header...
  eq(first[#first][1][1], "╰─")
  eq(second[1][1][1], "╭─ ")
  -- And the two are distinguishable at a glance: label vs author + different marker hl.
  eq(first[1][2][1], "✎ draft")
  eq(first[1][1][2], "DifflyCommentMarker")
  eq(second[1][2][1], "@alice")
  eq(second[1][1][2], "DifflyCommentRemoteMarker")

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["render(): collapsed remote threads show the author in the indicator"] = function()
  local buf, ns = scratch_buf(6)
  local t = remote({ messages = { { author = "alice", body = "x" } } })

  ui_comments.render(buf, ns, { { row = 2, above = false, thread = t } }, { collapsed = true })

  local details = marks(buf, ns)[1][4]
  eq(details.virt_lines, nil)
  eq(details.virt_text[1][1], " ✎ @alice")
  eq(details.virt_text[1][2], "DifflyCommentRemoteMarker")

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["render(): the exact local chunk shape (golden safety)"] = function()
  -- Any change here shifts every comment screenshot golden -- keep this pin in sync
  -- with deliberate redesigns only.
  local buf, ns = scratch_buf(6)
  local t = thread({ messages = { { body = "first\nsecond", created_at = "x" } } })

  ui_comments.render(buf, ns, { { row = 1, above = false, thread = t } }, { collapsed = false })

  local details = marks(buf, ns)[1][4]
  eq(details.virt_lines, {
    { { "╭─ ", "DifflyCommentMarker" }, { "✎ draft", "DifflyCommentMarker" } },
    { { "│ ", "DifflyCommentMarker" }, { "first", "DifflyCommentBody" } },
    { { "│ ", "DifflyCommentMarker" }, { "second", "DifflyCommentBody" } },
    { { "╰─", "DifflyCommentMarker" } },
  })

  ui_comments.render(buf, ns, { { row = 1, above = false, thread = t } }, { collapsed = true })
  eq(marks(buf, ns)[1][4].virt_text, { { " ✎ comment", "DifflyCommentMarker" } })

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["render(): clear-and-redraw removes stale marks"] = function()
  local buf, ns = scratch_buf(6)

  ui_comments.render(buf, ns, {
    { row = 1, above = false, thread = thread({ id = "c1" }) },
    { row = 3, above = false, thread = thread({ id = "c2" }) },
  }, { collapsed = false })
  eq(#marks(buf, ns), 2)

  ui_comments.render(buf, ns, {
    { row = 4, above = false, thread = thread({ id = "c3" }) },
  }, { collapsed = false })

  local got = marks(buf, ns)
  eq(#got, 1)
  eq(got[1][2], 4)

  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
