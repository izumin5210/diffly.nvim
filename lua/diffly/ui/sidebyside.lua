-- Side-by-side diff view (design.md "UI" > "Side-by-side"): a two-window vertical diff
-- pair reused across `open()` calls. Left window always shows a read-only `diffly://` blob
-- buffer for the base side; right window shows either the real worktree file (edits + `:w`
-- work normally) or a read-only HEAD blob, depending on `spec.right`.
--
-- docs/architecture.md "View contract" view contract: `M.new(ctx)` (see `diffly.ui.ViewCtx` in
-- `ui/keymaps.lua`) -- this view never reads "the current window". Both its windows are
-- always created by splitting rightward from `ctx.anchor` (the panel window), or by
-- absorbing `ctx.claim` when one is offered and still valid; buffer-local keymap callbacks
-- go through `ctx.actions` instead of module-level seam slots. `ui/unified.lua` follows
-- the identical contract.

local git = require("diffly.git")
local hl = require("diffly.ui.hl")
local ui_comments = require("diffly.ui.comments")
local ui_keymaps = require("diffly.ui.keymaps")
local scratch = require("diffly.ui.scratch")
local guard = require("diffly.ui.guard")

local M = {}

--- Buffer name for the left (base) side. Deliberately keyed by `spec.merge_base` (which
--- is constant for the whole diff spec) rather than `entry.base_sha` (which would be
--- constant too, in practice, for a fixed merge-base -- but naming it after the spec
--- makes a `session:refresh()` that moves the merge-base forward produce fresh buffer
--- names instead of silently reusing stale content under an old name).
---
--- `session_id` (docs/architecture.md "Rendering") is `ctx.anchor`, the panel window this view's
--- session was built with -- stable and unique for the session's whole lifetime, so two
--- concurrent reviews whose entries happen to share a blob/merge-base sha never collide
--- on the same buffer name (see ui/scratch.lua).
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
---@param session_id integer
---@return string
local function left_buffer_name(entry, spec, session_id)
  if not entry.base_sha then
    return scratch.name("empty", session_id, entry.path)
  end
  return scratch.name(scratch.short_sha(spec.merge_base), session_id, entry.path)
end

--- Buffer name for the right side when it is a blob (head mode) rather than the real
--- file. Keyed by `entry.head_sha` itself (not the spec): unlike the base side, the
--- right-hand blob legitimately changes across refreshes without the merge-base moving
--- (e.g. a new commit on the reviewed branch), so the name must track it directly.
--- A nil `head_sha` means the file doesn't exist at the right-hand revision (deleted),
--- which is the same situation as a deleted worktree file, hence the shared "deleted"
--- name. See `left_buffer_name` above for why `session_id` is part of the name too.
---@param entry diffly.FileEntry
---@param session_id integer
---@return string
local function right_blob_buffer_name(entry, session_id)
  if not entry.head_sha then
    return scratch.name("deleted", session_id, entry.path)
  end
  return scratch.name(scratch.short_sha(entry.head_sha), session_id, entry.path)
end

---@class diffly.ui.SideBySide : diffly.View
---@field ctx diffly.ui.ViewCtx
---@field left_win integer?   -- not part of the diffly.View contract; exposed for tests
---@field right_win integer?  -- ditto
---@field owned_wins integer[]  -- every window this view currently owns; destroyed by close()
---@field owned_bufs table<integer, boolean>
---@field universal_buf integer?    -- real bufnr currently carrying `keymaps.universal`, if
--- any -- read/written by `ui/keymaps.lua`'s `attach_universal`/`detach_universal`, not by
--- this module directly (see the calls in `set_right_worktree`/`clear_universal_keymaps`
--- below).
---@field universal_keys string[]?  -- keys applied to `universal_buf`, ditto
---@field comment_ns integer  -- this view's own comment namespace (its FIRST extmark ns:
--- the diff visualization here is native 'diff' mode, not extmarks) -- anonymous and
--- per-instance, mirroring ui/unified.lua's "one ns per concern" rule
---@field shown { path: string, left_buf: integer, right_buf: integer }?
--- -- what `View:open` last rendered, exactly what a comment-only repaint needs
---@field force_loaded table<string, boolean> -- paths whose size OR generated-file guard
--- (config.max_file_size/config.collapse_generated, ui/guard.lua) has been bypassed for
--- the rest of THIS view instance's lifetime -- one shared set for both guards (forcing
--- past either bypasses the other too), resets on a mode switch/close (a fresh view
--- instance) rather than persisting
local View = {}
View.__index = View

