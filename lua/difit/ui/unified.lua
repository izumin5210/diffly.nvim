-- Unified (single-column patch) diff view (WP-G). Read-only formatted-patch buffer with
-- a jump-to-file key; kept deliberately dumb (no diff algorithm of its own) so it can
-- later be swapped for an inline-overlay implementation without touching callers -- the
-- `difit.View` interface (open/close) is the only contract other modules depend on.
--
-- docs/refactor-v1.md R2/R3 view contract: `M.new(ctx)` (see `difit.ui.ViewCtx` in
-- `ui/keymaps.lua`) -- this view never reads "the current window". Its one window is
-- always created by splitting rightward from `ctx.anchor` (the panel window), or by
-- absorbing `ctx.claim` when one is offered and still valid; buffer-local keymap callbacks
-- go through `ctx.actions` instead of module-level seam slots. `ui/sidebyside.lua` follows
-- the identical contract.

local config = require("difit.config")
local git = require("difit.git")
local ui_keymaps = require("difit.ui.keymaps")
local scratch = require("difit.ui.scratch")

local M = {}

---@class difit.ui.UnifiedBufMeta
---@field path string      -- entry.path, relative to toplevel
---@field toplevel string  -- absolute worktree root, for resolving the real file
---@field repo difit.RepoIdentity   -- for fetching HEAD blob content when right == "head"
---@field right "worktree"|"head"
---@field head_sha string?  -- entry.head_sha; the blob to jump into when right == "head"
---@field jump_map table<integer, integer>  -- 1-based buffer line -> new-file line

---@class difit.ui.UnifiedView : difit.View
---@field ctx difit.ui.ViewCtx
---@field win integer?                          -- the one window this view owns
---@field owned_wins integer[]                  -- same window as `win`; destroyed by close()
---@field bufs table<string, integer>            -- bufname -> owned bufnr
---@field meta table<integer, difit.ui.UnifiedBufMeta>  -- bufnr -> jump metadata
local View = {}
View.__index = View

