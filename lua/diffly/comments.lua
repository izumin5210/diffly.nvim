-- Comment-thread model (docs/design.md "Comments"). Pure logic over the
-- diffly.ReviewState table: CRUD, snapshot-search re-anchoring, and difit-compatible
-- prompt formatting. Deliberately free of UI, git subprocesses, and vim.api -- callers
-- (session.lua) supply blob shas and content lines, so everything here is testable
-- in-process with plain tables.

local M = {}

---@return string @ISO8601 UTC, same format state.lua stamps marked_at with
local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
end

---@param st diffly.ReviewState
---@param path string
---@param id string
---@return diffly.CommentThread|nil, integer|nil index
local function find_thread(st, path, id)
  for i, thread in ipairs(st.comments[path] or {}) do
    if thread.id == id then
      return thread, i
    end
  end
  return nil, nil
end

---@class diffly.comments.AddOpts
---@field path string
---@field side "base"|"head"
---@field start_line integer
---@field end_line integer
---@field body string
---@field sha string        -- blob sha of the commented side's current content
---@field snapshot string[] -- exact text of start_line..end_line at comment time
---@field author string?    -- absent = the human reviewer (see diffly.CommentMessage)

---@param st diffly.ReviewState
---@param opts diffly.comments.AddOpts
---@return diffly.CommentThread
function M.add(st, opts)
  st.comment_seq = st.comment_seq + 1

  ---@type diffly.CommentThread
  local thread = {
    id = "c" .. st.comment_seq,
    path = opts.path,
    anchor = {
      side = opts.side,
      start_line = opts.start_line,
      end_line = opts.end_line,
      sha = opts.sha,
      snapshot = opts.snapshot,
    },
    messages = { { body = opts.body, created_at = now(), author = opts.author } },
  }

  st.comments[opts.path] = st.comments[opts.path] or {}
  table.insert(st.comments[opts.path], thread)
  return thread
end

--- Rewrite a thread's (single, v1) message body.
---@param st diffly.ReviewState
---@param path string
---@param id string
---@param body string
---@return diffly.CommentThread|nil @nil when no such thread exists
function M.update(st, path, id, body)
  local thread = find_thread(st, path, id)
  if not thread then
    return nil
  end
  thread.messages[1].body = body
  thread.messages[1].updated_at = now()
  return thread
end

--- Append a reply to a thread. `messages[]` has been thread-shaped since v1 exactly for
--- this; the compose UI still only edits the root, so replies are append-only records
--- (the agent bridge's "addressed this" loop is the first writer).
---@param st diffly.ReviewState
---@param path string
---@param id string
---@param body string
---@param opts { author: string? }?
---@return diffly.CommentMessage|nil @nil when no such thread exists
function M.reply(st, path, id, body, opts)
  local thread = find_thread(st, path, id)
  if not thread then
    return nil
  end
  ---@type diffly.CommentMessage
  local message = { body = body, created_at = now(), author = opts and opts.author }
  table.insert(thread.messages, message)
  return message
end

--- Remove a thread; the path key itself is dropped with the last thread so persisted
--- JSON never accumulates empty lists (and never hits vim.json's `{}`-vs-`[]` ambiguity).
---@param st diffly.ReviewState
---@param path string
---@param id string
---@return boolean deleted
function M.delete(st, path, id)
  local _, index = find_thread(st, path, id)
  if not index then
    return false
  end
  table.remove(st.comments[path], index)
  if #st.comments[path] == 0 then
    st.comments[path] = nil
  end
  return true
end

--- A path's threads in creation order. Returns a fresh list so callers can't
--- accidentally mutate persisted state through the result.
---@param st diffly.ReviewState
---@param path string
---@return diffly.CommentThread[]
function M.list(st, path)
  local result = {}
  for _, thread in ipairs(st.comments[path] or {}) do
    table.insert(result, thread)
  end
  return result
end

--- Every thread across the review, ordered by (path, start_line, id). The id tiebreak
--- compares the numeric part -- plain string order would put "c10" before "c2".
---@param st diffly.ReviewState
---@return diffly.CommentThread[]
function M.list_all(st)
  local result = {}
  for _, threads in pairs(st.comments) do
    for _, thread in ipairs(threads) do
      table.insert(result, thread)
    end
  end
  table.sort(result, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    if a.anchor.start_line ~= b.anchor.start_line then
      return a.anchor.start_line < b.anchor.start_line
    end
    return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2))
  end)
  return result
