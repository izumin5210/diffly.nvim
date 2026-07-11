-- Unified (single-column) diff view: inline overlay on top of the REAL file/blob buffer
-- (docs/architecture.md "Rendering"). The old design rendered a synthetic `diff --git` patch buffer with no
-- source-language highlighting and no LSP; this one shows the actual buffer -- worktree
-- file, HEAD blob, or deleted-file blob -- and paints the diff on top of it with extmarks:
-- "+" lines get a line-level highlight, and each contiguous run of "-" lines becomes ONE
-- `virt_lines` extmark anchored where the text used to sit. Context lines get no marks.
--
-- docs/architecture.md "View contract" view contract: `M.new(ctx)` (see `difit.ui.ViewCtx` in
-- `ui/keymaps.lua`) -- this view never reads "the current window". Its one window is
-- always created by splitting rightward from `ctx.anchor` (the panel window), or by
-- absorbing `ctx.claim` when one is offered and still valid; buffer-local keymap callbacks
-- go through `ctx.actions` instead of module-level seam slots. `ui/sidebyside.lua` follows
-- the identical contract, and this view reuses its real-buffer/universal-keymap/head-blob
-- patterns (via the shared helpers in `ui/keymaps.lua` and `ui/scratch.lua`) rather than
-- re-deriving them.

local git = require("difit.git")
local ui_keymaps = require("difit.ui.keymaps")
local scratch = require("difit.ui.scratch")

local M = {}

---@class difit.ui.UnifiedView : difit.View
---@field ctx difit.ui.ViewCtx
---@field win integer?                          -- the one window this view owns
---@field owned_wins integer[]                  -- same window as `win`; destroyed by close()
---@field owned_bufs table<integer, boolean>     -- difit-owned scratch buffers, wiped by close()
---@field ns integer               -- this view's own overlay namespace (one ns per concern)
---@field universal_buf integer?   -- real bufnr currently carrying the overlay + `keymaps.universal`
---@field universal_keys string[]? -- keys applied to `universal_buf` (see `ui_keymaps.detach_universal`)
local View = {}
View.__index = View

--- Ensure `self.win` points at a live window: splitting rightward from `self.ctx.anchor`
--- (the panel window) on first use, or absorbing `self.ctx.claim` (the initial placeholder
--- window `init.lua` creates alongside the viewer tabpage) when one is offered and still
--- valid -- consumed at most once, mirroring `ui/sidebyside.lua`'s `ensure_windows`
--- (docs/architecture.md "View contract"). `ctx.anchor` itself is never claimed or touched, so this
--- view's window can never collide with whatever the anchor currently shows. Subsequent
--- opens reuse `self.win`.
---@param self difit.ui.UnifiedView
local function ensure_window(self)
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    return
  end

  local ctx = self.ctx
  if ctx.claim and vim.api.nvim_win_is_valid(ctx.claim) then
    self.win = ctx.claim
    ctx.claim = nil
  else
    self.win = vim.api.nvim_open_win(
      vim.api.nvim_create_buf(false, true),
      true,
      { split = "right", win = ctx.anchor }
    )
  end
  vim.w[self.win].difit = true
  self.owned_wins = { self.win }
end

--- Load a blob's content via `git.file_content`, notifying once on a REAL git failure
--- (docs/architecture.md "Rendering") rather than silently degrading to the same empty buffer a
--- legitimate absence would produce -- mirrors `ui/sidebyside.lua`'s `set_left`/
--- `set_right_head`.
---@param repo difit.RepoIdentity
---@param sha string
---@param path string
---@param what string  -- "base"|"head", folded into the notify message
---@return string[] lines
local function load_blob(repo, sha, path, what)
  local content, err = git.file_content(repo, { sha = sha })
  if content then
    return content
  end
  vim.notify(
    string.format("difit: failed to load %s blob for %s: %s", what, path, err or "unknown error"),
    vim.log.levels.WARN
  )
  return {}
end

