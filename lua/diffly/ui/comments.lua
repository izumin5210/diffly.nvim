-- Comment rendering + placement math + the compose float (docs/design.md "Comments").
-- Namespaces are OWNED BY THE VIEWS (one anonymous comment ns per view instance,
-- mirroring the unified overlay's "one ns per concern" rule) -- this module never creates
-- one, it only paints into the ns a view hands it. Placement is pure data so the mapping
-- math is testable against real git hunks without any window machinery
-- (tests/test_ui_comments.lua).

local scratch = require("diffly.ui.scratch")

local M = {}

-- Same-(row, above) virt_lines from different extmarks stack by CREATION ORDER, with the
-- later-created mark rendering closer to the top (empirically -- extmark `priority` has
-- no effect on virt_lines ordering, only on highlights). ui/unified.lua exploits this to
-- keep a base-side comment BELOW the deleted lines it annotates: comments render first,
-- the overlay second, in both `open()` and `refresh_comments()`. Pinned by the unified
-- comments golden.

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
--- own discipline so a stale mark can never linger. Expanded threads render EVERY
--- message (remote threads carry replies; local drafts still have exactly one, keeping
--- their output byte-identical to the pre-remote shape -- golden safety, pinned by
--- test): a message with an `author` opens with an attribution line, the first of which
--- also carries the thread's `[resolved]` tag. Collapsed mode shrinks every thread to an
--- eol indicator so line geometry stops jumping while still marking where comments live.
---@param buf integer
---@param ns integer
---@param placements diffly.ui.CommentPlacement[]
---@param opts { collapsed: boolean }
function M.render(buf, ns, placements, opts)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for _, placement in ipairs(placements) do
    local thread = placement.thread
    local marker_hl = thread.remote and "DifflyCommentRemoteMarker" or "DifflyCommentMarker"

    if opts.collapsed then
      local indicator = thread.remote and (" ✎ @" .. thread.messages[1].author) or " ✎ comment"
      vim.api.nvim_buf_set_extmark(buf, ns, placement.row, 0, {
        virt_text = { { indicator, marker_hl } },
        virt_text_pos = "eol",
      })
    else
      local chunks = {}
      for index, message in ipairs(thread.messages) do
        if message.author then
          local author_line =
            { { "┃ ", marker_hl }, { "@" .. message.author, "DifflyCommentAuthor" } }
          if index == 1 and thread.resolved then
            table.insert(author_line, { " [resolved]", "DifflyCommentResolved" })
          end
          table.insert(chunks, author_line)
        end
        for _, line in ipairs(vim.split(message.body, "\n", { plain = true })) do
          table.insert(chunks, {
            { "┃ ", marker_hl },
            { line, "DifflyCommentBody" },
          })
        end
      end
      vim.api.nvim_buf_set_extmark(buf, ns, placement.row, 0, {
        virt_lines = chunks,
        virt_lines_above = placement.above,
      })
    end
  end
end

---@class diffly.ui.ComposeOpts
---@field title string          -- "path:L42" / "path:L42-L48", shown in the border
---@field initial string[]?     -- prefill for the edit flow; empty/nil starts in insert mode
---@field on_submit fun(lines: string[])
---@field on_cancel fun()?

--- The comment compose/edit float: a small markdown scratch anchored at the cursor.
--- Deliberately NOT a diffly.View -- it is action-owned (opened from a keypress, where
--- "the current window" is exactly the right reference point via `relative = "cursor"`),
--- so the views' "never read the current window" contract doesn't apply here (documented
--- in docs/architecture.md).
---
--- Lifecycle: every exit funnels through one `finish()` closure via a one-shot WinClosed
--- autocmd -- the submit/cancel keys below, but also `:q`, `:close`, and the whole
--- tabpage disappearing during session teardown -- so exactly one of on_submit/on_cancel
--- ever fires, no float bookkeeping needed anywhere else. A whitespace-only body submits
--- as a cancel: an empty comment is not a thing.
---@param opts diffly.ui.ComposeOpts
---@return integer win, integer buf
function M.compose(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local initial = opts.initial or {}
  if #initial > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
  end
  -- Markdown highlighting WITHOUT 'filetype' (the LSP-didOpen invariant, see
  -- ui/scratch.lua): treesitter when a parser exists, legacy 'syntax' otherwise.
  scratch.highlight(buf, { lang = "markdown" })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(60, math.max(20, vim.o.columns - 4)),
    height = 6,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "left",
  })

  local finished = false
  ---@param submitted boolean
  local function finish(submitted)
    if finished then
      return
    end
    finished = true

    local lines = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      or {}
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Insert mode SURVIVES the float closing (submitting with <C-s> from insert would
    -- otherwise dump the user into insert mode in the underlying buffer, where the next
    -- keys they type become text edits instead of commands).
    vim.cmd("stopinsert")

    if submitted and vim.trim(table.concat(lines, "\n")) ~= "" then
      opts.on_submit(lines)
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      finish(false)
    end,
  })

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    finish(true)
  end, { buffer = buf, nowait = true, silent = true, desc = "diffly: submit comment" })
  vim.keymap.set("n", "q", function()
    finish(false)
  end, { buffer = buf, nowait = true, silent = true, desc = "diffly: cancel comment" })

  if #initial == 0 then
    vim.cmd.startinsert()
  end

  return win, buf
end

return M