end

--- Threads on `path`/`side` whose [start_line, end_line] covers `line`. Outdated threads
--- ARE included, at their last-known position: rendering skips them, but cursor actions
--- (edit/delete after a `:Diffly comments` quickfix jump) must still be able to reach
--- them somewhere.
---@param st diffly.ReviewState
---@param path string
---@param side "base"|"head"
---@param line integer
---@return diffly.CommentThread[]
function M.find_at(st, path, side, line)
  local result = {}
  for _, thread in ipairs(st.comments[path] or {}) do
    local anchor = thread.anchor
    if anchor.side == side and anchor.start_line <= line and line <= anchor.end_line then
      table.insert(result, thread)
    end
  end
  return result
end

---@class diffly.comments.Resolution
---@field changed boolean      -- whether apply_resolution() will mutate persisted fields
---@field start_line integer?  -- set when the anchor moved
---@field sha string?          -- set when the anchor's sha must advance
---@field outdated boolean     -- final outdated value

--- Re-anchor decision for one thread, given the side's CURRENT blob sha and content.
--- Pure: mutates nothing (see `apply_resolution`).
---
--- A matching sha always short-circuits -- including when the thread is outdated: the
--- failed pass that set the flag advanced `anchor.sha` to the content it searched, so
--- "sha matches" means "content is identical to when the snapshot went missing" and the
--- flag must stand. Rehabilitation happens on the search path (content changed again and
--- the snapshot is findable once more).
---
--- The search wants the EXACT snapshot block (all lines, adjacent, in order); the
--- nearest match to the old position wins, and an exact-distance tie goes to the smaller
--- line number (deterministic; no fuzzy matching -- a silently mis-anchored comment is
--- worse than an outdated one, see docs/design.md).
---@param thread diffly.CommentThread
---@param current_sha string
---@param current_lines string[]
---@return diffly.comments.Resolution
function M.resolve(thread, current_sha, current_lines)
  local anchor = thread.anchor

  if anchor.sha == current_sha then
    return { changed = false, outdated = anchor.outdated == true }
  end

  local snapshot = anchor.snapshot
  local k = #snapshot
  local best_line, best_dist
  if k > 0 then
    for cand = 1, #current_lines - k + 1 do
      local matches = true
      for i = 1, k do
        if current_lines[cand + i - 1] ~= snapshot[i] then
          matches = false
          break
        end
      end
      -- Strictly-smaller comparison keeps the first (lowest-line) candidate on a
      -- distance tie, since candidates are visited in ascending line order.
      if matches then
        local dist = math.abs(cand - anchor.start_line)
        if not best_dist or dist < best_dist then
          best_line, best_dist = cand, dist
        end
      end
    end
  end

  if best_line then
    return { changed = true, start_line = best_line, sha = current_sha, outdated = false }
  end

  -- Not found: mark outdated, and advance the sha anyway so the next refresh against
  -- unchanged content short-circuits on the sha check instead of re-scanning the file.
  return { changed = true, sha = current_sha, outdated = true }
end

--- Apply a `resolve()` decision to the thread's anchor. `end_line` is recomputed from
--- the snapshot length; the snapshot itself is never rewritten (an exact match means
--- identical text anyway). `outdated` is stored as true-or-absent, never false.
---@param thread diffly.CommentThread
---@param resolution diffly.comments.Resolution
---@return boolean changed
function M.apply_resolution(thread, resolution)
  if not resolution.changed then
    return false
  end
  local anchor = thread.anchor
  if resolution.sha then
    anchor.sha = resolution.sha
  end
  if resolution.start_line then
    anchor.start_line = resolution.start_line
    anchor.end_line = resolution.start_line + #anchor.snapshot - 1
  end
  anchor.outdated = resolution.outdated or nil
  return true
end

---@param row integer
---@param line_count integer
---@return integer
local function clamp_row(row, line_count)
  return math.max(0, math.min(row, line_count - 1))
end

