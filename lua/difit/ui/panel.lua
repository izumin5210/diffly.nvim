-- Left-hand file tree panel (WP-H). Renders a `difit.Session`'s entries as a folding
-- tree with per-file viewed marks, status letters, and +/- counts, and wires the
-- buffer-local panel keymaps to the session.
--
-- `session` is used ONLY through the documented interface from docs/plan.md (WP-E):
-- fields `spec`/`entries`/`state`/`mode`/`current_path`, methods `subscribe`/
-- `open_file`/`toggle_viewed`/`is_viewed`/`next_unviewed`/`progress`/`set_mode`/
-- `refresh`/`close`. `lua/difit/session.lua` is intentionally never `require`d here, so
-- this module stays testable against a scripted fake (see tests/test_panel.lua).

local config = require("difit.config")
local tree = require("difit.tree")

require("difit.ui.hl").setup()

local M = {}

---@class difit.Panel
---@field buf integer
---@field win integer
---@field session difit.Session
---@field folded table<string, boolean>          -- dir path -> folded?
---@field row_nodes table<integer, difit.TreeNode> -- 1-indexed buffer line -> node
local Panel = {}
Panel.__index = Panel

-- Dedicated namespace for every highlight this module draws, so `render()` can clear
-- exactly its own extmarks each time without disturbing anything else in the buffer.
local ns = vim.api.nvim_create_namespace("difit_panel")

local GLYPH = {
  dir_open = "▾",
  dir_closed = "▸",
  checked = "✓",
}
-- U+2212 MINUS SIGN and U+2026 HORIZONTAL ELLIPSIS, matching the rendering sketch in
-- docs/plan.md verbatim (not ASCII "-"/"...").
local MINUS = "−"
local ELLIPSIS = "…"
local ARROW = "→"

local STATUS_HL = {
  A = "DifitStatusAdded",
  M = "DifitStatusModified",
  D = "DifitStatusDeleted",
  R = "DifitStatusRenamed",
}

--- Review keys/UI only ever show the short branch name ("main"), never a resolved
--- remote-tracking ref ("origin/main"); mirrors `session.lua`'s private `short_name`.
---@param ref string
---@return string
local function short_name(ref)
  return ref:match("^origin/(.+)$") or ref
end

--- Icons are entirely optional: feature-detect via `pcall` so the panel silently
--- degrades to no-icon rows when neither provider is installed, or `config.icons` is
--- off (tests always run with it off, for deterministic rows).
---@param filename string
---@return string|nil
local function resolve_icon(filename)
  local ok_mini, mini_icons = pcall(require, "mini.icons")
  if ok_mini then
    local icon = mini_icons.get("file", filename)
    return icon
  end

  local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
  if ok_devicons then
    local ext = filename:match("%.([^.]+)$")
    return devicons.get_icon(filename, ext, { default = true })
  end

  return nil
end

--- `difit  <base>…<head>` for a branch-pair review; `review_key` carries no `head` for
--- a PR review (see difit.ReviewKey), so that case reads `difit  <base ref> (PR #N)`
--- instead -- the closest faithful rendering given the documented interface.
---@param session difit.Session
---@return string
local function header_text(session)
  local key = session.spec.review_key
  if key.kind == "pr" then
    return string.format("difit  %s (PR #%d)", short_name(session.spec.base_ref), key.pr_number)
  end
  return string.format("difit  %s%s%s", key.base, ELLIPSIS, key.head)
end

---@class difit.panel.Highlight
---@field col_start integer -- byte offset, start col of the extmark
---@field col_end integer   -- byte offset, end col of the extmark
---@field hl_group string

---@class difit.panel.Row
---@field text string
---@field highlights difit.panel.Highlight[]