--- Get-or-create a diffly-owned scratch buffer via ui/scratch.lua: `buftype=nofile`,
--- `bufhidden=hide`, non-modifiable once populated, LSP-safe highlighting (never
--- `'filetype'` -- docs/architecture.md "Rendering"). Reuses an existing buffer with the exact
--- same name instead of recreating/re-populating it (buffer names always embed whatever
--- makes their content unique, so reuse is always content-safe).
---@param name string
---@param lines string[]
---@param opts { filename: string?, entry_path: string, side: "base"|"head"|nil }
--- -- `side`: which side's content this buffer shows; nil (placeholders, empty
--- no-content scratches) keeps the comment keys off the buffer entirely
---@return integer bufnr
function View:owned_buffer(name, lines, opts)
  local bufnr = scratch.find_or_create(name, { lines = lines, filename = opts.filename })
  self.owned_bufs[bufnr] = true
  -- Deterministic apply order (see config.lua): `keymaps.diff` first, `keymaps.universal`
  -- second -- `vim.keymap.set` overwrites on a shared lhs, so a user who configures the
  -- same key in both groups gets the universal binding, consistently across every owned
  -- buffer (mirrors `ui/unified.lua`'s equivalent helper).
  local keymap_opts = { side = opts.side }
  ui_keymaps.apply(bufnr, ui_keymaps.diff_spec(self.ctx.actions, opts.entry_path, keymap_opts))
  ui_keymaps.apply(bufnr, ui_keymaps.universal_spec(self.ctx.actions, opts.entry_path, keymap_opts))
  return bufnr
end

--- Peel `keymaps.universal` off whatever real buffer currently holds them, if any. Called
--- whenever the right window stops showing a real file (deleted-file scratch, binary
--- placeholder, `close()`) -- the previous real buffer is left alone otherwise (design.md:
--- editing/`:w` on it must keep working normally), it just must not keep diffly's keymaps.
--- Thin wrapper around `ui/keymaps.lua`'s shared lifecycle (see `View.universal_buf`'s doc
--- above) -- kept as a method so call sites read the same as before the extraction.
function View:clear_universal_keymaps()
  -- The comment layer follows the exact same rule as the keymaps: a real buffer must
  -- retain no diffly marks once this view stops showing it.
  if self.universal_buf and vim.api.nvim_buf_is_valid(self.universal_buf) then
    vim.api.nvim_buf_clear_namespace(self.universal_buf, self.comment_ns, 0, -1)
  end
  ui_keymaps.detach_universal(self)
end

--- Comment-layer repaint of whatever `View:open` last rendered: base-side threads into
--- the left (base blob) buffer, head-side threads into the right one, each buffer's
--- `comment_ns` fully cleared and redrawn. Both buffers show their side's content 1:1,
--- so placement is the direct line mapping -- no hunk walk needed here, unlike
--- ui/unified.lua.
---@param self diffly.ui.SideBySide
local function render_comments(self)
  local shown = self.shown
  if not shown then
    return
  end

  local actions = self.ctx.actions
  local threads = actions.comments_for(shown.path)
  local collapsed = actions.comments_collapsed()

  for _, target in ipairs({
    { buf = shown.left_buf, side = "base", win = self.left_win },
    { buf = shown.right_buf, side = "head", win = self.right_win },
  }) do
    if vim.api.nvim_buf_is_valid(target.buf) then
      local line_count = vim.api.nvim_buf_line_count(target.buf)
      ui_comments.render(
        target.buf,
        self.comment_ns,
        ui_comments.direct_placements(threads, target.side, line_count),
        -- Each side wraps to its OWN window's budget: the two splits can differ in
        -- width (gutter columns, an uneven manual resize).
        { collapsed = collapsed, wrap_width = ui_comments.wrap_width(target.win) }
      )
    end
  end
