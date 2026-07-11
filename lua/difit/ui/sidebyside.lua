-- Side-by-side diff view (design.md "UI" > "Side-by-side"): a two-window vertical diff
-- pair reused across `open()` calls. Left window always shows a read-only `difit://` blob
-- buffer for the base side; right window shows either the real worktree file (edits + `:w`
-- work normally) or a read-only HEAD blob, depending on `spec.right`.
--
-- docs/architecture.md "View contract" view contract: `M.new(ctx)` (see `difit.ui.ViewCtx` in
-- `ui/keymaps.lua`) -- this view never reads "the current window". Both its windows are
-- always created by splitting rightward from `ctx.anchor` (the panel window), or by
-- absorbing `ctx.claim` when one is offered and still valid; buffer-local keymap callbacks
-- go through `ctx.actions` instead of module-level seam slots. `ui/unified.lua` follows
-- the identical contract.

local git = require("difit.git")
local ui_keymaps = require("difit.ui.keymaps")
local scratch = require("difit.ui.scratch")
local size_guard = require("difit.ui.size_guard")

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
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
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
---@param entry difit.FileEntry
---@param session_id integer
---@return string
local function right_blob_buffer_name(entry, session_id)
  if not entry.head_sha then
    return scratch.name("deleted", session_id, entry.path)
  end
  return scratch.name(scratch.short_sha(entry.head_sha), session_id, entry.path)
end

---@class difit.ui.SideBySide : difit.View
---@field ctx difit.ui.ViewCtx
---@field left_win integer?   -- not part of the difit.View contract; exposed for tests
---@field right_win integer?  -- ditto
---@field owned_wins integer[]  -- every window this view currently owns; destroyed by close()
---@field owned_bufs table<integer, boolean>
---@field universal_buf integer?    -- real bufnr currently carrying `keymaps.universal`, if
--- any -- read/written by `ui/keymaps.lua`'s `attach_universal`/`detach_universal`, not by
--- this module directly (see the calls in `set_right_worktree`/`clear_universal_keymaps`
--- below).
---@field universal_keys string[]?  -- keys applied to `universal_buf`, ditto
---@field force_loaded table<string, boolean> -- paths whose size guard (config.max_file_size,
--- ui/size_guard.lua) has been bypassed for the rest of THIS view instance's lifetime --
--- resets on a mode switch/close (a fresh view instance) rather than persisting
local View = {}
View.__index = View

--- Get-or-create a difit-owned scratch buffer via ui/scratch.lua: `buftype=nofile`,
--- `bufhidden=hide`, non-modifiable once populated, LSP-safe highlighting (never
--- `'filetype'` -- docs/architecture.md "Rendering"). Reuses an existing buffer with the exact
--- same name instead of recreating/re-populating it (buffer names always embed whatever
--- makes their content unique, so reuse is always content-safe).
---@param name string
---@param lines string[]
---@param opts { filename: string?, entry_path: string }
---@return integer bufnr
function View:owned_buffer(name, lines, opts)
  local bufnr = scratch.find_or_create(name, { lines = lines, filename = opts.filename })
  self.owned_bufs[bufnr] = true
  -- Deterministic apply order (see config.lua): `keymaps.diff` first, `keymaps.universal`
  -- second -- `vim.keymap.set` overwrites on a shared lhs, so a user who configures the
  -- same key in both groups gets the universal binding, consistently across every owned
  -- buffer (mirrors `ui/unified.lua`'s equivalent helper).
  ui_keymaps.apply(bufnr, ui_keymaps.diff_spec(self.ctx.actions, opts.entry_path))
  ui_keymaps.apply(bufnr, ui_keymaps.universal_spec(self.ctx.actions, opts.entry_path))
  return bufnr
end

--- Peel `keymaps.universal` off whatever real buffer currently holds them, if any. Called
--- whenever the right window stops showing a real file (deleted-file scratch, binary
--- placeholder, `close()`) -- the previous real buffer is left alone otherwise (design.md:
--- editing/`:w` on it must keep working normally), it just must not keep difit's keymaps.
--- Thin wrapper around `ui/keymaps.lua`'s shared lifecycle (see `View.universal_buf`'s doc
--- above) -- kept as a method so call sites read the same as before the extraction.
function View:clear_universal_keymaps()
  ui_keymaps.detach_universal(self)
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

  vim.w[left].difit = true
  vim.w[right].difit = true

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
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
function View:set_left(entry, spec)
  local lines = {}
  if entry.base_sha then
    local content, err = git.file_content(spec.repo, { sha = entry.base_sha })
    if content then
      lines = content
    else
      vim.notify(
        string.format(
          "difit: failed to load base blob for %s: %s",
          entry.path,
          err or "unknown error"
        ),
        vim.log.levels.WARN
      )
    end
  end
  local bufnr = self:owned_buffer(
    left_buffer_name(entry, spec, self.ctx.anchor),
    lines,
    { filename = entry.path, entry_path = entry.path }
  )
  vim.api.nvim_win_set_buf(self.left_win, bufnr)