--- Where base-side line `base_line` renders in the unified buffer. Mirrors
--- `ui/unified.lua`'s `compute_overlay` walk, tracking BOTH sides: `cur_old` starts at
--- `hunk.old_start`, `cur_new` at `hunk.new_start`; " " consumes one line of each side
--- (a context base line maps to its own new-side row, below it), "-" consumes only the
--- old side (a deleted base line anchors exactly where its deletion run's virt_lines
--- render, sharing compute_overlay's clamp rules), "+" consumes only the new side. A
--- base line outside every hunk maps to itself shifted by the cumulative (new - old)
--- length delta of the hunks fully above it.
---
--- Lives HERE (not ui/comments.lua, whose placement pipeline is its main consumer)
--- because it is pure hunk math with no vim.api in sight: `session.lua`'s comment
--- navigation (`next_comment`/`prev_comment`) orders both sides' threads through this
--- same walk, and session.lua deliberately never depends on `lua/diffly/ui/*`.
---@param hunks diffly.Hunk[]
---@param line_count integer  -- line count of the unified buffer (the new side)
---@param base_line integer   -- 1-based base-side line
---@return { row: integer, above: boolean }
function M.base_target(hunks, line_count, base_line)
  local delta = 0

  for _, hunk in ipairs(hunks) do
    local cur_old = hunk.old_start
    local cur_new = hunk.new_start

    if base_line < cur_old then
      break -- unchanged territory before this hunk; the accumulated delta applies
    end

    for _, body_line in ipairs(hunk.lines) do
      local marker = body_line:sub(1, 1)
      if marker == " " then
        if cur_old == base_line then
          return { row = clamp_row(cur_new - 1, line_count), above = false }
        end
        cur_old = cur_old + 1
        cur_new = cur_new + 1
      elseif marker == "-" then
        if cur_old == base_line then
          -- The deletion-run anchor, with compute_overlay's exact clamp rules: row 0
          -- above=true when the new side is empty; below the last real line when the
          -- deletion runs past EOF.
          local raw_row = cur_new - 1
          if raw_row < 0 then
            return { row = 0, above = true }
          elseif raw_row > line_count - 1 then
            return { row = math.max(line_count - 1, 0), above = false }
          end
          return { row = raw_row, above = true }
        end
        cur_old = cur_old + 1
      elseif marker == "+" then
        cur_new = cur_new + 1
      end
      -- marker == "\\": "\ No newline at end of file" -- neither side has a line here.
    end

    -- The whole hunk lies above base_line: fold its length difference into the offset.
    delta = delta + (cur_new - hunk.new_start) - (cur_old - hunk.old_start)
  end

  return { row = clamp_row(base_line + delta - 1, line_count), above = false }
end

--- Per-hunk valid submit positions, walking each hunk's body with both side counters
--- exactly like `M.base_target` above: context lines (" ") are valid on BOTH
--- sides, "-" lines only as base positions, "+" lines only as head positions. Grouped
--- PER HUNK (not one flat set) because that grouping IS the "a multi-line range must sit
--- inside one hunk" rule the forge enforces -- and within a hunk each side's valid lines
--- are contiguous, so checking a range's two ends suffices.
---@param hunks diffly.Hunk[]
---@return { base: table<integer, true>, head: table<integer, true> }[]
function M.hunk_line_sets(hunks)
  local sets = {}
  for _, hunk in ipairs(hunks) do
    local base, head = {}, {}
    local cur_old = hunk.old_start
    local cur_new = hunk.new_start
    for _, body_line in ipairs(hunk.lines) do
      local marker = body_line:sub(1, 1)
      if marker == " " then
        base[cur_old] = true
        head[cur_new] = true
        cur_old = cur_old + 1
        cur_new = cur_new + 1
      elseif marker == "-" then
        base[cur_old] = true
        cur_old = cur_old + 1
      elseif marker == "+" then
        head[cur_new] = true
        cur_new = cur_new + 1
      end
      -- "\ No newline at end of file": neither side has a line here.
    end
    table.insert(sets, { base = base, head = head })
  end
  return sets
end

--- Map every local draft onto the PR's real diff, or explain why it can't go: the pure
--- decision half of `:Diffly submit` (`Session:prepare_submission` assembles `ctx_by_path`
--- and owns the git calls). MUTATES NOTHING -- a worktree-anchored draft whose sha
--- doesn't match the PR head re-anchors via `M.resolve` against the head blob, but only
--- the derived payload uses the moved position; the draft itself stays untouched (it
--- still points at what the user is looking at).
---@param threads diffly.CommentThread[]
---@param ctx_by_path table<string, diffly.SubmitCtx>
---@return diffly.SubmissionPlan
function M.plan_submission(threads, ctx_by_path)
  ---@type diffly.SubmissionPlan
  local plan = { items = {}, skipped = {} }

  ---@param thread diffly.CommentThread
  ---@param reason string
  local function skip(thread, reason)
    table.insert(plan.skipped, { thread = thread, reason = reason })
  end

  for _, thread in ipairs(threads) do
    local anchor = thread.anchor
    local ctx = ctx_by_path[thread.path]

    if anchor.outdated then
      skip(thread, "outdated (its code is gone)")
    elseif not ctx or not ctx.in_pr then
      skip(thread, "the file is not in the PR diff")
    else
      -- Where the range sits in FORGE coordinates. Base anchors are immutable (the
      -- merge-base blob never changes), so they submit as-is; head anchors may have been
      -- written against edited worktree content and re-anchor onto the head blob first.
      local start_line, end_line = anchor.start_line, anchor.end_line
      local ok = true
      if anchor.side == "head" and anchor.sha ~= ctx.head_sha then
        local resolution = M.resolve(thread, ctx.head_sha or "", ctx.head_lines or {})
        if resolution.outdated then
          skip(thread, "its content was not found in the PR head")
          ok = false
        elseif resolution.start_line then
          start_line = resolution.start_line
          end_line = resolution.start_line + #anchor.snapshot - 1
        end
      end

      if ok then
        -- The range's END decides which hunk the comment belongs to; the START must sit
        -- in the SAME hunk (forge rule). Within a hunk a side's valid lines are
        -- contiguous, so the two ends are all that needs checking.
        local hunk_set
        for _, set in ipairs(ctx.line_sets) do
          if set[anchor.side][end_line] then
            hunk_set = set
            break
          end
        end
        if not hunk_set then
          skip(thread, "its line is not part of the PR diff")
        elseif not hunk_set[anchor.side][start_line] then
          skip(thread, "its range spans more than one hunk of the PR diff")
        else
          ---@type diffly.ReviewCommentPayload
          local payload = {
            path = thread.path,
            side = anchor.side,
            line = end_line,
            start_line = start_line ~= end_line and start_line or nil,
            body = thread.messages[1].body,
          }
          table.insert(plan.items, { thread = thread, payload = payload })
        end
      end
    end
  end

  return plan
end

--- One-way draft adoption (docs/design.md "Comments": drafts written under the
--- branch-pair key follow the review into its PR key): move every thread of `src` into
--- `dst` under FRESH ids from `dst.comment_seq` -- the two stores allocated ids
--- independently, so keeping the originals could collide -- anchors/messages/timestamps
--- verbatim, and empty `src.comments` out. Pure table surgery; the caller persists both
--- states (and leaves `src`'s viewed marks alone -- they deliberately never migrate).
---@param src diffly.ReviewState
---@param dst diffly.ReviewState
---@return integer adopted
function M.adopt(src, dst)
  local adopted = 0
  for path, threads in pairs(src.comments) do
    for _, thread in ipairs(threads) do
      dst.comment_seq = dst.comment_seq + 1
      thread.id = "c" .. dst.comment_seq
      dst.comments[path] = dst.comments[path] or {}
      table.insert(dst.comments[path], thread)
      adopted = adopted + 1
    end
  end
  src.comments = {}
  return adopted
end

--- difit-compatible prompt block: `path:L42` (or `path:L42-L48` for a range) on the
--- first line, then the body verbatim -- the format difit's "Copy Prompt" feature
--- established for feeding review comments to AI coding agents.
---@param thread diffly.CommentThread
---@return string
function M.format_prompt(thread)
  local anchor = thread.anchor
  local location = string.format("%s:L%d", thread.path, anchor.start_line)
  if anchor.end_line ~= anchor.start_line then
    location = location .. string.format("-L%d", anchor.end_line)
  end
  return location .. "\n" .. thread.messages[1].body
end

--- All prompt blocks joined with difit's `=====` separator.
---@param threads diffly.CommentThread[]
---@return string
function M.format_prompt_all(threads)
  local blocks = {}
  for _, thread in ipairs(threads) do
    table.insert(blocks, M.format_prompt(thread))
  end
  return table.concat(blocks, "\n\n=====\n\n")
end

return M
