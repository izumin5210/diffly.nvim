-- Tests for lua/diffly/comments.lua: the pure comment-thread model (CRUD over a
-- diffly.ReviewState table, snapshot-search re-anchoring, difit-compatible prompt
-- formatting, submission planning, draft adoption). Mostly no git repo and no UI (shas
-- are opaque strings, content is plain string lists, state tables built by hand exactly
-- like test_state.lua) -- the submission-planning cases are the exception, pinning the
-- hunk math against REAL `git diff` output via helpers.new_repo.

local helpers = dofile("tests/helpers.lua")
local comments = require("diffly.comments")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

---@return diffly.ReviewState
local function fresh_state()
  return {
    version = 1,
    key = { kind = "branch", repo = "github.com/owner/repo", base = "main", head = "feature" },
    viewed = {},
    comments = {},
    comment_seq = 0,
  }
end

--- Shorthand for the add() opts table; only what a test cares about needs overriding.
local function add_opts(overrides)
  return vim.tbl_extend("force", {
    path = "src/a.lua",
    side = "head",
    start_line = 3,
    end_line = 3,
    body = "needs a guard clause",
    sha = "sha-head-1",
    snapshot = { "local x = 1" },
  }, overrides or {})
end

-- CRUD ---------------------------------------------------------------------

