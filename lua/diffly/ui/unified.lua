-- Unified (single-column) diff view: inline overlay on top of the REAL file/blob buffer
-- (docs/architecture.md "Rendering"). The old design rendered a synthetic `diff --git` patch buffer with no
-- source-language highlighting and no LSP; this one shows the actual buffer -- worktree
-- file, HEAD blob, or deleted-file blob -- and paints the diff on top of it with extmarks:
-- "+" lines get a line-level highlight, and each contiguous run of "-" lines becomes ONE
-- `virt_lines` extmark anchored where the text used to sit. Context lines get no marks.
--
-- docs/architecture.md "View contract" view contract: `M.new(ctx)` (see `diffly.ui.ViewCtx` in
-- `ui/keymaps.lua`) -- this view never reads "the current window". Its one window is
-- always created by splitting rightward from `ctx.anchor` (the panel window), or by
-- absorbing `ctx.claim` when one is offered and still valid; buffer-local keymap callbacks
-- go through `ctx.actions` instead of module-level seam slots. `ui/sidebyside.lua` follows
-- the identical contract, and this view reuses its real-buffer/universal-keymap/head-blob
-- patterns (via the shared helpers in `ui/keymaps.lua` and `ui/scratch.lua`) rather than
-- re-deriving them.

local git = require("diffly.git")
local ui_comments = require("diffly.ui.comments")
local ui_keymaps = require("diffly.ui.keymaps")
local scratch = require("diffly.ui.scratch")
local guard = require("diffly.ui.guard")

local M = {}

---@class diffly.ui.UnifiedView : diffly.View
---@field ctx diffly.ui.ViewCtx
---@field win integer?                          -- the one window this view owns
---@field owned_wins integer[]                  -- same window as `win`; destroyed by close()
---@field owned_bufs table<integer, boolean>     -- diffly-owned scratch buffers, wiped by close()
---@field ns integer               -- this view's own overlay namespace (one ns per concern)
---@field comment_ns integer       -- this view's own comment namespace -- separate from the
--- overlay's `ns` on purpose ("one ns per concern"): `render_overlay`'s clear-and-redraw
--- must never eat comment marks, and a comment-only repaint (`refresh_comments`) must
--- never disturb the overlay
---@field shown { buf: integer, path: string, hunks: diffly.Hunk[], deleted: boolean }?
--- -- what `View:open` last rendered, exactly what a comment-only repaint needs
---@field universal_buf integer?   -- real bufnr currently carrying the overlay + `keymaps.universal`
---@field universal_keys string[]? -- keys applied to `universal_buf` (see `ui_keymaps.detach_universal`)
---@field force_loaded table<string, boolean> -- paths whose size OR generated-file guard
--- (config.max_file_size/config.collapse_generated, ui/guard.lua) has been bypassed for
--- the rest of THIS view instance's lifetime -- one shared set for both guards (forcing
--- past either bypasses the other too), resets on a mode switch/close (a fresh view
--- instance) rather than persisting
local View = {}
View.__index = View

--- Ensure `self.win` points at a live window: splitting rightward from `self.ctx.anchor`
--- (the panel window) on first use, or absorbing `self.ctx.claim` (the initial placeholder
--- window `init.lua` creates alongside the viewer tabpage) when one is offered and still
--- valid -- consumed at most once, mirroring `ui/sidebyside.lua`'s `ensure_windows`
--- (docs/architecture.md "View contract"). `ctx.anchor` itself is never claimed or touched, so this
--- view's window can never collide with whatever the anchor currently shows. Subsequent
--- opens reuse `self.win`.
---@param self diffly.ui.UnifiedView
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
  vim.w[self.win].diffly = true
  self.owned_wins = { self.win }
end

--- Load a blob's content via `git.file_content`, notifying once on a REAL git failure
--- (docs/architecture.md "Rendering") rather than silently degrading to the same empty buffer a
--- legitimate absence would produce -- mirrors `ui/sidebyside.lua`'s `set_left`/
--- `set_right_head`.
---@param repo diffly.RepoIdentity
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
    string.format("diffly: failed to load %s blob for %s: %s", what, path, err or "unknown error"),
    vim.log.levels.WARN
  )
  return {}