end

--- Build the two-window vertical pair on first use, splitting rightward from
--- `self.ctx.anchor` (the panel window) -- or absorbing `self.ctx.claim` (the initial
--- placeholder window `init.lua` creates alongside the viewer tabpage, before any view has
--- opened anything) as the left window, when one is offered and still valid. `claim` is
--- consumed at most once: absorbing it clears `ctx.claim` so a later view build (a mode
--- switch) never mistakes some other window for a fresh claim.
---
--- `ctx.anchor` itself is NEVER claimed or otherwise touched here -- it is only ever a
--- split point -- so this view's windows can never collide with, or silently steal,
--- whatever the anchor currently shows (the historical bug class this replaces: guessing
--- at "the current window" and erroring on 'winfixbuf' or hijacking some other window).
---
--- Subsequent calls are a no-op as long as both windows are still valid.
function View:ensure_windows()
  if
    self.left_win
    and vim.api.nvim_win_is_valid(self.left_win)
    and self.right_win
    and vim.api.nvim_win_is_valid(self.right_win)
  then
    return
  end

  local ctx = self.ctx
  local left
  if ctx.claim and vim.api.nvim_win_is_valid(ctx.claim) then
    left = ctx.claim
    ctx.claim = nil
  else
    local placeholder = vim.api.nvim_create_buf(false, true)
    left = vim.api.nvim_open_win(placeholder, true, { split = "right", win = ctx.anchor })
  end

  local right = vim.api.nvim_open_win(
    vim.api.nvim_create_buf(false, true),
    true,
    { split = "right", win = left }
  )

  vim.w[left].diffly = true
  vim.w[right].diffly = true

  -- Remap native diff mode's symmetric highlight groups into the derived asymmetric
  -- palette -- one color family per pane, so the base pane never paints deleted lines
  -- green (docs/design.md "Side-by-side"). The remap rides diffly-owned window highlight
  -- namespaces, NEVER 'winhighlight' (rationale in ui/hl.lua: winhl is a contended
  -- read-modify-write string other plugins rewrite, and writing it leaks into the global
  -- default). Both windows are owned (fresh splits, or the absorbed claim placeholder --
  -- which `close()` destroys like any other owned window), so the attach needs no
  -- restore path.
  local ns = hl.diff_namespaces()
  vim.api.nvim_win_set_hl_ns(left, ns.old)
  vim.api.nvim_win_set_hl_ns(right, ns.new)

  self.left_win, self.right_win = left, right
  self.owned_wins = { left, right }
end