--- Get-or-create a difit-owned scratch buffer, tracking it in `self.owned_bufs` so
--- `close()` can wipe it later, and applying the full `keymaps.diff` + `keymaps.universal`
--- action sets (every difit-owned buffer this view creates gets both -- mirrors
--- `ui/sidebyside.lua`'s `View:owned_buffer`).
---@param self difit.ui.UnifiedView
---@param name string
---@param lines string[]
---@param path string
---@return integer bufnr
local function owned_buffer(self, name, lines, path)
  local bufnr = scratch.find_or_create(name, { lines = lines, filename = path })
  self.owned_bufs[bufnr] = true
  ui_keymaps.apply(bufnr, ui_keymaps.diff_spec(self.ctx.actions, path))
  ui_keymaps.apply(bufnr, ui_keymaps.universal_spec(self.ctx.actions, path))
  return bufnr
end

--- Detach the overlay + `keymaps.universal` from whatever real buffer currently carries
--- them, unless `keep` names that exact buffer (re-opening the very same file reuses it).
--- Mirrors `ui/sidebyside.lua`'s `clear_universal_keymaps`, extended with this view's own
--- extra responsibility: a real buffer must retain no trace of the overlay either, the
--- moment the view stops showing it (a different file, a difit-owned buffer, or close()).
---@param self difit.ui.UnifiedView
---@param keep integer?
local function release_real_buf(self, keep)
  if not self.universal_buf or self.universal_buf == keep then
    return
  end
  if vim.api.nvim_buf_is_valid(self.universal_buf) then
    vim.api.nvim_buf_clear_namespace(self.universal_buf, self.ns, 0, -1)
  end
  ui_keymaps.detach_universal(self)
end

--- Compute this hunk set's overlay as plain data: 0-based rows to paint `DifitOverlayAdd`
--- on, plus one virt_lines run per contiguous "-" block. Kept separate from the extmark
--- calls themselves so the anchoring math (the empirically-verified part) is easy to
--- reason about on its own.
---
--- Walks each hunk's body lines with `cur_new` starting at `hunk.new_start` (1-based):
--- " "/"+" lines occupy the real new-file line at `cur_new`, then advance it; "+" lines
--- additionally get an add row. "-" lines never advance `cur_new` -- they accumulate into
--- a pending run that gets flushed (as one virt_lines entry) the moment a non-"-" line is
--- seen, or the hunk ends. The flush's anchor row is `cur_new - 1` (0-based: "immediately
--- before the real line now sitting at `cur_new`"), with two edge cases confirmed against
--- real git output (see the empirical cases in tests/test_unified.lua):
---   - `cur_new == 0` (git reports this ONLY when the whole hunk -- and, in practice with
---     `-U3` context, the whole new-side file -- is empty; there is no "line 0" to anchor
---     before) -- clamp to row 0, still `virt_lines_above = true` (renders at the very top).
---   - the anchor would land past the buffer's last real line (a deletion running to EOF,
---     where the following line simply doesn't exist) -- clamp to the last line instead,
---     with `virt_lines_above = false` so the run renders BELOW it rather than overlapping.
--- "\ No newline at end of file" markers are skipped (neither a real line nor a deletion).
---@param hunks difit.Hunk[]
---@param line_count integer  -- `nvim_buf_line_count` of the buffer this overlay targets
---@return integer[] add_rows
---@return { row: integer, above: boolean, lines: string[] }[] delete_runs
local function compute_overlay(hunks, line_count)
  local add_rows = {}
  local delete_runs = {}

  for _, hunk in ipairs(hunks) do
    local cur_new = hunk.new_start
    local pending = nil

    local function flush()
      if not pending then
        return
      end
      local raw_row = cur_new - 1
      local row, above
      if raw_row < 0 then
        row, above = 0, true
      elseif raw_row > line_count - 1 then
        row, above = math.max(line_count - 1, 0), false
      else
        row, above = raw_row, true
      end
      table.insert(delete_runs, { row = row, above = above, lines = pending })
      pending = nil
    end

    for _, body_line in ipairs(hunk.lines) do
      local marker = body_line:sub(1, 1)
      if marker == " " then
        flush()
        cur_new = cur_new + 1
      elseif marker == "+" then
        flush()
        table.insert(add_rows, cur_new - 1)
        cur_new = cur_new + 1
      elseif marker == "-" then
        pending = pending or {}
        table.insert(pending, body_line:sub(2))
      end
      -- marker == "\\" ("\ No newline at end of file"): neither a real line nor a
      -- deletion -- skipped.
    end
    flush()
  end

  return add_rows, delete_runs
end

--- Full clear-and-redraw of `self.ns` on `buf` from `hunks` -- never incremental, so a
--- stale mark from a previous render (different hunks, a different file reusing this
--- buffer, ...) can never linger.
---@param self difit.ui.UnifiedView
---@param buf integer
---@param hunks difit.Hunk[]
local function render_overlay(self, buf, hunks)
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local add_rows, delete_runs = compute_overlay(hunks, line_count)

  -- `row` can exceed `line_count` when the hunks (computed straight from git) disagree
  -- with what's actually in `buf` -- the one legitimate way that happens is a blob whose
  -- content failed to load (docs/architecture.md "Rendering" already notified once for that), which
  -- degrades to an empty/short buffer while `hunks` still reflects the real diff. Skip
  -- rather than erroring `nvim_buf_set_extmark` out; `delete_runs`' own row is already
  -- clamped into range by `compute_overlay`, so only add rows need the guard here.
  for _, row in ipairs(add_rows) do
    if row >= 0 and row < line_count then
      vim.api.nvim_buf_set_extmark(
        buf,
        self.ns,
        row,
        0,
        { hl_group = "DifitOverlayAdd", hl_eol = true }
      )
    end
  end

  for _, run in ipairs(delete_runs) do
    local chunks = {}
    for _, line in ipairs(run.lines) do
      table.insert(chunks, { { line, "DifitOverlayDelete" } })
    end
    vim.api.nvim_buf_set_extmark(buf, self.ns, run.row, 0, {
      virt_lines = chunks,
      virt_lines_above = run.above,
    })
  end
end

--- Deleted-file rendering: the buffer already IS the removed content in full (the base
--- blob), so every line just gets a line-level `DifitOverlayDelete` highlight -- no
--- `virt_lines` needed, unlike the mixed add/delete overlay `render_overlay` draws for a
--- file that still exists on the new side.
---@param self difit.ui.UnifiedView
---@param buf integer
local function render_all_deleted(self, buf)
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for row = 0, line_count - 1 do
    vim.api.nvim_buf_set_extmark(
      buf,
      self.ns,
      row,
      0,
      { hl_group = "DifitOverlayDelete", hl_eol = true }
    )
  end
end

--- Binary entries: a shared one-line placeholder, difit-owned (gets `keymaps.diff` +
--- `keymaps.universal` like every other owned buffer), no overlay.
---@param self difit.ui.UnifiedView
---@param entry difit.FileEntry
local function show_binary(self, entry)
  release_real_buf(self, nil)
  local buf = owned_buffer(
    self,
    scratch.name("binary", self.ctx.anchor, entry.path),
    { "binary file" },
    entry.path
  )
  vim.api.nvim_win_set_buf(self.win, buf)
end

--- Deleted entries (`entry.head_sha == nil`): a read-only blob of `entry.base_sha`,
--- entirely painted as deleted (see `render_all_deleted`). Content-addressed buffer name
--- (mirrors `ui/sidebyside.lua`'s left/head blob naming): reuse across opens is always
--- content-safe, since the name embeds the exact sha being shown.
---@param self difit.ui.UnifiedView
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
local function show_deleted(self, entry, spec)
  release_real_buf(self, nil)
  local lines = entry.base_sha and load_blob(spec.repo, entry.base_sha, entry.path, "base") or {}
  local name =
    scratch.name(scratch.short_sha(entry.base_sha) or "empty", self.ctx.anchor, entry.path)
  local buf = owned_buffer(self, name, lines, entry.path)
  vim.api.nvim_win_set_buf(self.win, buf)
  render_all_deleted(self, buf)
end

--- `spec.right == "worktree"`: `:edit` the real file directly into `self.win` -- normal
--- buffer semantics (autocmds, filetype/LSP, `:w`) apply exactly like
--- `ui/sidebyside.lua`'s right-hand worktree window. Only `keymaps.universal` is applied
--- (design.md: real file buffers never get the single-key `keymaps.diff` shortcuts),
--- attached/detached via the same lifecycle `ui/sidebyside.lua` uses.
---@param self difit.ui.UnifiedView
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return integer buf
local function show_worktree_file(self, entry, spec)
  local abs_path = vim.fs.joinpath(spec.repo.toplevel, entry.path)
  vim.api.nvim_win_call(self.win, function()
    vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
  end)
  local buf = vim.api.nvim_win_get_buf(self.win)
  release_real_buf(self, buf)
  ui_keymaps.attach_universal(self, buf, entry.path, self.ctx.actions)
  return buf
end

--- `spec.right == "head"`: a read-only blob of `entry.head_sha` (difit-owned, gets
--- `keymaps.diff` + `keymaps.universal`) -- mirrors `ui/sidebyside.lua`'s `set_right_head`.
---@param self difit.ui.UnifiedView
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return integer buf
local function show_head_blob(self, entry, spec)
  release_real_buf(self, nil)
  local lines = load_blob(spec.repo, entry.head_sha, entry.path, "head")
  local name = scratch.name(scratch.short_sha(entry.head_sha), self.ctx.anchor, entry.path)
  local buf = owned_buffer(self, name, lines, entry.path)
  vim.api.nvim_win_set_buf(self.win, buf)
  return buf
end

---@param entry difit.FileEntry
---@param spec difit.DiffSpec
function View:open(entry, spec)
  ensure_window(self)

  if entry.binary then
    show_binary(self, entry)
  elseif not entry.head_sha then
    show_deleted(self, entry, spec)
  else
    local buf
    if spec.right == "worktree" then
      buf = show_worktree_file(self, entry, spec)
    else
      buf = show_head_blob(self, entry, spec)
    end

    -- A nil hunk list is a REAL git failure (docs/architecture.md "Rendering"): notify once and
    -- still render the buffer with no overlay at all, rather than erroring open() out.
    local hunks, err = git.hunks(spec.repo, entry, spec.merge_base, spec.right)
    if not hunks then
      vim.notify(
        string.format(
          "difit: failed to compute hunks for %s: %s",
          entry.path,
          err or "unknown error"
        ),
        vim.log.levels.WARN
      )
      hunks = {}
    end
    render_overlay(self, buf, hunks)
  end

  vim.api.nvim_set_current_win(self.win)
end

--- Closes the owned window (docs/architecture.md "View contract"), releases whatever real buffer
--- carried the overlay/`keymaps.universal`, then wipes every owned scratch buffer.
function View:close()
  release_real_buf(self, nil)

  for _, win in ipairs(self.owned_wins) do
    if vim.api.nvim_win_is_valid(win) then
      local tab = vim.api.nvim_win_get_tabpage(win)
      -- Never close the last window in a tabpage outright -- mirrors
      -- `ui/sidebyside.lua`'s own guard; the panel, at minimum, is always expected to
      -- remain whenever `close()` runs as part of ordinary session lifecycle.
      if #vim.api.nvim_tabpage_list_wins(tab) > 1 then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
  self.owned_wins = {}
  self.win = nil

  for buf in pairs(self.owned_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  self.owned_bufs = {}
end

---@param ctx difit.ui.ViewCtx
---@return difit.View
function M.new(ctx)
  return setmetatable({
    ctx = ctx,
    win = nil,
    owned_wins = {},
    owned_bufs = {},
    ns = vim.api.nvim_create_namespace(""), -- anonymous: one dedicated ns per view instance
    universal_buf = nil,
    universal_keys = nil,
    universal_token = nil,
  }, View)
end

return M