end

--- Get-or-create a diffly-owned scratch buffer, tracking it in `self.owned_bufs` so
--- `close()` can wipe it later, and applying the full `keymaps.diff` + `keymaps.universal`
--- action sets (every diffly-owned buffer this view creates gets both -- mirrors
--- `ui/sidebyside.lua`'s `View:owned_buffer`).
---@param self diffly.ui.UnifiedView
---@param name string
---@param lines string[]
---@param path string
---@param side "base"|"head"|nil  -- which side's content the buffer shows; nil
--- (placeholders) keeps the comment keys off the buffer entirely
---@return integer bufnr
local function owned_buffer(self, name, lines, path, side)
  local bufnr = scratch.find_or_create(name, { lines = lines, filename = path })
  self.owned_bufs[bufnr] = true
  local keymap_opts = { side = side }
  ui_keymaps.apply(bufnr, ui_keymaps.diff_spec(self.ctx.actions, path, keymap_opts))
  ui_keymaps.apply(bufnr, ui_keymaps.universal_spec(self.ctx.actions, path, keymap_opts))
  return bufnr
end

--- Detach the overlay + `keymaps.universal` from whatever real buffer currently carries
--- them, unless `keep` names that exact buffer (re-opening the very same file reuses it).
--- Mirrors `ui/sidebyside.lua`'s `clear_universal_keymaps`, extended with this view's own
--- extra responsibility: a real buffer must retain no trace of the overlay either, the
--- moment the view stops showing it (a different file, a diffly-owned buffer, or close()).
---@param self diffly.ui.UnifiedView
---@param keep integer?
local function release_real_buf(self, keep)
  if not self.universal_buf or self.universal_buf == keep then
    return
  end
  if vim.api.nvim_buf_is_valid(self.universal_buf) then
    vim.api.nvim_buf_clear_namespace(self.universal_buf, self.ns, 0, -1)
    -- Same rule for the comment layer: a real buffer must retain no diffly marks once
    -- the view stops showing it.
    vim.api.nvim_buf_clear_namespace(self.universal_buf, self.comment_ns, 0, -1)
  end
  ui_keymaps.detach_universal(self)
end

--- Comment-layer repaint of whatever `View:open` last rendered: placements from the
--- session's threads (through `ctx.actions` -- views never hold a session), then a full
--- clear-and-redraw of `self.comment_ns` only. Head-side threads map 1:1 onto the shown
--- buffer; base-side threads go through the hunk walk -- except on a deleted file, whose
--- buffer IS the base blob, so base threads map 1:1 there (and its head side no longer
--- exists to render).
---@param self diffly.ui.UnifiedView
local function render_comments(self)
  local shown = self.shown
  if not shown or not vim.api.nvim_buf_is_valid(shown.buf) then
    return
  end

  local actions = self.ctx.actions
  local threads = actions.comments_for(shown.path)
  local line_count = vim.api.nvim_buf_line_count(shown.buf)

  local placements
  if shown.deleted then
    placements = ui_comments.direct_placements(threads, "base", line_count)
  else
    placements = ui_comments.direct_placements(threads, "head", line_count)
    vim.list_extend(
      placements,
      ui_comments.mapped_base_placements(threads, shown.hunks, line_count)
    )
  end

  ui_comments.render(shown.buf, self.comment_ns, placements, {
    collapsed = actions.comments_collapsed(),
    wrap_width = ui_comments.wrap_width(self.win),
  })
end

--- Compute this hunk set's overlay as plain data: 0-based rows to paint `DifflyOverlayAdd`
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
---@param hunks diffly.Hunk[]
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
---@param self diffly.ui.UnifiedView
---@param buf integer
---@param hunks diffly.Hunk[]
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
      -- end_row makes this a line-spanning range: a zero-width point mark with only
      -- hl_eol renders NOTHING (the highlight needs an extent to paint).
      vim.api.nvim_buf_set_extmark(
        buf,
        self.ns,
        row,
        0,
        { end_row = row + 1, end_col = 0, hl_group = "DifflyOverlayAdd", hl_eol = true }
      )
    end
  end

  for _, run in ipairs(delete_runs) do
    local chunks = {}
    for _, line in ipairs(run.lines) do
      table.insert(chunks, { { line, "DifflyOverlayDelete" } })
    end
    vim.api.nvim_buf_set_extmark(buf, self.ns, run.row, 0, {
      virt_lines = chunks,
      virt_lines_above = run.above,
    })
  end
end

--- Deleted-file rendering: the buffer already IS the removed content in full (the base
--- blob), so every line just gets a line-level `DifflyOverlayDelete` highlight -- no
--- `virt_lines` needed, unlike the mixed add/delete overlay `render_overlay` draws for a
--- file that still exists on the new side.
---@param self diffly.ui.UnifiedView
---@param buf integer
local function render_all_deleted(self, buf)
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for row = 0, line_count - 1 do
    -- Same line-spanning range as the add marks: point marks paint nothing.
    vim.api.nvim_buf_set_extmark(buf, self.ns, row, 0, {
      end_row = math.min(row + 1, line_count),
      end_col = 0,
      hl_group = "DifflyOverlayDelete",
      hl_eol = true,
    })
  end
end

--- Binary entries: a shared one-line placeholder, diffly-owned (gets `keymaps.diff` +
--- `keymaps.universal` like every other owned buffer), no overlay.
---@param self diffly.ui.UnifiedView
---@param entry diffly.FileEntry
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

--- Oversized entries (`config.max_file_size` -- see `ui/guard.lua`): the same
--- shared-placeholder shape as `show_binary` (diffly-owned, `keymaps.diff` +
--- `keymaps.universal`), styled identically, but with the actual/limit sizes in the
--- message and a buffer-local `L` key that force-loads this exact path for the rest of
--- this view instance's lifetime (`self.force_loaded`) rather than being unconditional
--- like binary's placeholder. `actual` (rather than just `entry.path`) is folded into the
--- buffer name so a `session:refresh()` that changes the file's size while it's still
--- oversized gets a FRESH buffer instead of reusing stale message text -- mirrors every
--- other owned buffer here relying on a content-addressed name for reuse-safety (see
--- `show_deleted`/`show_head_blob` below).
---@param self diffly.ui.UnifiedView
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
---@param actual integer  -- bytes, the largest oversized side
---@param limit integer   -- bytes, config.max_file_size
local function show_oversized(self, entry, spec, actual, limit)
  release_real_buf(self, nil)
  local name =
    scratch.name("oversized", self.ctx.anchor, string.format("%s@%d", entry.path, actual))
  local buf = owned_buffer(self, name, { guard.message(actual, limit) }, entry.path)
  vim.api.nvim_win_set_buf(self.win, buf)
  guard.apply_force_load_keymap(buf, self, entry, spec)
end

--- Generated entries (`config.collapse_generated` -- see `ui/guard.lua`/
--- `lua/diffly/generated.lua`): the same shared-placeholder shape as `show_oversized`
--- (diffly-owned, `keymaps.diff` + `keymaps.universal`, a force-load `L` key), but with a
--- fixed message (no size to report) -- so, unlike `show_oversized`'s buffer name, this one
--- needs no content-addressed suffix.
---@param self diffly.ui.UnifiedView
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
local function show_generated(self, entry, spec)
  release_real_buf(self, nil)
  local name = scratch.name("generated", self.ctx.anchor, entry.path)
  local buf = owned_buffer(self, name, { guard.generated_message() }, entry.path)
  vim.api.nvim_win_set_buf(self.win, buf)
  guard.apply_force_load_keymap(buf, self, entry, spec)
end

--- Deleted entries (`entry.head_sha == nil`): a read-only blob of `entry.base_sha`,
--- entirely painted as deleted (see `render_all_deleted`). Content-addressed buffer name
--- (mirrors `ui/sidebyside.lua`'s left/head blob naming): reuse across opens is always
--- content-safe, since the name embeds the exact sha being shown.
---@param self diffly.ui.UnifiedView
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
local function show_deleted(self, entry, spec)
  release_real_buf(self, nil)
  local lines = entry.base_sha and load_blob(spec.repo, entry.base_sha, entry.path, "base") or {}
  local name =
    scratch.name(scratch.short_sha(entry.base_sha) or "empty", self.ctx.anchor, entry.path)
  local buf = owned_buffer(self, name, lines, entry.path, entry.base_sha and "base" or nil)
  vim.api.nvim_win_set_buf(self.win, buf)
  render_all_deleted(self, buf)
  return buf
end

--- `spec.right == "worktree"`: `:edit` the real file directly into `self.win` -- normal
--- buffer semantics (autocmds, filetype/LSP, `:w`) apply exactly like
--- `ui/sidebyside.lua`'s right-hand worktree window. Only `keymaps.universal` is applied
--- (design.md: real file buffers never get the single-key `keymaps.diff` shortcuts),
--- attached/detached via the same lifecycle `ui/sidebyside.lua` uses.
---@param self diffly.ui.UnifiedView
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
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

--- `spec.right == "head"`: a read-only blob of `entry.head_sha` (diffly-owned, gets
--- `keymaps.diff` + `keymaps.universal`) -- mirrors `ui/sidebyside.lua`'s `set_right_head`.
---@param self diffly.ui.UnifiedView
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
---@return integer buf
local function show_head_blob(self, entry, spec)
  release_real_buf(self, nil)
  local lines = load_blob(spec.repo, entry.head_sha, entry.path, "head")
  local name = scratch.name(scratch.short_sha(entry.head_sha), self.ctx.anchor, entry.path)
  local buf = owned_buffer(self, name, lines, entry.path, "head")
  vim.api.nvim_win_set_buf(self.win, buf)
  return buf
end

--- Binary takes precedence over both content-hiding guards unconditionally (config.lua's
--- `max_file_size` doc): a binary entry never shows size/generated text or gets an `L`
--- key, since there's nothing further to "load" -- the binary placeholder IS the final
--- render. Between the other two, the size guard runs first (docs/architecture.md
--- "Rendering"): an oversized file's content is never loaded, so the generated-file
--- heuristics (which need to read that content) never get a chance to run for it -- an
--- accepted divergence from a hypothetical "check generated first" ordering, since running
--- heuristics would defeat the size guard's entire point.
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
function View:open(entry, spec)
  ensure_window(self)

  -- Placeholders below render no comments; `shown` only ever points at a buffer whose
  -- lines are real file content the placement math can anchor into.
  self.shown = nil

  if entry.binary then
    show_binary(self, entry)
    vim.api.nvim_set_current_win(self.win)
    return
  end

  if not self.force_loaded[entry.path] then
    local limit = guard.limit()
    if limit then
      local oversized = guard.exceeds(guard.unified_sizes(spec.repo, entry, spec), limit)
      if oversized then
        show_oversized(self, entry, spec, oversized, limit)
        vim.api.nvim_set_current_win(self.win)
        return
      end
    end

    if guard.is_generated(spec.repo, entry, spec) then
      show_generated(self, entry, spec)
      vim.api.nvim_set_current_win(self.win)
      return
    end
  end

  if not entry.head_sha then
    local buf = show_deleted(self, entry, spec)
    self.shown = { buf = buf, path = entry.path, hunks = {}, deleted = true }
    -- No ordering concern here: render_all_deleted paints line highlights only (no
    -- virt_lines to stack against).
    render_comments(self)
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
          "diffly: failed to compute hunks for %s: %s",
          entry.path,
          err or "unknown error"
        ),
        vim.log.levels.WARN
      )
      hunks = {}
    end
    -- Comments BEFORE the overlay, deliberately: same-(row, above) virt_lines stack by
    -- creation order with the later-created mark on top, so a base-side comment sharing
    -- a deletion run's anchor renders BELOW the deleted lines it annotates only when the
    -- overlay's mark is created after the comment's (see ui/comments.lua; pinned by the
    -- unified comments golden).
    self.shown = { buf = buf, path = entry.path, hunks = hunks, deleted = false }
    render_comments(self)
    render_overlay(self, buf, hunks)
  end

  vim.api.nvim_set_current_win(self.win)
