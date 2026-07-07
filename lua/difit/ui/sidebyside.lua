-- Side-by-side diff view (design.md "UI" > "Side-by-side"): a two-window vertical diff
-- pair reused across `open()` calls in the current tabpage. Left window always shows a
-- read-only `difit://` blob buffer for the base side; right window shows either the real
-- worktree file (edits + `:w` work normally) or a read-only HEAD blob, depending on
-- `spec.right`. Window/tabpage positioning relative to a file-tree panel is out of scope
-- here -- WP-I decides where the *first* split lands; this module only guarantees the
-- pair is created once and reused afterwards.

local git = require("difit.git")
local config = require("difit.config")

local M = {}

-- Seam for WP-I: called with the toggled file's path whenever the user presses
-- `config.get().keymaps.diff.toggle_viewed` inside a difit-owned buffer. `difit.init`
-- doesn't exist yet, so callers can't `require("difit").toggle_viewed_current()`
-- directly; it overwrites this field once the session/panel wiring exists.
---@type fun(path: string)
M._on_toggle_viewed = function(_) end

-- All difit-owned scratch buffers are namespaced under this prefix so they can be told
-- apart from real file buffers at a glance (bufname prefix check) and swept up on
-- close().
local NS_PREFIX = "difit://"

---@param sha string?
---@return string?
local function short_sha(sha)
  return sha and sha:sub(1, 7) or nil
end

--- Buffer name for the left (base) side. Deliberately keyed by `spec.merge_base` (which
--- is constant for the whole diff spec) rather than `entry.base_sha` (which would be
--- constant too, in practice, for a fixed merge-base -- but naming it after the spec
--- makes a `session:refresh()` that moves the merge-base forward produce fresh buffer
--- names instead of silently reusing stale content under an old name).
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return string
local function left_buffer_name(entry, spec)
  if not entry.base_sha then
    return NS_PREFIX .. "empty/" .. entry.path
  end
  return NS_PREFIX .. short_sha(spec.merge_base) .. "/" .. entry.path
end

--- Buffer name for the right side when it is a blob (head mode) rather than the real
--- file. Keyed by `entry.head_sha` itself (not the spec): unlike the base side, the
--- right-hand blob legitimately changes across refreshes without the merge-base moving
--- (e.g. a new commit on the reviewed branch), so the name must track it directly.
--- A nil `head_sha` means the file doesn't exist at the right-hand revision (deleted),
--- which is the same situation as a deleted worktree file, hence the shared "deleted"
--- name.
---@param entry difit.FileEntry
---@return string
local function right_blob_buffer_name(entry)
  if not entry.head_sha then
    return NS_PREFIX .. "deleted/" .. entry.path
  end
  return NS_PREFIX .. short_sha(entry.head_sha) .. "/" .. entry.path
end

---@class difit.ui.SideBySide : difit.View
---@field left_win integer?   -- not part of the difit.View contract; exposed for tests
---@field right_win integer?  -- ditto
---@field owned_bufs table<integer, boolean>
local View = {}
View.__index = View

--- Look up an existing buffer by its exact name (per plan.md: `vim.fn.bufnr()` matches
--- an exact name before falling back to pattern matching, so this is safe even though
--- `name` embeds a path that could otherwise look pattern-like).
---@param name string
---@return integer? bufnr
local function find_buffer(name)
  local bufnr = vim.fn.bufnr(name)
  if bufnr == -1 then
    return nil
  end
  return bufnr
end

--- Apply the configured `toggle_viewed` keymap to a difit-owned buffer, invoking the
--- `M._on_toggle_viewed` seam with `path`. A falsy config value disables the mapping
--- (see config.lua).
---@param bufnr integer
---@param path string
local function apply_toggle_viewed_keymap(bufnr, path)
  local key = vim.tbl_get(config.get(), "keymaps", "diff", "toggle_viewed")
  if not key then
    return
  end
  vim.keymap.set("n", key, function()
    M._on_toggle_viewed(path)
  end, { buffer = bufnr, silent = true, desc = "difit: toggle viewed" })
end

--- Get-or-create a difit-owned scratch buffer: `buftype=nofile`, `bufhidden=hide`,
--- non-modifiable once populated. Reuses an existing buffer with the exact same name
--- instead of recreating/re-populating it (buffer names always embed whatever makes
--- their content unique, so reuse is always content-safe).
---@param name string
---@param lines string[]
---@param opts { filetype: string?, entry_path: string }
---@return integer bufnr
function View:owned_buffer(name, lines, opts)
  local bufnr = find_buffer(name)
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    if opts.filetype then
      vim.bo[bufnr].filetype = opts.filetype
    end
  end
  self.owned_bufs[bufnr] = true
  apply_toggle_viewed_keymap(bufnr, opts.entry_path)
  return bufnr
