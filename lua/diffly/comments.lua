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
    messages = { { body = opts.body, created_at = now() } },
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