--- Turn off 'diff' in both windows if it happens to be set. Reused windows may still be
--- mid-diff from whatever the previous `open()` call showed there, so this always runs
--- before deciding whether to re-enable it -- otherwise a binary <-> textual transition
--- (or close()) would leave stale diff options (foldmethod, scrollbind, ...) behind.
function View:diffoff()
  for _, win in ipairs({ self.left_win, self.right_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        if vim.wo.diff then
          vim.cmd("diffoff")
        end
      end)
    end
  end
end

--- Populate the left window with entry.base_sha's blob content, or an empty scratch
--- buffer when there is no base blob (added/untracked file). `entry.base_sha == nil` is
--- a legitimate empty buffer (nothing to load); a non-nil sha that `git.file_content`
--- still fails to load is a REAL git failure (docs/architecture.md "Rendering") -- notify once
--- rather than silently degrading to the same empty buffer a legitimate absence would
--- produce, so the UI still renders instead of erroring.
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
function View:set_left(entry, spec)
  local lines = {}
  if entry.base_sha then
    local content, err = git.file_content(spec.repo, { sha = entry.base_sha })
    if content then
      lines = content
    else
      vim.notify(
        string.format(
          "diffly: failed to load base blob for %s: %s",
          entry.path,
          err or "unknown error"
        ),
        vim.log.levels.WARN
      )
    end
  end
  local bufnr = self:owned_buffer(left_buffer_name(entry, spec, self.ctx.anchor), lines, {
    filename = entry.path,
    entry_path = entry.path,
    -- An added/untracked file's empty left scratch has no base content to comment on.
    side = entry.base_sha and "base" or nil,
  })
  vim.api.nvim_win_set_buf(self.left_win, bufnr)
end

--- Populate the right window for `spec.right == "worktree"`: `:edit` the real file so
--- normal buffer semantics (autocmds, filetype detection, `:w`) apply, or an empty
--- scratch when the file was deleted in the worktree.
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
function View:set_right_worktree(entry, spec)
  if not entry.head_sha then
    local bufnr = self:owned_buffer(
      scratch.name("deleted", self.ctx.anchor, entry.path),
      {},
      { entry_path = entry.path }
    )
    vim.api.nvim_win_set_buf(self.right_win, bufnr)
    -- The right window no longer shows a real file -- drop whatever `keymaps.universal`
    -- maps the previous one carried instead of leaving them dangling on a buffer this view
    -- no longer has any window pointed at.
    self:clear_universal_keymaps()
    return
  end

  local abs_path = vim.fs.joinpath(spec.repo.toplevel, entry.path)
  vim.api.nvim_win_call(self.right_win, function()
    vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
  end)
  local buf = vim.api.nvim_win_get_buf(self.right_win)
  -- A real-to-real file switch bypasses `clear_universal_keymaps` (attach_universal
  -- peels the keymaps itself), but the comment layer follows the same rule: the
  -- previous real buffer must retain no diffly marks.
  if self.universal_buf and self.universal_buf ~= buf then
    if vim.api.nvim_buf_is_valid(self.universal_buf) then
      vim.api.nvim_buf_clear_namespace(self.universal_buf, self.comment_ns, 0, -1)
    end
  end
  ui_keymaps.attach_universal(self, buf, entry.path, self.ctx.actions)
end

--- Populate the right window for `spec.right == "head"`: a read-only blob buffer of
--- entry.head_sha, following the same empty-scratch rule as the left side when there is
--- no blob (file doesn't exist at HEAD, i.e. deleted) -- and the same real-failure
--- notice as `set_left` when `entry.head_sha` is set but the blob still fails to load.
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
function View:set_right_head(entry, spec)
  local lines = {}
  if entry.head_sha then
    local content, err = git.file_content(spec.repo, { sha = entry.head_sha })
    if content then
      lines = content
    else
      vim.notify(
        string.format(
          "diffly: failed to load head blob for %s: %s",
          entry.path,
          err or "unknown error"
        ),
        vim.log.levels.WARN
      )
    end
  end
  local bufnr = self:owned_buffer(right_blob_buffer_name(entry, self.ctx.anchor), lines, {
    filename = entry.path,
    entry_path = entry.path,
    side = entry.head_sha and "head" or nil,
  })
  vim.api.nvim_win_set_buf(self.right_win, bufnr)
  -- `spec.right` never actually changes across one View instance's lifetime (see
  -- `session.lua`: a mode/right change always goes through a fresh view), but clearing
  -- here too is a cheap belt-and-suspenders against a real file's keymaps surviving a
  -- switch away from worktree mode.
  self:clear_universal_keymaps()
end

--- Binary entries never get `diffthis`; both windows just show the same one-line
--- placeholder buffer.
---@param entry diffly.FileEntry
function View:show_binary(entry)
  -- Binary entries pre-empt `set_right_worktree` entirely (see `open()`), so the right
  -- window stops showing a real file even in worktree mode -- drop its `keymaps.universal`
  -- too.
  self:clear_universal_keymaps()
  local bufnr = self:owned_buffer(
    scratch.name("binary", self.ctx.anchor, entry.path),
    { "binary file" },
    { entry_path = entry.path }
  )
  vim.api.nvim_win_set_buf(self.left_win, bufnr)
  vim.api.nvim_win_set_buf(self.right_win, bufnr)
end

--- Oversized entries (`config.max_file_size` -- see `ui/guard.lua`): the same
--- shared-placeholder shape as `show_binary` (both windows, `keymaps.diff` +
--- `keymaps.universal`, no `diffthis`), but with the actual/limit sizes in the message and
--- a buffer-local `L` key that force-loads this exact path for the rest of this view
--- instance's lifetime (`self.force_loaded`) rather than being unconditional like binary's
--- placeholder. `actual` (rather than just `entry.path`) is folded into the buffer name
--- so a `session:refresh()` that changes the file's size while it's still oversized gets a
--- FRESH buffer instead of reusing stale message text -- mirrors every other owned buffer
--- here relying on a content-addressed name for reuse-safety.
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
---@param actual integer  -- bytes, the largest oversized side
---@param limit integer   -- bytes, config.max_file_size
function View:show_oversized(entry, spec, actual, limit)
  -- Oversized entries pre-empt `set_right_worktree` entirely (see `open()`), so the right
  -- window stops showing a real file even in worktree mode -- mirrors `show_binary`.
  self:clear_universal_keymaps()
  local name =
    scratch.name("oversized", self.ctx.anchor, string.format("%s@%d", entry.path, actual))
  local bufnr = self:owned_buffer(
    name,
    { guard.message(actual, limit) },
    { entry_path = entry.path }
  )
  vim.api.nvim_win_set_buf(self.left_win, bufnr)
  vim.api.nvim_win_set_buf(self.right_win, bufnr)
  guard.apply_force_load_keymap(bufnr, self, entry, spec)
end

--- Generated entries (`config.collapse_generated` -- see `ui/guard.lua`/
--- `lua/diffly/generated.lua`): the same shared-placeholder shape as `show_oversized`
--- (both windows, `keymaps.diff` + `keymaps.universal`, no `diffthis`, a force-load `L`
--- key), but with a fixed message (no size to report) -- so, unlike `show_oversized`'s
--- buffer name, this one needs no content-addressed suffix; the message never changes for
--- a given path.
---@param entry diffly.FileEntry
---@param spec diffly.DiffSpec
function View:show_generated(entry, spec)
  self:clear_universal_keymaps()
  local name = scratch.name("generated", self.ctx.anchor, entry.path)
  local bufnr = self:owned_buffer(name, { guard.generated_message() }, { entry_path = entry.path })
  vim.api.nvim_win_set_buf(self.left_win, bufnr)
  vim.api.nvim_win_set_buf(self.right_win, bufnr)
  guard.apply_force_load_keymap(bufnr, self, entry, spec)
end

--- Focus the right window and land on the first change, mirroring the plan's
--- "gg]c"-guarded-by-pcall behavior: files with no visible diff (or no 'diff' at all,
--- e.g. binary entries) must not raise.
function View:focus_right_first_change()
  vim.api.nvim_set_current_win(self.right_win)
  pcall(vim.cmd, "normal! gg]c")
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
  self:ensure_windows()
  self:diffoff()

  -- Placeholders below render no comments; `shown` only ever points at buffers whose
  -- lines are real side content the placement math can anchor into.
  self.shown = nil

  if entry.binary then
    self:show_binary(entry)
    self:focus_right_first_change()
    return
  end

  if not self.force_loaded[entry.path] then
    local limit = guard.limit()
    if limit then
      local oversized = guard.exceeds(guard.sidebyside_sizes(spec.repo, entry, spec), limit)
      if oversized then
        self:show_oversized(entry, spec, oversized, limit)
        self:focus_right_first_change()
        return
      end
    end

    if guard.is_generated(spec.repo, entry, spec) then
      self:show_generated(entry, spec)
      self:focus_right_first_change()
      return
    end
  end

  self:set_left(entry, spec)
  if spec.right == "worktree" then
    self:set_right_worktree(entry, spec)
  else
    self:set_right_head(entry, spec)
  end

  vim.api.nvim_win_call(self.left_win, function()
    vim.cmd("diffthis")
  end)
  vim.api.nvim_win_call(self.right_win, function()
    vim.cmd("diffthis")
  end)

  self.shown = {
    path = entry.path,
    left_buf = vim.api.nvim_win_get_buf(self.left_win),
    right_buf = vim.api.nvim_win_get_buf(self.right_win),
  }
  render_comments(self)

  self:focus_right_first_change()
end

--- Optional View-contract method (`Session:refresh_comment_render`): repaint ONLY the
--- comment namespace of whatever this view currently shows -- no window churn, no cursor
--- movement, exactly what a comment mutation or collapse toggle needs.
function View:refresh_comments()
  render_comments(self)
end

--- Optional View-contract method (`Session:focus_line`, same family as
--- `refresh_comments`): put the cursor on `line` and focus its window -- the LEFT
--- window for side "base" (its buffer is base content 1:1, so the line needs no
--- mapping), the right (new-side) one otherwise -- clamped to that buffer's end so a
--- stale line number still lands somewhere sensible.
---@param line integer
---@param side "base"|"head"|nil
function View:focus_line(line, side)
  local win = side == "base" and self.left_win or self.right_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(line, count)), 0 })