end

--- Populate the right window for `spec.right == "worktree"`: `:edit` the real file so
--- normal buffer semantics (autocmds, filetype detection, `:w`) apply, or an empty
--- scratch when the file was deleted in the worktree.
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
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
  ui_keymaps.attach_universal(
    self,
    vim.api.nvim_win_get_buf(self.right_win),
    entry.path,
    self.ctx.actions
  )
end

--- Populate the right window for `spec.right == "head"`: a read-only blob buffer of
--- entry.head_sha, following the same empty-scratch rule as the left side when there is
--- no blob (file doesn't exist at HEAD, i.e. deleted) -- and the same real-failure
--- notice as `set_left` when `entry.head_sha` is set but the blob still fails to load.
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
function View:set_right_head(entry, spec)
  local lines = {}
  if entry.head_sha then
    local content, err = git.file_content(spec.repo, { sha = entry.head_sha })
    if content then
      lines = content
    else
      vim.notify(
        string.format(
          "difit: failed to load head blob for %s: %s",
          entry.path,
          err or "unknown error"
        ),
        vim.log.levels.WARN
      )
    end
  end
  local bufnr = self:owned_buffer(
    right_blob_buffer_name(entry, self.ctx.anchor),
    lines,
    { filename = entry.path, entry_path = entry.path }
  )
  vim.api.nvim_win_set_buf(self.right_win, bufnr)
  -- `spec.right` never actually changes across one View instance's lifetime (see
  -- `session.lua`: a mode/right change always goes through a fresh view), but clearing
  -- here too is a cheap belt-and-suspenders against a real file's keymaps surviving a
  -- switch away from worktree mode.
  self:clear_universal_keymaps()
end

--- Binary entries never get `diffthis`; both windows just show the same one-line
--- placeholder buffer.
---@param entry difit.FileEntry
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

--- Oversized entries (`config.max_file_size` -- see `ui/size_guard.lua`): the same
--- shared-placeholder shape as `show_binary` (both windows, `keymaps.diff` +
--- `keymaps.universal`, no `diffthis`), but with the actual/limit sizes in the message and
--- a buffer-local `L` key that force-loads this exact path for the rest of this view
--- instance's lifetime (`self.force_loaded`) rather than being unconditional like binary's
--- placeholder. `actual` (rather than just `entry.path`) is folded into the buffer name
--- so a `session:refresh()` that changes the file's size while it's still oversized gets a
--- FRESH buffer instead of reusing stale message text -- mirrors every other owned buffer
--- here relying on a content-addressed name for reuse-safety.
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
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
    { size_guard.message(actual, limit) },
    { entry_path = entry.path }
  )
  vim.api.nvim_win_set_buf(self.left_win, bufnr)
  vim.api.nvim_win_set_buf(self.right_win, bufnr)
  size_guard.apply_force_load_keymap(bufnr, self, entry, spec)
end

--- Focus the right window and land on the first change, mirroring the plan's
--- "gg]c"-guarded-by-pcall behavior: files with no visible diff (or no 'diff' at all,
--- e.g. binary entries) must not raise.
function View:focus_right_first_change()
  vim.api.nvim_set_current_win(self.right_win)
  pcall(vim.cmd, "normal! gg]c")
end

--- Binary takes precedence over the size guard unconditionally (config.lua's
--- `max_file_size` doc): a binary entry never shows size text or gets an `L` key, since
--- there's nothing further to "load" -- the binary placeholder IS the final render.
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
function View:open(entry, spec)
  self:ensure_windows()
  self:diffoff()

  if entry.binary then
    self:show_binary(entry)
    self:focus_right_first_change()
    return
  end

  local limit = size_guard.limit()
  if limit and not self.force_loaded[entry.path] then
    local oversized = size_guard.exceeds(size_guard.sidebyside_sizes(spec.repo, entry, spec), limit)
    if oversized then
      self:show_oversized(entry, spec, oversized, limit)
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

  self:focus_right_first_change()
end

--- `diffoff` where applicable, close every owned window, then wipe every difit-owned
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

  for bufnr in pairs(self.owned_bufs) do
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

---@param ctx difit.ui.ViewCtx
---@return difit.View
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
    force_loaded = {},
  }, View)
end

return M