end

--- Optional View-contract method (`Session:_refresh_comment_render`): repaint the
--- comment namespace of whatever this view currently shows -- no window churn, no cursor
--- movement, exactly what a comment mutation or collapse toggle needs. The overlay is
--- repainted right after, NOT because its data changed, but to restore the
--- comments-first creation order that keeps deletion runs above the comments annotating
--- them (see `View:open`).
function View:refresh_comments()
  render_comments(self)
  local shown = self.shown
  if shown and not shown.deleted and vim.api.nvim_buf_is_valid(shown.buf) then
    render_overlay(self, shown.buf, shown.hunks)
  end
end

--- Optional View-contract method (`Session:focus_line`, same family as
--- `refresh_comments`): focus the view window and put the cursor on `line`, clamped to
--- the buffer end so a stale line number still lands somewhere sensible. Side "base"
--- resolves through the same hunk walk the comment layer renders with
--- (`ui_comments.base_target`), so the cursor lands exactly where a base-side thread's
--- virt_lines sit; a deleted file needs no mapping (the buffer IS the base blob), and a
--- placeholder render (`shown == nil`) degrades to the plain clamp.
---@param line integer
---@param side "base"|"head"|nil
function View:focus_line(line, side)
  if not (self.win and vim.api.nvim_win_is_valid(self.win)) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(self.win)
  local count = vim.api.nvim_buf_line_count(buf)
  local target = line
  local shown = self.shown
  if side == "base" and shown and not shown.deleted and shown.buf == buf then
    target = ui_comments.base_target(shown.hunks, count, line).row + 1
  end
  vim.api.nvim_set_current_win(self.win)
  vim.api.nvim_win_set_cursor(self.win, { math.max(1, math.min(target, count)), 0 })
