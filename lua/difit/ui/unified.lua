-- Unified (single-column patch) diff view (WP-G). Read-only formatted-patch buffer with
-- a jump-to-file key; kept deliberately dumb (no diff algorithm of its own) so it can
-- later be swapped for an inline-overlay implementation without touching callers -- the
-- `difit.View` interface (open/close) is the only contract other modules depend on.

local config = require("difit.config")
local git = require("difit.git")

local M = {}

--- Module-level seam for `config.keymaps.diff.toggle_viewed`, mirroring the pattern used
--- by the side-by-side view: this module has no session dependency of its own, so the
--- integration WP overrides this to actually record viewed state. No-op by default.
---@param path string
function M._on_toggle_viewed(path) end

---@class difit.ui.UnifiedBufMeta
---@field path string      -- entry.path, relative to toplevel
---@field toplevel string  -- absolute worktree root, for resolving the real file
---@field jump_map table<integer, integer>  -- 1-based buffer line -> real-file line

---@class difit.ui.UnifiedView : difit.View
---@field win integer?                          -- the one window this view owns
---@field bufs table<string, integer>            -- bufname -> owned bufnr
---@field meta table<integer, difit.ui.UnifiedBufMeta>  -- bufnr -> jump metadata
local View = {}
View.__index = View

--- Build the buffer content and its line -> real-file-line jump map for one entry.
--- Binary entries get a single placeholder line and an empty jump map (nothing to jump
--- to). Deleted/added/renamed files fall out of `git.hunks` naturally; a nil hunk list
--- (e.g. a transient git error) degrades to just the header line rather than erroring.
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

  local hunks = git.hunks(spec.repo, entry, spec.merge_base, spec.right)
  for _, hunk in ipairs(hunks or {}) do
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

--- Get the owned buffer for `name`, creating (and configuring) it on first use.
---@param self difit.ui.UnifiedView
---@param name string
---@return integer bufnr
local function get_or_create_buf(self, name)
  local existing = self.bufs[name]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "diff"
  self.bufs[name] = buf
  return buf
end

--- Ensure `self.win` points at a live window, splitting off the current one on first
--- use. Subsequent opens reuse it.
---@param self difit.ui.UnifiedView
local function ensure_window(self)
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    return
  end
  vim.cmd("vsplit")
  self.win = vim.api.nvim_get_current_win()
end

--- Resolve the window that a file jump should land in: Vim's own "previous window"
--- (`CTRL-W p`) when that is a real window distinct from the unified one, else a fresh
--- vertical split next to it. Assumes the unified window is currently focused (true
--- whenever this runs from its own `<CR>` mapping).
---@param self difit.ui.UnifiedView
---@return integer winid
local function target_window(self)
  local unified_win = self.win
  vim.cmd("wincmd p")
  local candidate = vim.api.nvim_get_current_win()
  if candidate ~= unified_win and vim.api.nvim_win_is_valid(candidate) then
    return candidate
  end

  -- `wincmd p` had nowhere else to go (the unified view is the only window in this
  -- tabpage) -- give the real file its own split instead of hijacking this one.
  vim.api.nvim_set_current_win(unified_win)
  vim.cmd("vsplit")
  return vim.api.nvim_get_current_win()
end

--- `<CR>` handler: jump to the real file at the line the current buffer line maps to.
--- No-op on lines with no mapping (the `diff --git` line and hunk headers).
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
  vim.cmd("edit " .. vim.fn.fnameescape(meta.toplevel .. "/" .. meta.path))

  local line_count = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(win, { math.min(target_line, line_count), 0 })
end

--- Apply the hardcoded jump key plus the configurable toggle-viewed key to `buf`.
---@param self difit.ui.UnifiedView
---@param buf integer
---@param entry difit.FileEntry
local function setup_keymaps(self, buf, entry)
  vim.keymap.set("n", "<CR>", function()
    jump_to_file(self, buf)
  end, { buffer = buf, silent = true, nowait = true, desc = "difit: jump to file" })

  local toggle_key = config.get().keymaps.diff.toggle_viewed
  if toggle_key then
    vim.keymap.set("n", toggle_key, function()
      M._on_toggle_viewed(entry.path)
    end, { buffer = buf, silent = true, desc = "difit: toggle viewed" })
  end
end

---@param entry difit.FileEntry
---@param spec difit.DiffSpec
function View:open(entry, spec)
  local bufname = "difit://unified/" .. entry.path
  local buf = get_or_create_buf(self, bufname)

  local lines, jump_map = build_content(entry, spec)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  self.meta[buf] = { path = entry.path, toplevel = spec.repo.toplevel, jump_map = jump_map }

  ensure_window(self)
  vim.api.nvim_win_set_buf(self.win, buf)
  vim.api.nvim_set_current_win(self.win)

  setup_keymaps(self, buf, entry)
end

function View:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil

  for _, buf in pairs(self.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  self.bufs = {}
  self.meta = {}
end

---@return difit.View
function M.new()
  return setmetatable({ win = nil, bufs = {}, meta = {} }, View)
end

return M