---@param row difit.TreeRow
---@param folded table<string, boolean>
---@return difit.panel.Row
local function render_dir_row(row, folded)
  local marker = folded[row.node.path] and GLYPH.dir_closed or GLYPH.dir_open
  local indent = string.rep(" ", row.depth * 2)
  local text = indent .. marker .. " " .. row.node.name
  return {
    text = text,
    highlights = { { col_start = #indent, col_end = #text, hl_group = "DifitPanelDir" } },
  }
end

--- File rows: `<indent>[ ]|[✓] <status letter> <name>  +a −d`. Renamed files show
--- `old → new` (full relative paths) in place of `name`. Spacing is a single
--- space-separated layout (one space after the checkbox, one after the status letter,
--- two before the counts) -- there is no column-alignment requirement to satisfy.
--- Viewed files highlight the *whole row* `DifitViewed` instead of the per-segment
--- groups (design.md: viewed files are "greyed out" as a unit).
---@param row difit.TreeRow
---@param session difit.Session
---@param icons_enabled boolean
---@return difit.panel.Row
local function render_file_row(row, session, icons_enabled)
  local node = row.node
  local entry = node.entry
  local viewed = session:is_viewed(entry.path)

  local indent = string.rep(" ", (row.depth + 1) * 2)
  local checkbox = viewed and ("[" .. GLYPH.checked .. "]") or "[ ]"

  local display_name = node.name
  if entry.status == "R" and entry.old_path then
    display_name = entry.old_path .. " " .. ARROW .. " " .. entry.path
  end
  if icons_enabled then
    local icon = resolve_icon(node.name)
    if icon then
      display_name = icon .. " " .. display_name
    end
  end

  local counts = string.format("+%d %s%d", entry.additions, MINUS, entry.deletions)

  local checkbox_start = #indent
  local checkbox_end = checkbox_start + #checkbox
  local status_start = checkbox_end + 1 -- +1: skip the space after the checkbox
  local status_end = status_start + #entry.status
  local name_start = status_end + 1 -- +1: skip the space after the status letter

  local text = indent .. checkbox .. " " .. entry.status .. " " .. display_name .. "  " .. counts

  if viewed then
    return {
      text = text,
      highlights = { { col_start = 0, col_end = #text, hl_group = "DifitViewed" } },
    }
  end

  return {
    text = text,
    highlights = {
      { col_start = checkbox_start, col_end = checkbox_end, hl_group = "DifitCheckbox" },
      { col_start = status_start, col_end = status_end, hl_group = STATUS_HL[entry.status] },
      { col_start = #text - #counts, col_end = #text, hl_group = "DifitCounts" },
    },
  }
end

--- After `render()` rebuilds `row_nodes`, move the cursor back onto whichever node it
--- was logically on before the rebuild (see the snapshot taken at the top of
--- `Panel:render()`). A background refresh (BufWritePost/FocusGained/a *different* row's
--- toggle_viewed all notify every subscriber, including this panel) must not leave the
--- cursor sitting on a different file's row just because sorting shifted line numbers
--- around -- otherwise the next `v`/`<CR>` would silently act on the wrong file. Falls
--- back to clamping onto the nearest still-valid row when the exact node is gone (e.g.
--- the file left the diff, or fold-compression restructured the tree), rather than
--- leaving the cursor on a stale/out-of-range line.
---@param panel difit.Panel
---@param path string?
---@param total_lines integer
local function restore_cursor(panel, path, total_lines)
  if not path or not vim.api.nvim_win_is_valid(panel.win) then
    return
  end

  local target_lnum
  for lnum, node in pairs(panel.row_nodes) do
    if node.path == path then
      target_lnum = lnum
      break
    end
  end

  if not target_lnum then
    local current = vim.api.nvim_win_get_cursor(panel.win)[1]
    target_lnum = math.max(1, math.min(current, total_lines))
  end

  pcall(vim.api.nvim_win_set_cursor, panel.win, { target_lnum, 0 })
end

--- Re-reads `session.entries`/`session:progress()`/`session:is_viewed()` and redraws
--- the whole buffer. Rebuilds the row -> node map every time so keymaps always resolve
--- against what's actually on screen (folds shift row numbers).
function Panel:render()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  -- Snapshot which node the cursor is logically on, against the OLD row_nodes, before
  -- rebuilding anything below -- this is what lets the cursor follow that same node to
  -- its new row further down, even though row numbers are about to be recomputed from
  -- scratch.
  local cursor_path
  if vim.api.nvim_win_is_valid(self.win) then
    local node = self.row_nodes[vim.api.nvim_win_get_cursor(self.win)[1]]
    if node then
      cursor_path = node.path
    end
  end

  local session = self.session
  local icons_enabled = config.get().icons

  local lines = { header_text(session) }
  local progress = session:progress()
  lines[2] = string.format("%d/%d viewed", progress.viewed, progress.total)

  local extmarks = {
    { line = 0, col_start = 0, col_end = #lines[1], hl_group = "DifitPanelHeader" },
  }

  local root = tree.build(session.entries)
  local rows = tree.flatten(root, self.folded)
  local row_nodes = {}

  for _, row in ipairs(rows) do
    local lnum = #lines + 1
    local rendered = row.node.type == "dir" and render_dir_row(row, self.folded)
      or render_file_row(row, session, icons_enabled)

    lines[lnum] = rendered.text
    row_nodes[lnum] = row.node
    for _, hl in ipairs(rendered.highlights) do
      extmarks[#extmarks + 1] =
        { line = lnum - 1, col_start = hl.col_start, col_end = hl.col_end, hl_group = hl.hl_group }
    end
  end

  self.row_nodes = row_nodes

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  for _, hl in ipairs(extmarks) do
    vim.api.nvim_buf_set_extmark(self.buf, ns, hl.line, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.hl_group,
    })
  end
  vim.bo[self.buf].modifiable = false

  restore_cursor(self, cursor_path, #lines)
end

function Panel:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
end

function Panel:focus()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_set_current_win(self.win)
  end
end

---@return difit.TreeNode|nil
local function current_node(panel)
  local lnum = vim.api.nvim_win_get_cursor(panel.win)[1]
  return panel.row_nodes[lnum]
end

---@param panel difit.Panel
---@param path string
---@return integer|nil
local function row_for_path(panel, path)
  for lnum, node in pairs(panel.row_nodes) do
    if node.type == "file" and node.path == path then
      return lnum
    end
  end
  return nil
end

---@param node difit.TreeNode
---@return string|nil
local function parent_dir_path(node)
  local parent = node.path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then
    return parent
  end
  return nil
end

---@param panel difit.Panel
---@param dir_path string
local function toggle_fold(panel, dir_path)
  panel.folded[dir_path] = not panel.folded[dir_path]
  panel:render()
end

--- open: file row -> `session:open_file`; dir row -> toggle its own fold.
---@param panel difit.Panel
local function on_open(panel)
  local node = current_node(panel)
  if not node then
    return
  end
  if node.type == "dir" then
    toggle_fold(panel, node.path)
  else
    panel.session:open_file(node.path)
  end
end

--- fold ("za"): dir row -> toggle it, same as `open`. File row -> toggle its *parent*
--- directory, mirroring native `za` (closing the fold enclosing the cursor); a
--- root-level file has no enclosing directory row, so it is a no-op there.
---@param panel difit.Panel
local function on_fold(panel)
  local node = current_node(panel)
  if not node then
    return
  end
  if node.type == "dir" then
    toggle_fold(panel, node.path)
    return
  end
  local parent = parent_dir_path(node)
  if parent then
    toggle_fold(panel, parent)
  end
end

---@param panel difit.Panel
local function on_toggle_viewed(panel)
  local node = current_node(panel)
  if not node or node.type ~= "file" then
    return
  end

  -- No explicit `panel:render()` here: `session:toggle_viewed` already notifies
  -- subscribers synchronously, and this panel subscribed its own re-render callback in
  -- `M.open` -- by the time `toggle_viewed` returns, `row_nodes` already reflects the
  -- new state, which is exactly what `row_for_path` below needs.
  local became_viewed = panel.session:toggle_viewed(node.path)

  -- Auto-advance only on MARKING a file viewed, never on un-marking it (design.md:
  -- "Marking advances to the next un-viewed file") -- otherwise un-marking a mistake
  -- would also yank the cursor/diff away from the file the user is looking at.
  if became_viewed and config.get().auto_advance then
    local nxt = panel.session:next_unviewed(node.path)
    if nxt then
      local lnum = row_for_path(panel, nxt)
      if lnum and vim.api.nvim_win_is_valid(panel.win) then
        vim.api.nvim_win_set_cursor(panel.win, { lnum, 0 })
      end
      panel.session:open_file(nxt)
    end
  end
end

---@param panel difit.Panel
local function on_refresh(panel)
  panel.session:refresh()
end

---@param panel difit.Panel
local function on_toggle_mode(panel)
  local next_mode = panel.session.mode == "sidebyside" and "unified" or "sidebyside"
  panel.session:set_mode(next_mode)
end

---@param panel difit.Panel
local function on_close(panel)
  panel.session:close()
  panel:close()
end

---@param panel difit.Panel
local function set_keymaps(panel)
  local actions = {
    open = on_open,
    fold = on_fold,
    toggle_viewed = on_toggle_viewed,
    refresh = on_refresh,
    toggle_mode = on_toggle_mode,
    close = on_close,
  }

  local keymaps = config.get().keymaps.panel
  for name, fn in pairs(actions) do
    local lhs = keymaps[name]
    if lhs then -- `false` (or unset) disables the mapping
      vim.keymap.set("n", lhs, function()
        fn(panel)
      end, { buffer = panel.buf, nowait = true, silent = true, desc = "difit: " .. name })
    end
  end
end

---@param session difit.Session
---@return difit.Panel
function M.open(session)
  local cfg = config.get()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "difit://panel")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "difit-panel"

  -- `win = -1` makes this a top-level split (like `:topleft vsplit`): full tabpage
  -- height, independent of whatever window layout already exists.
  local win = vim.api.nvim_open_win(buf, true, {
    split = "left",
    win = -1,
    width = cfg.panel.width,
  })
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  -- Defense in depth (Neovim 0.12+): `ui/unified.lua`'s jump-to-file target-window
  -- resolution already checks bufname prefixes to avoid landing a real file in this
  -- window, but 'winfixbuf' makes Neovim itself refuse any `:edit`/`:buffer` that would
  -- replace this window's buffer -- so a future code path that forgets that check still
  -- can't silently destroy the tree.
  vim.wo[win].winfixbuf = true

  local panel = setmetatable({
    buf = buf,
    win = win,
    session = session,
    folded = {},
    row_nodes = {},
  }, Panel)

  set_keymaps(panel)

  session:subscribe(function()
    if vim.api.nvim_buf_is_valid(panel.buf) then
      panel:render()
    end
  end)

  panel:render()
  return panel
end

return M