T["add() assigns sequential ids and stores threads under their path"] = function()
  local st = fresh_state()
  local a = comments.add(st, add_opts())
  local b = comments.add(st, add_opts({ path = "src/b.lua" }))

  eq(a.id, "c1")
  eq(b.id, "c2")
  eq(st.comment_seq, 2)
  eq(#st.comments["src/a.lua"], 1)
  eq(#st.comments["src/b.lua"], 1)
end

T["add() records the anchor verbatim and stamps created_at"] = function()
  local st = fresh_state()
  local thread = comments.add(
    st,
    add_opts({ side = "base", start_line = 4, end_line = 6, snapshot = { "a", "b", "c" } })
  )

  eq(thread.path, "src/a.lua")
  eq(thread.anchor.side, "base")
  eq(thread.anchor.start_line, 4)
  eq(thread.anchor.end_line, 6)
  eq(thread.anchor.sha, "sha-head-1")
  eq(thread.anchor.snapshot, { "a", "b", "c" })
  eq(thread.anchor.outdated, nil)
  eq(#thread.messages, 1)
  eq(thread.messages[1].body, "needs a guard clause")
  eq(thread.messages[1].created_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil, true)
  eq(thread.messages[1].updated_at, nil)
end

T["update() rewrites the body and stamps updated_at"] = function()
  local st = fresh_state()
  local thread = comments.add(st, add_opts())

  local updated = comments.update(st, "src/a.lua", thread.id, "actually it is fine")

  eq(updated ~= nil, true)
  eq(st.comments["src/a.lua"][1].messages[1].body, "actually it is fine")
  eq(type(st.comments["src/a.lua"][1].messages[1].updated_at), "string")
end

T["update() returns nil for an unknown id or path"] = function()
  local st = fresh_state()
  comments.add(st, add_opts())
  eq(comments.update(st, "src/a.lua", "c99", "x"), nil)
  eq(comments.update(st, "src/other.lua", "c1", "x"), nil)
end

T["delete() removes a thread and drops the path key with the last one"] = function()
  local st = fresh_state()
  local a = comments.add(st, add_opts())
  local b = comments.add(st, add_opts({ start_line = 9, end_line = 9 }))

  eq(comments.delete(st, "src/a.lua", a.id), true)
  eq(#st.comments["src/a.lua"], 1)

  eq(comments.delete(st, "src/a.lua", b.id), true)
  eq(st.comments["src/a.lua"], nil)
end

T["delete() returns false for an unknown id"] = function()
  local st = fresh_state()
  comments.add(st, add_opts())
  eq(comments.delete(st, "src/a.lua", "c99"), false)
  eq(comments.delete(st, "src/other.lua", "c1"), false)
  eq(#st.comments["src/a.lua"], 1)
end

T["ids never get reused after a delete (comment_seq only grows)"] = function()
  local st = fresh_state()
  local a = comments.add(st, add_opts())
  comments.delete(st, "src/a.lua", a.id)
  local b = comments.add(st, add_opts())
  eq(b.id, "c2")
end

T["list() returns a path's threads in creation order"] = function()
  local st = fresh_state()
  comments.add(st, add_opts({ start_line = 9, end_line = 9 }))
  comments.add(st, add_opts({ start_line = 2, end_line = 2 }))

  local listed = comments.list(st, "src/a.lua")
  eq(#listed, 2)
  eq(listed[1].id, "c1")
  eq(listed[2].id, "c2")
  eq(comments.list(st, "src/never.lua"), {})
end

T["list_all() sorts by path, then start_line, then numeric id"] = function()
  local st = fresh_state()
  -- Creation order is deliberately shuffled relative to the expected output, and ids go
  -- past 9 so a naive string compare ("c10" < "c2") would misorder them.
  comments.add(st, add_opts({ path = "src/z.lua", start_line = 1, end_line = 1 }))
  comments.add(st, add_opts({ path = "src/a.lua", start_line = 8, end_line = 8 }))
  for _ = 1, 8 do
    comments.add(st, add_opts({ path = "src/m.lua", start_line = 5, end_line = 5 }))
  end
  comments.add(st, add_opts({ path = "src/a.lua", start_line = 2, end_line = 2 }))

  local all = comments.list_all(st)
  eq(#all, 11)
  eq(all[1].path, "src/a.lua")
  eq(all[1].anchor.start_line, 2)
  eq(all[2].anchor.start_line, 8)
  -- The eight src/m.lua threads share a line; ids must come out numerically ordered.
  local m_ids = {}
  for i = 3, 10 do
    table.insert(m_ids, all[i].id)
  end
  eq(m_ids, { "c3", "c4", "c5", "c6", "c7", "c8", "c9", "c10" })
  eq(all[11].path, "src/z.lua")
end

T["find_at() matches threads whose range covers the line, filtered by side"] = function()
  local st = fresh_state()
  comments.add(st, add_opts({ start_line = 4, end_line = 6 }))
  comments.add(st, add_opts({ side = "base", start_line = 5, end_line = 5 }))

  eq(#comments.find_at(st, "src/a.lua", "head", 5), 1)
  eq(comments.find_at(st, "src/a.lua", "head", 5)[1].id, "c1")
  eq(#comments.find_at(st, "src/a.lua", "base", 5), 1)
  eq(#comments.find_at(st, "src/a.lua", "head", 7), 0)
  eq(#comments.find_at(st, "src/other.lua", "head", 5), 0)
end

T["find_at() includes outdated threads at their last-known position"] = function()
  -- Rendering excludes outdated threads, but cursor actions (edit/delete after a
  -- quickfix jump) must still reach them where they were last seen.
  local st = fresh_state()
  local thread = comments.add(st, add_opts({ start_line = 4, end_line = 4 }))
  thread.anchor.outdated = true

  eq(#comments.find_at(st, "src/a.lua", "head", 4), 1)
end

-- resolve() / apply_resolution() --------------------------------------------

T["resolve(): matching sha short-circuits with no change"] = function()
  local st = fresh_state()
  local thread = comments.add(st, add_opts())

  local res = comments.resolve(thread, "sha-head-1", { "anything", "at all" })
  eq(res.changed, false)
  eq(res.outdated, false)
end

T["resolve(): reverted content rehabilitates an outdated thread via the search"] = function()
  -- outdated advances the sha alongside the flag, so "sha matches" always means "content
  -- is identical to when the snapshot went missing" -- the flag must stand in that case.
  -- Rehabilitation happens on the search path: the content changed AGAIN (different sha)
  -- and the snapshot is findable once more.
  local st = fresh_state()
  local thread = comments.add(st, add_opts())
  thread.anchor.outdated = true
  thread.anchor.sha = "sha-head-2" -- advanced by the failed pass that set outdated

  local res = comments.resolve(thread, "sha-head-3", { "pad", "local x = 1" })
  eq(res.changed, true)
  eq(res.outdated, false)
  eq(res.start_line, 2)

  comments.apply_resolution(thread, res)
  eq(thread.anchor.outdated, nil)
  eq(thread.anchor.start_line, 2)
  eq(thread.anchor.sha, "sha-head-3")
end

T["resolve(): a moved block is found and the anchor follows it"] = function()
  local st = fresh_state()
  local thread =
    comments.add(st, add_opts({ start_line = 2, end_line = 3, snapshot = { "bb", "cc" } }))

  -- Two lines were inserted above; the block now starts at line 4.
  local res = comments.resolve(thread, "sha-head-2", { "new", "new", "aa", "bb", "cc" })
  eq(res.changed, true)
  eq(res.outdated, false)
  eq(res.start_line, 4)
  eq(res.sha, "sha-head-2")

  comments.apply_resolution(thread, res)
  eq(thread.anchor.start_line, 4)
  eq(thread.anchor.end_line, 5)
  eq(thread.anchor.sha, "sha-head-2")
  -- The snapshot is the original text and stays put (an exact match means identical text).
  eq(thread.anchor.snapshot, { "bb", "cc" })
end

T["resolve(): the nearest of several matches wins"] = function()
  local st = fresh_state()
  local thread = comments.add(st, add_opts({ start_line = 6, end_line = 6, snapshot = { "dup" } }))

  local res = comments.resolve(
    thread,
    "sha-head-2",
    { "dup", "x", "x", "x", "dup", "x", "x", "x", "x", "dup" }
  )
  eq(res.start_line, 5) -- |5-6| = 1 beats |1-6| = 5 and |10-6| = 4
end

T["resolve(): equidistant matches prefer the smaller line number"] = function()
  local st = fresh_state()
  local thread = comments.add(st, add_opts({ start_line = 3, end_line = 3, snapshot = { "dup" } }))

  local res = comments.resolve(thread, "sha-head-2", { "x", "dup", "x", "dup", "x" })
  eq(res.start_line, 2) -- |2-3| == |4-3|; the smaller line wins deterministically
end

T["resolve(): a multi-line snapshot only matches as a whole block"] = function()
  local st = fresh_state()
  local thread =
    comments.add(st, add_opts({ start_line = 1, end_line = 2, snapshot = { "aa", "bb" } }))

  -- "aa" and "bb" both exist but never adjacently: no match.
  local res = comments.resolve(thread, "sha-head-2", { "aa", "x", "bb", "aa", "y", "bb" })
  eq(res.outdated, true)
end

T["resolve(): blocks at line 1 and at EOF are reachable"] = function()
  local st = fresh_state()
  local top = comments.add(st, add_opts({ start_line = 5, end_line = 5, snapshot = { "top" } }))
  eq(comments.resolve(top, "sha-2", { "top", "x", "x" }).start_line, 1)

  local bottom =
    comments.add(st, add_opts({ start_line = 1, end_line = 2, snapshot = { "yy", "zz" } }))
  eq(comments.resolve(bottom, "sha-2", { "x", "x", "yy", "zz" }).start_line, 3)
end

T["resolve(): no match -> outdated, and the sha still advances"] = function()
  local st = fresh_state()
  local thread = comments.add(st, add_opts())

  local res = comments.resolve(thread, "sha-head-2", { "completely", "different" })
  eq(res.changed, true)
  eq(res.outdated, true)
  eq(res.start_line, nil)

  comments.apply_resolution(thread, res)
  eq(thread.anchor.outdated, true)
  -- The sha advances so the next refresh with unchanged content short-circuits on the
  -- sha check instead of re-scanning the file.
  eq(thread.anchor.sha, "sha-head-2")
  eq(thread.anchor.start_line, 3)

  -- Same sha again: nothing to do, nothing to persist.
  local again = comments.resolve(thread, "sha-head-2", { "completely", "different" })
  eq(again.changed, false)
  eq(again.outdated, true)
end

-- Prompt formatting ----------------------------------------------------------

T["format_prompt(): single line"] = function()
  local st = fresh_state()
  local thread =
    comments.add(st, add_opts({ start_line = 42, end_line = 42, body = "rename this" }))
  eq(comments.format_prompt(thread), "src/a.lua:L42\nrename this")
end

T["format_prompt(): range"] = function()
  local st = fresh_state()
  local thread =
    comments.add(st, add_opts({ start_line = 42, end_line = 48, body = "extract a helper" }))
  eq(comments.format_prompt(thread), "src/a.lua:L42-L48\nextract a helper")
end

-- hunk_line_sets() / plan_submission() -- pinned against real git hunks -------

--- A repo whose head commit makes three well-separated edits to a 30-line file --
--- replace line 5, delete line 15, append two lines after (old) 25 -- so `git diff -U3`
--- yields three distinct hunks. Returns everything plan_submission's ctx needs.
local function submit_fixture()
  local repo = helpers.new_repo()
  local lines = {}
  for i = 1, 30 do
    lines[i] = "l" .. i
  end
  repo:write("f.txt", table.concat(lines, "\n") .. "\n")
  repo:commit("chore: base")
  local git = require("diffly.git")
  local id = git.repo_identity(repo.dir)
  local base_sha = vim.trim(repo:git({ "rev-parse", "HEAD" }))

  local changed = vim.deepcopy(lines)
  changed[5] = "l5 CHANGED"
  table.remove(changed, 15) -- deletes "l15"
  -- After the removal above, old line 25 sits at index 24; append two lines after it.
  table.insert(changed, 25, "added B")
  table.insert(changed, 25, "added A")
  repo:write("f.txt", table.concat(changed, "\n") .. "\n")
  repo:commit("feat: head")

  local entry
  for _, e in ipairs(git.diff_files(id, base_sha, "head", {})) do
    if e.path == "f.txt" then
      entry = e
    end
  end
  local hunks = git.hunks(id, entry, base_sha, "head")
  local head_lines = git.file_content(id, { sha = entry.head_sha })

  return repo, entry, hunks, head_lines
end

--- plan_submission ctx for the fixture above, keyed by path.
local function fixture_ctx(entry, hunks, head_lines)
  return {
    ["f.txt"] = {
      in_pr = true,
      head_sha = entry.head_sha,
      head_lines = head_lines,
      line_sets = comments.hunk_line_sets(hunks),
    },
  }
end

--- A local draft thread aimed at the fixture; `sha` defaults to the entry's head sha
--- (the no-drift case).
local function draft(overrides)
  local st = fresh_state()
  return comments.add(
    st,
    vim.tbl_extend("force", {
      path = "f.txt",
      side = "head",
      start_line = 5,
      end_line = 5,
      body = "about this line",
      sha = "HEAD-SHA",
      snapshot = { "l5 CHANGED" },
    }, overrides or {})
  )
end

T["hunk_line_sets(): context lines valid on both sides, +/- on exactly one"] = function()
  local repo, _, hunks = submit_fixture()
  eq(#hunks, 3)

  local sets = comments.hunk_line_sets(hunks)
  eq(#sets, 3)

  -- Hunk 1 (replace old 5 with new 5): context 2..4/6..8 valid on both sides, the
  -- replaced line valid on both (old 5 as "-", new 5 as "+").
  eq(sets[1].head[4], true)
  eq(sets[1].base[4], true)
  eq(sets[1].head[5], true)
  eq(sets[1].base[5], true)
  eq(sets[1].head[1], nil, "line 1 is outside the -U3 context")

  -- Hunk 2 (delete old 15): the deleted line exists on the base side only.
  eq(sets[2].base[15], true)
  -- New-side line 15 is old 16 shifted up -- a context line, so it IS head-valid; the
  -- base side must not gain any new-side-only line. Spot-check the boundary instead:
  eq(sets[2].head[15] ~= nil, true)

  -- Hunk 3 (two added lines at new 25/26): head-only.
  eq(sets[3].head[25], true)
  eq(sets[3].head[26], true)
  eq(sets[3].base[25], true, "context around the addition stays base-valid")
  eq(sets[3].base[26], true)

  repo:destroy()
end

T["plan_submission(): a clean head-side draft maps as-is (no start_line on single lines)"] = function()
  local repo, entry, hunks, head_lines = submit_fixture()
  local thread = draft({ sha = entry.head_sha })

  local plan = comments.plan_submission({ thread }, fixture_ctx(entry, hunks, head_lines))

  eq(#plan.skipped, 0)
  eq(#plan.items, 1)
  eq(plan.items[1].payload, {
    path = "f.txt",
    side = "head",
    line = 5,
    body = "about this line",
  })

  repo:destroy()
end

T["plan_submission(): a worktree-drifted draft re-anchors onto the head blob, mutating nothing"] = function()
  local repo, entry, hunks, head_lines = submit_fixture()
  -- The draft was written against edited worktree content: wrong sha, wrong line -- but
  -- the snapshot text exists in the head blob at line 5.
  local thread = draft({ sha = "worktree-sha", start_line = 7, end_line = 7 })
  local before = vim.deepcopy(thread)

  local plan = comments.plan_submission({ thread }, fixture_ctx(entry, hunks, head_lines))

  eq(#plan.items, 1)
  eq(plan.items[1].payload.line, 5, "submitted at the head-blob position, not the drafted one")
  eq(thread, before, "planning must not mutate the drafts")

  repo:destroy()
end

T["plan_submission(): skip reasons -- outdated, missing content, out-of-diff, cross-hunk, unknown path"] = function()
  local repo, entry, hunks, head_lines = submit_fixture()
  local ctx = fixture_ctx(entry, hunks, head_lines)

  local outdated = draft({ sha = entry.head_sha })
  outdated.anchor.outdated = true
  local missing = draft({ sha = "stale", snapshot = { "never existed anywhere" } })
  local out_of_diff = draft({ sha = entry.head_sha, start_line = 1, end_line = 1 })
  local cross_hunk = draft({ sha = entry.head_sha, start_line = 5, end_line = 25 })
  local unknown = draft({ sha = entry.head_sha, path = "other.txt" })
  unknown.path = "other.txt"

  local plan =
    comments.plan_submission({ outdated, missing, out_of_diff, cross_hunk, unknown }, ctx)

  eq(#plan.items, 0)
  eq(#plan.skipped, 5)
  -- The plan preserves input order (every draft here carries the same fresh-state "c1"
  -- id, so positions -- not ids -- are the reliable handle).
  eq(plan.skipped[1].thread, outdated)
  eq(plan.skipped[1].reason:find("outdated") ~= nil, true)
  eq(plan.skipped[2].thread, missing)
  eq(plan.skipped[2].reason:find("not found in the PR head") ~= nil, true)
  eq(plan.skipped[3].thread, out_of_diff)
  eq(plan.skipped[3].reason:find("not part of the PR diff") ~= nil, true)
  eq(plan.skipped[4].thread, cross_hunk)
  eq(plan.skipped[4].reason:find("spans more than one hunk") ~= nil, true)
  eq(plan.skipped[5].thread, unknown)
  eq(plan.skipped[5].reason:find("not in the PR diff") ~= nil, true)

  repo:destroy()
end

T["plan_submission(): ranges inside one hunk carry start_line; base-side deleted lines map"] = function()
  local repo, entry, hunks, head_lines = submit_fixture()
  local ctx = fixture_ctx(entry, hunks, head_lines)

  local range = draft({
    sha = entry.head_sha,
    start_line = 4,
    end_line = 6,
    snapshot = { "l4", "l5 CHANGED", "l6" },
  })
  local base_deleted = draft({
    side = "base",
    sha = "BASE-SHA",
    start_line = 15,
    end_line = 15,
    snapshot = { "l15" },
  })

  local plan = comments.plan_submission({ range, base_deleted }, ctx)

  eq(#plan.skipped, 0)
  eq(plan.items[1].payload.start_line, 4)
  eq(plan.items[1].payload.line, 6)
  eq(plan.items[2].payload, {
    path = "f.txt",
    side = "base",
    line = 15,
    body = "about this line",
  })

  repo:destroy()
end

-- adopt() ---------------------------------------------------------------------

T["adopt(): moves drafts with FRESH ids, emptying the source"] = function()
  local src = fresh_state()
  local a = comments.add(src, add_opts({ body = "first" }))
  local b = comments.add(src, add_opts({ start_line = 9, end_line = 9, body = "second" }))
  local a_anchor = vim.deepcopy(a.anchor)

  local dst = fresh_state()
  dst.comment_seq = 5
  comments.add(dst, add_opts({ body = "already here" }))

  eq(comments.adopt(src, dst), 2)

  eq(src.comments, {}, "the source is emptied (viewed marks are not this function's business)")
  local moved = dst.comments["src/a.lua"]
  eq(#moved, 3)
  eq(moved[2].id, "c7", "fresh ids from the destination's sequence")
  eq(moved[3].id, "c8")
  eq(moved[2].anchor, a_anchor, "anchors travel verbatim")
  eq(moved[2].messages[1].body, "first")
  eq(moved[3].messages[1].body, "second")
  eq(dst.comment_seq, 8)

  -- Nothing left to adopt on a second pass.
  eq(comments.adopt(src, dst), 0)
end

T["format_prompt_all(): joins with ===== separators"] = function()
  local st = fresh_state()
  local a = comments.add(st, add_opts({ start_line = 1, end_line = 1, body = "first" }))
  local b = comments.add(st, add_opts({ start_line = 2, end_line = 2, body = "second" }))

  eq(comments.format_prompt_all({ a, b }), "src/a.lua:L1\nfirst\n\n=====\n\nsrc/a.lua:L2\nsecond")
  eq(comments.format_prompt_all({}), "")
end

return T
