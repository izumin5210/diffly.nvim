-- Comment rendering + placement math (docs/design.md "Comments"). Namespaces are OWNED BY
-- THE VIEWS (one anonymous comment ns per view instance, mirroring the unified overlay's
-- "one ns per concern" rule) -- this module never creates one, it only paints into the ns
-- a view hands it. Placement is pure data so the mapping math is testable against real
-- git hunks without any window machinery (tests/test_ui_comments.lua).

local M = {}

-- Explicit priority for expanded comment virt_lines. The unified overlay's deletion runs
-- use the extmark default (4096); same-row ordering between the two is pinned by the e2e
-- goldens -- comments render below the deletion text they annotate.
M.PRIORITY = 4200

---@class diffly.ui.CommentPlacement
---@field row integer     -- 0-based buffer row to anchor at
---@field above boolean   -- virt_lines_above
---@field thread diffly.CommentThread

--- Outdated threads are never placed: their position is a memory, not a location, and a
--- comment pinned to the wrong line is worse than an absent one. They stay reachable
--- through the panel count and `:Diffly comments` (docs/design.md "Comments").
---@param thread diffly.CommentThread
---@param side "base"|"head"
---@return boolean
local function placeable(thread, side)
  return thread.anchor.side == side and not thread.anchor.outdated
end

---@param row integer
---@param line_count integer
---@return integer
local function clamp_row(row, line_count)
  return math.max(0, math.min(row, line_count - 1))
end

--- Placements for a buffer whose lines ARE the side's content 1:1 (side-by-side's two
--- buffers; the unified buffer for head-side threads; the deleted-file blob for base-side
--- ones). Anchors below the range's LAST line -- "directly below the commented code".
---@param threads diffly.CommentThread[]
---@param side "base"|"head"
---@param line_count integer
---@return diffly.ui.CommentPlacement[]
function M.direct_placements(threads, side, line_count)
  local placements = {}
  for _, thread in ipairs(threads) do
    if placeable(thread, side) then
      table.insert(placements, {
        row = clamp_row(thread.anchor.end_line - 1, line_count),
        above = false,
        thread = thread,
      })
    end
  end
  return placements
end

--- Where base-side line `base_line` renders in the unified buffer. Mirrors
--- `ui/unified.lua`'s `compute_overlay` walk, tracking BOTH sides: `cur_old` starts at
--- `hunk.old_start`, `cur_new` at `hunk.new_start`; " " consumes one line of each side
--- (a context base line maps to its own new-side row, below it), "-" consumes only the
--- old side (a deleted base line anchors exactly where its deletion run's virt_lines
--- render, sharing compute_overlay's clamp rules), "+" consumes only the new side. A
--- base line outside every hunk maps to itself shifted by the cumulative (new - old)
--- length delta of the hunks fully above it.
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

--- `direct_placements`' counterpart for base-side threads shown in the unified buffer:
--- each surviving thread goes through `base_target` (anchored at its range's last line).
---@param threads diffly.CommentThread[]
---@param hunks diffly.Hunk[]
---@param line_count integer
---@return diffly.ui.CommentPlacement[]
function M.mapped_base_placements(threads, hunks, line_count)
  local placements = {}
  for _, thread in ipairs(threads) do
    if placeable(thread, "base") then
      local target = M.base_target(hunks, line_count, thread.anchor.end_line)
      table.insert(placements, { row = target.row, above = target.above, thread = thread })
    end
  end
  return placements
end

--- Full clear-and-redraw of `ns` on `buf` -- never incremental, mirroring the overlay's
--- own discipline so a stale mark can never linger. Expanded threads render their (v1:
--- single) message body as one virt_lines block per thread; collapsed mode shrinks every
--- thread to an eol indicator so line geometry stops jumping while still marking where
--- comments live.
---@param buf integer
---@param ns integer
---@param placements diffly.ui.CommentPlacement[]
---@param opts { collapsed: boolean }
function M.render(buf, ns, placements, opts)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for _, placement in ipairs(placements) do
    if opts.collapsed then
      vim.api.nvim_buf_set_extmark(buf, ns, placement.row, 0, {
        virt_text = { { " ✎ comment", "DifflyCommentMarker" } },
        virt_text_pos = "eol",
      })
    else
      local chunks = {}
      local body = placement.thread.messages[1].body
      for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
        table.insert(chunks, {
          { "┃ ", "DifflyCommentMarker" },
          { line, "DifflyCommentBody" },
        })
      end
      vim.api.nvim_buf_set_extmark(buf, ns, placement.row, 0, {
        virt_lines = chunks,
        virt_lines_above = placement.above,
        priority = M.PRIORITY,
      })
    end
  end
end

return M
