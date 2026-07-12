-- Tests for lua/diffly/comments.lua: the pure comment-thread model (CRUD over a
-- diffly.ReviewState table, snapshot-search re-anchoring, difit-compatible prompt
-- formatting). No git repo and no UI: shas are opaque strings, content is plain string
-- lists, and the state table is built by hand exactly like test_state.lua does.

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

T["format_prompt_all(): joins with ===== separators"] = function()
  local st = fresh_state()
  local a = comments.add(st, add_opts({ start_line = 1, end_line = 1, body = "first" }))
  local b = comments.add(st, add_opts({ start_line = 2, end_line = 2, body = "second" }))

  eq(comments.format_prompt_all({ a, b }), "src/a.lua:L1\nfirst\n\n=====\n\nsrc/a.lua:L2\nsecond")
  eq(comments.format_prompt_all({}), "")
end

return T