end

--- `diffoff` where applicable, close every owned window, then wipe every diffly-owned
--- buffer this view created (docs/architecture.md "View contract": views own their windows now, not
--- just their buffers -- WP-I no longer reaps them). Real file BUFFERS are still never
--- wiped: closing the right window when it shows one just closes that window, exactly
--- like any other window onto it closing would -- the buffer itself survives, hidden.
function View:close()
  self:diffoff()
  self:clear_universal_keymaps()

  for _, win in ipairs(self.owned_wins) do
    if vim.api.nvim_win_is_valid(win) then
      local tab = vim.api.nvim_win_get_tabpage(win)
      -- Never close the last window in a tabpage outright (`nvim_win_close` would error,
      -- or worse, tear down the whole tabpage/session) -- something besides this view's
      -- own windows (the panel, at minimum) is always expected to remain whenever
      -- `close()` runs as part of ordinary session lifecycle.
      if #vim.api.nvim_tabpage_list_wins(tab) > 1 then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
  self.owned_wins = {}
  self.left_win, self.right_win = nil, nil
  self.shown = nil

  for bufnr in pairs(self.owned_bufs) do
    -- An owned buffer that SURVIVES below (still shown by the incoming view's window
    -- during the set_mode overlap) must not keep this view's comment marks: the incoming
    -- view repaints its OWN comment ns, and a leftover ns from this one would render
    -- every comment twice.
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, self.comment_ns, 0, -1)
    end
    -- Regression guard (the "focus lands on the panel after switching modes on a
    -- binary/head-mode file" bug): binary placeholders and head-mode blobs are named
    -- purely from `entry.path`/the sha/`ctx.anchor` (see ui/scratch.lua), with no
    -- per-view component, so this view and `ui/unified.lua` can end up sharing the EXACT
    -- SAME buffer for the same file. `Session:set_mode` opens the incoming view BEFORE
    -- closing this outgoing one (docs/architecture.md "View contract"), so by the time
    -- this loop runs, the incoming view's window may already be showing this very buffer
    -- -- and `nvim_buf_delete` closes every window still displaying the buffer it
    -- deletes, not just the ones this view itself owns. Deleting out from under a live
    -- window would silently destroy it and drop focus back to whatever's left (the
    -- panel). Only delete once no window anywhere still needs it; whichever view still
    -- owns a window on it will wipe it in its own close() later.
    if vim.api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) == 0 then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  self.owned_bufs = {}
end

---@param ctx diffly.ui.ViewCtx
---@return diffly.View
function M.new(ctx)
  return setmetatable({
    ctx = ctx,
    left_win = nil,
    right_win = nil,
    owned_wins = {},
    owned_bufs = {},
    universal_buf = nil, -- real bufnr currently carrying `keymaps.universal`, if any
    universal_keys = nil, -- keys applied to `universal_buf`, for `ui_keymaps.remove`
    universal_token = nil, -- this attach's ownership stamp (see `ui_keymaps.attach_universal`)
    comment_ns = vim.api.nvim_create_namespace(""), -- anonymous, per-instance (field doc above)
    shown = nil,
    force_loaded = {},
  }, View)
end

return M
