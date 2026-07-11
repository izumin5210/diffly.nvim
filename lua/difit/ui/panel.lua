-- Left-hand file tree panel (WP-H). Renders a `difit.Session`'s entries as a folding
-- tree with per-file viewed marks, status letters, and +/- counts, and wires the
-- buffer-local panel keymaps to the session.
--
-- `session` is used ONLY through the documented interface from docs/plan.md (WP-E):
-- fields `spec`/`entries`/`state`/`mode`/`current_path`, methods `subscribe`/
-- `open_file`/`toggle_viewed`/`is_viewed`/`next_unviewed`/`progress`/`set_mode`/
-- `refresh`/`close`/`sweep_patterns`/`toggle_viewed_batch`. `lua/difit/session.lua` is
-- intentionally never `require`d here, so this module stays testable against a scripted
-- fake (see tests/test_panel.lua).

local config = require("difit.config")
local tree = require("difit.tree")
local scratch = require("difit.ui.scratch")

local M = {}

---@class difit.Panel
---@field buf integer
---@field win integer
---@field session difit.Session
---@field folded table<string, boolean>          -- dir path -> folded?
---@field row_nodes table<integer, difit.TreeNode> -- 1-indexed buffer line -> node
---@field hide_viewed boolean  -- display-only filter (toggle_hide_viewed); never persisted
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

--- `session.entries`, minus already-viewed files when `hide_viewed` is on -- what the
--- tree actually gets built from. Filtering the flat entry list (rather than pruning the
--- tree afterwards) is what makes now-empty directories vanish on their own: `tree.build`
--- never creates a directory node with no file underneath it, so there is nothing extra to
--- prune here.
---@param panel difit.Panel
---@return difit.FileEntry[]
local function visible_entries(panel)
  if not panel.hide_viewed then
    return panel.session.entries
  end
  return vim.tbl_filter(function(entry)
    return not panel.session:is_viewed(entry.path)
  end, panel.session.entries)
end

--- `"N/total viewed"`, plus a compact `" (hidden)"` suffix while `hide_viewed` is on.
--- Progress counts are always GLOBAL (every file in the review), never just the rows
--- currently on screen -- the filter is a display concern only, per design.md's
--- "Interaction" note that navigation/progress must stay filter-independent.
---@param session difit.Session
---@param hide_viewed boolean
---@return string
local function progress_text(session, hide_viewed)
  local progress = session:progress()
  local text = string.format("%d/%d viewed", progress.viewed, progress.total)
  if hide_viewed then
    text = text .. " (hidden)"
  end
  return text
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
  -- scratch. Also what makes the currently-selected row disappearing (e.g. it just got
  -- marked viewed while `hide_viewed` is on) degrade gracefully: `restore_cursor` below
  -- already clamps to the nearest still-valid row when `cursor_path` is gone from the
  -- rebuilt `row_nodes`.
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
  lines[2] = progress_text(session, self.hide_viewed)

  local extmarks = {
    { line = 0, col_start = 0, col_end = #lines[1], hl_group = "DifitPanelHeader" },
  }

  local root = tree.build(visible_entries(self))
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

--- Re-pin the panel window to `config.get().panel.width` if something (most likely a
--- fresh split from a view rebuilding its windows -- see ui/sidebyside.lua/ui/unified.lua,
--- both of which split rightward FROM this window) has carved space out of it since the
--- last render. `winfixwidth` (set in `M.open` below) already stops Neovim's own
--- 'equalalways' from doing this on its own, but a config with 'equalalways' off, or the
--- transient resize a brand-new split briefly imposes on its neighbor before this module
--- ever gets a chance to react, both slip past that -- so this is belt-and-braces, not the
--- primary fix. A no-op when the width already matches, so it never fights a user's own
--- manual `<C-w>` resize on every unrelated re-render.
function Panel:ensure_width()
  if not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local want = config.get().panel.width
  if vim.api.nvim_win_get_width(self.win) ~= want then
    vim.api.nvim_win_set_width(self.win, want)
  end
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

--- Move the cursor to `path`'s row WITHOUT taking window focus. `on_toggle_viewed` below
--- already does this itself when the toggle originates *in* the panel; this public
--- method is for the opposite direction -- `init.lua`'s `toggle_viewed_and_advance`, which
--- runs when a diff/file buffer's own `toggle_viewed` key advances to the next file, needs
--- a way to keep the panel's cursor in sync without stealing focus away from wherever the
--- user actually is (the diff/file buffer). A no-op when `path` isn't currently a visible
--- row (e.g. hidden behind a fold).
---@param path string
function Panel:set_cursor(path)
  local lnum = row_for_path(self, path)
  if lnum and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_set_cursor, self.win, { lnum, 0 })
  end
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