end

--- Create the two-window vertical pair on first use, to the right of wherever the
--- current window is (that's "wherever the panel would be" per plan.md -- this WP only
--- ever sees the current window, WP-I positions the panel before calling into this
--- view). Subsequent calls are a no-op as long as both windows are still valid.
function View:ensure_windows()
  if
    self.left_win
    and vim.api.nvim_win_is_valid(self.left_win)
    and self.right_win
    and vim.api.nvim_win_is_valid(self.right_win)
  then
    return
  end

  local left = vim.api.nvim_get_current_win()
  local placeholder = vim.api.nvim_create_buf(false, true)
  local right = vim.api.nvim_open_win(placeholder, true, { split = "right", win = left })
  self.left_win, self.right_win = left, right
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
--- buffer when there is no base blob (added/untracked file).
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
function View:set_left(entry, spec)
  local lines = {}
  if entry.base_sha then
    lines = git.file_content(spec.repo, { sha = entry.base_sha }) or {}
  end
  local ft = vim.filetype.match({ filename = entry.path })
  local bufnr = self:owned_buffer(
    left_buffer_name(entry, spec),
    lines,
    { filetype = ft, entry_path = entry.path }
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
      NS_PREFIX .. "deleted/" .. entry.path,
      {},
      { entry_path = entry.path }
    )
    vim.api.nvim_win_set_buf(self.right_win, bufnr)
    return
  end

  local abs_path = spec.repo.toplevel .. "/" .. entry.path
  vim.api.nvim_win_call(self.right_win, function()
    vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
  end)
end

--- Populate the right window for `spec.right == "head"`: a read-only blob buffer of
--- entry.head_sha, following the same empty-scratch rule as the left side when there is
--- no blob (file doesn't exist at HEAD, i.e. deleted).
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
function View:set_right_head(entry, spec)
  local lines = {}
  if entry.head_sha then
    lines = git.file_content(spec.repo, { sha = entry.head_sha }) or {}
  end
  local ft = vim.filetype.match({ filename = entry.path })
  local bufnr = self:owned_buffer(
    right_blob_buffer_name(entry),
    lines,
    { filetype = ft, entry_path = entry.path }
  )
  vim.api.nvim_win_set_buf(self.right_win, bufnr)
end

--- Binary entries never get `diffthis`; both windows just show the same one-line
--- placeholder buffer.
---@param entry difit.FileEntry
function View:show_binary(entry)
  local bufnr = self:owned_buffer(
    NS_PREFIX .. "binary/" .. entry.path,
    { "binary file" },
    { entry_path = entry.path }
  )
  vim.api.nvim_win_set_buf(self.left_win, bufnr)
  vim.api.nvim_win_set_buf(self.right_win, bufnr)
end

--- Focus the right window and land on the first change, mirroring the plan's
--- "gg]c"-guarded-by-pcall behavior: files with no visible diff (or no 'diff' at all,
--- e.g. binary entries) must not raise.
function View:focus_right_first_change()
  vim.api.nvim_set_current_win(self.right_win)
  pcall(vim.cmd, "normal! gg]c")
end

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

--- `diffoff` where applicable, wipe every difit-owned buffer this view created. Windows
--- themselves are left alone (WP-I owns closing the tabpage/layout); a real file buffer
--- shown in the right window is never touched beyond turning its window's diff off.
function View:close()
  self:diffoff()

  -- Deleting a buffer that is the only thing a window shows makes Neovim close that
  -- window outright (`:bwipeout` semantics) as long as another window remains open --
  -- an unwanted side effect here, since this WP never closes windows itself. Swap any
  -- window still showing one of our own buffers to a fresh empty buffer first so the
  -- wipe below can't take a window down with it.
  for _, win in ipairs({ self.left_win, self.right_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if self.owned_bufs[buf] then
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
      end
    end
  end

  for bufnr in pairs(self.owned_bufs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  self.owned_bufs = {}
end

---@return difit.View
function M.new()
  return setmetatable({
    left_win = nil,
    right_win = nil,
    owned_bufs = {},
  }, View)
end

return M