end

--- Closes the owned window (docs/architecture.md "View contract"), releases whatever real buffer
--- carried the overlay/`keymaps.universal`, then wipes every owned scratch buffer still
--- exclusively ours (see the `win_findbuf` guard below).
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
  self.shown = nil

  for buf in pairs(self.owned_bufs) do
    -- An owned buffer that SURVIVES below (still shown by the incoming view's window
    -- during the set_mode overlap) must not keep this view's comment marks: the incoming
    -- view repaints its OWN comment ns, and a leftover ns from this one would render
    -- every comment twice.
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, self.comment_ns, 0, -1)
    end
    -- Regression guard (the "focus lands on the panel after switching modes on a
    -- binary/head-mode file" bug): binary placeholders and head-mode blobs are named
    -- purely from `entry.path`/the sha/`ctx.anchor` (see ui/scratch.lua), with no
    -- per-view component, so `ui/sidebyside.lua` and this view can end up sharing the
    -- EXACT SAME buffer for the same file. `Session:set_mode` opens the incoming view
    -- BEFORE closing this outgoing one (docs/architecture.md "View contract"), so by the
    -- time this loop runs, the incoming view's window may already be showing this very
    -- buffer -- and `nvim_buf_delete` closes every window still displaying the buffer it
    -- deletes, not just the ones this view itself owns. Deleting out from under a live
    -- window would silently destroy it and drop focus back to whatever's left (the
    -- panel). Only delete once no window anywhere still needs it; whichever view still
    -- owns a window on it will wipe it in its own close() later.
    if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  self.owned_bufs = {}
end

---@param ctx diffly.ui.ViewCtx
---@return diffly.View
function M.new(ctx)
  return setmetatable({
    ctx = ctx,
    win = nil,
    owned_wins = {},
    owned_bufs = {},
    ns = vim.api.nvim_create_namespace(""), -- anonymous: one dedicated ns per view instance
    comment_ns = vim.api.nvim_create_namespace(""), -- ditto; see the field doc above
    shown = nil,
    universal_buf = nil,
    universal_keys = nil,
    universal_token = nil,
    force_loaded = {},
  }, View)
end

return M