--- Move the cursor to, and open, `session:next_unviewed(after_path)` -- the auto-advance
--- tail shared by `on_toggle_viewed` (single-file toggle, `after_path` is the just-toggled
--- file) and the batch actions `on_sweep`/`on_toggle_viewed_subtree` below (`after_path =
--- nil`: a batch touches files scattered across the tree, so there is no single "after"
--- file to resume from -- start over from the beginning of `tree.file_order` instead, same
--- as a fresh review's first auto-advance-free open would).
---@param panel difit.Panel
---@param after_path string?
local function advance_to_next_unviewed(panel, after_path)
  local nxt = panel.session:next_unviewed(after_path)
  if nxt then
    local lnum = row_for_path(panel, nxt)
    if lnum and vim.api.nvim_win_is_valid(panel.win) then
      vim.api.nvim_win_set_cursor(panel.win, { lnum, 0 })
    end
    panel.session:open_file(nxt)
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
  -- new state, which is exactly what `advance_to_next_unviewed` below needs.
  local became_viewed = panel.session:toggle_viewed(node.path)

  -- Auto-advance only on MARKING a file viewed, never on un-marking it (design.md:
  -- "Marking advances to the next un-viewed file") -- otherwise un-marking a mistake
  -- would also yank the cursor/diff away from the file the user is looking at.
  if became_viewed and config.get().auto_advance then
    advance_to_next_unviewed(panel, node.path)
  end
end

--- `result` from `Session:toggle_viewed_batch`/`sweep_patterns`, formatted as the same
--- compact one-line report `init.lua`'s `M.sweep()` gives for `:Difit sweep` -- reimplemented
--- here rather than shared across the two files for the same reason
--- `toggle_viewed_and_advance`/`on_toggle_viewed` are already duplicated between them (see
--- init.lua): this call site has its own panel-local cursor/row bookkeeping to run
--- afterwards, and init.lua has none of that to share it with.
---@param result {marked: integer, unmarked: integer, matched: integer}
local function notify_batch_result(result)
  if result.marked > 0 then
    vim.notify(
      string.format("difit: marked %d files as viewed", result.marked),
      vim.log.levels.INFO
    )
  else
    vim.notify(string.format("difit: unmarked %d files", result.unmarked), vim.log.levels.INFO)
  end
end

--- `S`: bulk-toggle every entry matching `config.viewed_patterns` (see
--- `Session:sweep_patterns()`). Distinguishes "the option is unset" from "it's set but
--- nothing in this diff matches it" -- both are all-zero-counts results at the `Session`
--- level, so the two INFO messages are resolved here rather than inferred from the count.
---@param panel difit.Panel
local function on_sweep(panel)
  if #config.get().viewed_patterns == 0 then
    vim.notify("difit: viewed_patterns is not configured", vim.log.levels.INFO)
    return
  end

  local result = panel.session:sweep_patterns()
  if result.matched == 0 then
    vim.notify("difit: no files matched viewed_patterns", vim.log.levels.INFO)
    return
  end

  notify_batch_result(result)
  if result.marked > 0 and config.get().auto_advance then
    advance_to_next_unviewed(panel, nil)
  end
end

--- `V`: on a FILE row, behaves exactly like `v` (delegates to `on_toggle_viewed` verbatim,
--- including its own single-file auto-advance). On a DIRECTORY row, bulk-toggles every file
--- entry in that subtree via `Session:toggle_viewed_batch`.
---
--- Subtree membership is a plain path-prefix test against `panel.session.entries` --
--- `entry.path` starting with `node.path .. "/"` -- rather than walking the currently
--- RENDERED tree under this row. That's deliberate: the rendered tree is built from
--- `visible_entries()`, which drops already-viewed files while `hide_viewed` is on, and the
--- tri-state "all viewed -> unmark" branch of `toggle_viewed_batch` only works if it can see
--- those already-viewed files in the first place. Folds have the same problem (a folded
--- child directory's files never even get a row). Matching directly against `node.path` --
--- always the real, uncompressed directory path even after `tree.build`'s single-child-chain
--- compression, see `tree.lua`'s `collapse_chains` -- sidesteps both filters at once.
---@param panel difit.Panel
local function on_toggle_viewed_subtree(panel)
  local node = current_node(panel)
  if not node then
    return
  end
  if node.type == "file" then
    on_toggle_viewed(panel)
    return
  end

  local prefix = node.path .. "/"
  local paths = {}
  for _, entry in ipairs(panel.session.entries) do
    if vim.startswith(entry.path, prefix) then
      table.insert(paths, entry.path)
    end
  end

  local result = panel.session:toggle_viewed_batch(paths)
  if result.matched == 0 then
    return
  end

  notify_batch_result(result)
  if result.marked > 0 and config.get().auto_advance then
    advance_to_next_unviewed(panel, nil)
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

--- Reference point for `]f`/`[f` when pressed IN the panel: the row under the cursor,
--- same as every other panel-local action (`on_open`/`on_toggle_viewed`/`on_fold`) --
--- falling back to `session.current_path` only when the cursor isn't parked on a file row
--- at all (the header/progress lines, a dir row, or an empty tree), so the keys still do
--- something sensible instead of silently no-op-ing there.
---@param panel difit.Panel
---@return string|nil
local function reference_path(panel)
  local node = current_node(panel)
  if node and node.type == "file" then
    return node.path
  end
  return panel.session.current_path
end

--- `]f`/`[f` in the panel: ALWAYS all files, `hide_viewed` or not (design.md's
--- "Interaction" rule -- the filter is a display concern, never a navigation one; skipping
--- viewed files during navigation is what `v`'s auto-advance is already for). Unlike
--- `on_toggle_viewed`'s auto-advance, this always moves the cursor via `Panel:set_cursor`
--- (not a raw `nvim_win_set_cursor`) since the target may currently be hidden behind a
--- fold -- or, with the filter on, simply may not be about to become a row at all until
--- `hide_viewed` is turned back off, in which case `set_cursor` is already documented to
--- no-op rather than error.
---@param panel difit.Panel
local function on_next_file(panel)
  local target = panel.session:next_file(reference_path(panel))
  if target then
    panel.session:open_file(target)
    panel:set_cursor(target)
  end
end

---@param panel difit.Panel
local function on_prev_file(panel)
  local target = panel.session:prev_file(reference_path(panel))
  if target then
    panel.session:open_file(target)
    panel:set_cursor(target)
  end
end

--- `H`: toggle whether already-viewed files are hidden from the tree, then re-render.
--- Display-only -- `hide_viewed` lives only on this `difit.Panel` instance, is never
--- persisted, and never affects navigation (`next_unviewed`/`next_file`/`prev_file` all
--- read `session` state, never panel rows) or the header's progress counts (always global,
--- see `progress_text`).
---@param panel difit.Panel
local function on_toggle_hide_viewed(panel)
  panel.hide_viewed = not panel.hide_viewed
  panel:render()
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
    toggle_hide_viewed = on_toggle_hide_viewed,
    sweep = on_sweep,
    toggle_viewed_subtree = on_toggle_viewed_subtree,
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

  -- `keymaps.universal`: the same leader-prefixed keys that work in every other difit
  -- context (owned diff buffers, real file buffers -- see ui/sidebyside.lua/ui/unified.lua)
  -- must also work on the panel, so a user doesn't have to remember a different key just
  -- because the cursor happens to be here. toggle_viewed/toggle_mode reuse the EXACT same
  -- handlers as the panel's own `v`/`s` above (identical row-under-cursor/auto-advance
  -- semantics, not a re-implementation); focus_panel is `panel:focus()`, a harmless no-op
  -- since this fires from the panel buffer itself. next_file/prev_file (`]f`/`[f`) get
  -- their own panel-local handlers too (`on_next_file`/`on_prev_file` above) rather than
  -- reusing `init.lua`'s `build_actions` version: the panel has no `path` to hand them the
  -- way a diff/real-file buffer's keymap closure does, so it resolves its own reference
  -- point off the row under the cursor instead (see `reference_path`). Applied AFTER
  -- `keymaps.panel` above, so a user-configured lhs collision between the two groups
  -- resolves to the universal binding, same deterministic order as the owned diff buffers.
  local universal_actions = {
    toggle_viewed = on_toggle_viewed,
    toggle_mode = on_toggle_mode,
    focus_panel = function(p)
      p:focus()
    end,
    next_file = on_next_file,
    prev_file = on_prev_file,
  }
  local universal = config.get().keymaps.universal
  for name, fn in pairs(universal_actions) do
    local lhs = universal[name]
    if lhs then -- `false` (or unset) disables the mapping
      vim.keymap.set("n", lhs, function()
        fn(panel)
      end, {
        buffer = panel.buf,
        nowait = true,
        silent = true,
        desc = "difit: universal " .. name,
      })
    end
  end
end

---@param session difit.Session
---@return difit.Panel
function M.open(session)
  local cfg = config.get()

  local buf = vim.api.nvim_create_buf(false, true)
  -- Named after the buffer's own (unique) number: since docs/refactor-v1.md R1, more
  -- than one review -- hence more than one panel -- can be open at once, and a bare
  -- "difit://panel" would collide (E95) on the second `panel.open()` call. R4 unifies
  -- this into the same `difit://<kind>/<session_id>` scheme every other owned buffer
  -- uses (see ui/scratch.lua) -- the panel just supplies its own bufnr as the
  -- discriminator, since it's already known and already unique.
  vim.api.nvim_buf_set_name(buf, scratch.name("panel", buf))
  -- No `filetype`/highlighting: the panel draws its own extmarks and, per
  -- docs/refactor-v1.md R4, `difit://` buffers must never fire `FileType` autocmds.
  scratch.configure(buf, { modifiable = false })

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
  -- Every mode switch closes/reopens the diff-area windows, and both views build theirs by
  -- splitting rightward FROM this window (ctx.anchor -- see ui/sidebyside.lua's
  -- `ensure_windows`/ui/unified.lua's `ensure_window`). Without these, Neovim's default
  -- 'equalalways' re-equalizes every non-fixed window -- including this one -- the instant
  -- a window opens or closes anywhere in the tabpage, silently drifting the panel away from
  -- `config.panel.width` on every single toggle. diffview.nvim's own file panel sets the
  -- same two options for the identical reason.
  vim.wo[win].winfixwidth = true
  vim.wo[win].winfixheight = true
  -- Sentinel for init.lua's `WinClosed` teardown funnel (docs/refactor-v1.md R1): the
  -- panel window is the sole navigational anchor of a review, so its own closure is what
  -- that autocmd watches for. Harmless when this module is driven standalone (see
  -- tests/test_panel.lua) -- nothing reads `vim.w[win].difit` outside init.lua.
  vim.w[win].difit = true
  -- Defense in depth (Neovim 0.12+): both diff views already build their own windows via
  -- explicit `ctx.anchor`/`ctx.claim` handles and never touch "the current window" (docs/
  -- refactor-v1.md R2), so nothing should ever `:edit`/`:buffer` a real file straight into
  -- this one -- but 'winfixbuf' makes Neovim itself refuse that outright, so a future code
  -- path that gets this wrong still can't silently destroy the tree.
  vim.wo[win].winfixbuf = true

  local panel = setmetatable({
    buf = buf,
    win = win,
    session = session,
    folded = {},
    row_nodes = {},
    hide_viewed = false,
  }, Panel)

  set_keymaps(panel)

  session:subscribe(function()
    if vim.api.nvim_buf_is_valid(panel.buf) then
      panel:render()
    end
    -- Runs on every refresh/toggle/set_mode notification (this is the panel's own single
    -- subscriber callback -- see `Panel:ensure_width`'s doc for why this belongs here
    -- rather than a dedicated WinResized/WinNew autocmd): a set_mode tears down and rebuilds
    -- the diff-area windows before notifying, so this is always the first point after that
    -- churn where the panel can reliably re-pin its own width back.
    panel:ensure_width()
  end)

  panel:render()
  return panel
end

return M