--- Build the buffer content and its line -> real-file-line jump map for one entry.
--- Binary entries get a single placeholder line and an empty jump map (nothing to jump
--- to). Deleted/added/renamed files fall out of `git.hunks` naturally; a nil hunk list
--- is a REAL git failure (docs/refactor-v1.md R4) -- notify once and degrade to just the
--- header line, so the UI still renders instead of erroring.
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return string[] lines
---@return table<integer, integer> jump_map
local function build_content(entry, spec)
  if entry.binary then
    return { "binary file" }, {}
  end

  local lines = { "diff --git a/" .. (entry.old_path or entry.path) .. " b/" .. entry.path }
  local jump_map = {}

  local hunks, err = git.hunks(spec.repo, entry, spec.merge_base, spec.right)
  if not hunks then
    vim.notify(
      string.format("difit: failed to compute hunks for %s: %s", entry.path, err or "unknown error"),
      vim.log.levels.WARN
    )
    hunks = {}
  end
  for _, hunk in ipairs(hunks) do
    table.insert(lines, hunk.header)

    -- Count only "+"/" " body lines: those are the ones that exist in the new file, so
    -- the Nth one (0-indexed) sits at `new_start + N`. "-" lines have no new-file line
    -- of their own; clicking one jumps to the top of the hunk instead.
    local seen = 0
    for _, body_line in ipairs(hunk.lines) do
      table.insert(lines, body_line)
      local marker = body_line:sub(1, 1)
      if marker == "+" or marker == " " then
        jump_map[#lines] = hunk.new_start + seen
        seen = seen + 1
      elseif marker == "-" then
        jump_map[#lines] = hunk.new_start
      end
      -- marker == "\\" ("\ No newline at end of file"): left unmapped, <CR> no-ops.
    end
  end

  return lines, jump_map
end

--- Get-or-create the owned buffer for `name` via ui/scratch.lua, tracking it in
--- `self.bufs` so `close()` can sweep it later (scratch.lua itself no longer needs that
--- table for lookups -- `vim.fn.bufnr(name)` already handles reuse -- but this view still
--- owns cleaning up whatever it created).
---@param self difit.ui.UnifiedView
---@param name string
---@param opts difit.ui.scratch.Opts?
---@return integer bufnr
local function get_or_create_buf(self, name, opts)
  local buf = scratch.find_or_create(name, opts)
  self.bufs[name] = buf
  return buf
end

--- Ensure `self.win` points at a live window: splitting rightward from `self.ctx.anchor`
--- (the panel window) on first use, or absorbing `self.ctx.claim` (the initial placeholder
--- window `init.lua` creates alongside the viewer tabpage) when one is offered and still
--- valid -- consumed at most once, mirroring `ui/sidebyside.lua`'s `ensure_windows`
--- (docs/refactor-v1.md R2). `ctx.anchor` itself is never claimed or touched, so this
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

--- Resolve the window that a file jump should land in: Vim's own "previous window"
--- (`CTRL-W p`) when that is a real window distinct from the unified one AND not a
--- difit-owned window (most notably the panel, `difit://panel`) -- else a fresh vertical
--- split next to it. Assumes the unified window is currently focused (true whenever this
--- runs from its own `<CR>` mapping).
---
--- The difit-owned check matters because `wincmd p`'s "previous window" is Vim's own
--- last-focused-window tracking, not anything this plugin controls: e.g. switching modes
--- while the panel is focused builds the new unified window via a `vsplit` run *while
--- the panel is current*, which makes the panel Vim's "previous window" from that point
--- on -- so an unguarded `wincmd p` here would jump straight back into the panel and then
--- `:edit` the real file into it, destroying the tree.
---@param self difit.ui.UnifiedView
---@return integer winid
local function target_window(self)
  local unified_win = self.win
  vim.cmd("wincmd p")
  local candidate = vim.api.nvim_get_current_win()
  local candidate_owned = false
  if vim.api.nvim_win_is_valid(candidate) then
    local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(candidate))
    candidate_owned = vim.startswith(bufname, "difit://")
  end

  if candidate ~= unified_win and vim.api.nvim_win_is_valid(candidate) and not candidate_owned then
    return candidate
  end

  -- `wincmd p` had nowhere else to go (the unified view is the only window in this
  -- tabpage), or landed on a difit-owned window -- give the real file its own split
  -- instead of hijacking either.
  vim.api.nvim_set_current_win(unified_win)
  vim.cmd("vsplit")
  return vim.api.nvim_get_current_win()
end

--- `spec.right == "head"`: `jump_map` lines were computed against `git diff <base>
--- HEAD` (see `build_content`), i.e. they're HEAD-relative -- but the *worktree* file may
--- have diverged from HEAD since (more/fewer lines above the hunk), so opening it there
--- would land on the wrong line, or the wrong content entirely. Open a read-only blob of
--- `entry.head_sha` instead, so the line numbers always match what the diff showed,
--- mirroring `ui/sidebyside.lua`'s own head-mode blob buffers (including its buffer
--- naming scheme -- see ui/scratch.lua). A `head_sha` that fails to load is a REAL git
--- failure (docs/refactor-v1.md R4): notify once and still open an empty blob rather
--- than erroring.
---@param self difit.ui.UnifiedView
---@param win integer
---@param meta difit.ui.UnifiedBufMeta
---@return integer bufnr
local function open_head_blob(self, win, meta)
  local short_sha = meta.head_sha and meta.head_sha:sub(1, 7) or "unknown"
  local name = scratch.name(short_sha, self.ctx.anchor, meta.path)

  local content
  if meta.head_sha then
    local err
    content, err = git.file_content(meta.repo, { sha = meta.head_sha })
    if not content then
      vim.notify(
        string.format("difit: failed to load blob for %s: %s", meta.path, err or "unknown error"),
        vim.log.levels.WARN
      )
    end
  end

  local buf = get_or_create_buf(self, name, { lines = content or {}, filename = meta.path })
  vim.api.nvim_win_set_buf(win, buf)
  return buf
end

--- `<CR>` handler: jump to the line the current buffer line maps to -- the real worktree
--- file when `spec.right == "worktree"`, or a read-only HEAD blob buffer when
--- `spec.right == "head"` (see `open_head_blob`). No-op on lines with no mapping (the
--- `diff --git` line and hunk headers).
---@param self difit.ui.UnifiedView
---@param buf integer
local function jump_to_file(self, buf)
  local meta = self.meta[buf]
  if not meta then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local target_line = meta.jump_map[cursor_line]
  if not target_line then
    return
  end

  local win = target_window(self)
  vim.api.nvim_set_current_win(win)

  if meta.right == "head" then
    open_head_blob(self, win, meta)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(meta.toplevel, meta.path)))
  end

  local line_count = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(win, { math.min(target_line, line_count), 0 })
end

--- Apply the hardcoded jump key plus the full configurable `config.keymaps.diff` action
--- set (toggle_viewed/toggle_mode/focus_panel/close) to `buf`. This buffer is always
--- difit-owned (`difit://unified/...`), so it only ever gets `keymaps.diff`, never
--- `keymaps.file` -- see `ui/sidebyside.lua` for the real-buffer case.
---@param self difit.ui.UnifiedView
---@param buf integer
---@param entry difit.FileEntry
local function setup_keymaps(self, buf, entry)
  vim.keymap.set("n", "<CR>", function()
    jump_to_file(self, buf)
  end, { buffer = buf, silent = true, nowait = true, desc = "difit: jump to file" })

  local cfg = config.get().keymaps.diff
  local actions = self.ctx.actions
  ui_keymaps.apply(buf, {
    toggle_viewed = {
      key = cfg.toggle_viewed,
      callback = function()
        actions.toggle_viewed(entry.path)
      end,
    },
    toggle_mode = {
      key = cfg.toggle_mode,
      callback = function()
        actions.toggle_mode()
      end,
    },
    focus_panel = {
      key = cfg.focus_panel,
      callback = function()
        actions.focus_panel()
      end,
    },
    close = {
      key = cfg.close,
      callback = function()
        actions.close()
      end,
    },
  })
end

---@param entry difit.FileEntry
---@param spec difit.DiffSpec
function View:open(entry, spec)
  -- `lang = "diff"` (never `entry.path`'s own language): this buffer's content is always
  -- a unified patch, regardless of which file it's showing -- highlighting it as the
  -- reviewed file's own language would be wrong even before considering docs/
  -- refactor-v1.md R4's "never set 'filetype'" rule.
  local bufname = scratch.name("unified", self.ctx.anchor, entry.path)
  local buf = get_or_create_buf(self, bufname, { lang = "diff" })

  local lines, jump_map = build_content(entry, spec)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  self.meta[buf] = {
    path = entry.path,
    toplevel = spec.repo.toplevel,
    repo = spec.repo,
    right = spec.right,
    head_sha = entry.head_sha,
    jump_map = jump_map,
  }

  ensure_window(self)
  vim.api.nvim_win_set_buf(self.win, buf)
  vim.api.nvim_set_current_win(self.win)

  setup_keymaps(self, buf, entry)
end

--- Closes the owned window (docs/refactor-v1.md R2), then wipes every owned buffer.
function View:close()
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

  for _, buf in pairs(self.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  self.bufs = {}
  self.meta = {}
end

---@param ctx difit.ui.ViewCtx
---@return difit.View
function M.new(ctx)
  return setmetatable({ ctx = ctx, win = nil, owned_wins = {}, bufs = {}, meta = {} }, View)
end

return M
