-- Large-file guard shared by both diff views (config.lua's `max_file_size`): decides
-- whether an entry's content is worth loading at all, formats the placeholder message,
-- and wires the placeholder's force-load `L` key. Kept out of ui/sidebyside.lua and
-- ui/unified.lua themselves (mirrors ui/scratch.lua's/ui/keymaps.lua's own extractions)
-- because both views need the exact same decision, just applied to a different set of
-- "sides" (see `M.sidebyside_sizes`/`M.unified_sizes` below).
--
-- Never consulted for anything but the ONE entry a view is about to `open()`: no size
-- check ever runs for files nobody opened (config.lua's own doc on `max_file_size`).

local config = require("difit.config")
local git = require("difit.git")

local M = {}

--- `config.max_file_size`, or nil when the guard is disabled (`false`) -- callers treat a
--- nil limit as "never oversized", short-circuiting before any size lookup at all.
---@return integer?
function M.limit()
  local max = config.get().max_file_size
  if max == false then
    return nil
  end
  return max
end

--- Byte size of a worktree file via `vim.uv.fs_stat` -- the worktree-side counterpart to
--- `git.blob_size` (a worktree file has no blob sha to `cat-file -s` until it's staged).
--- nil for a path that doesn't exist (already-deleted-on-disk edge cases some caller
--- didn't already filter out) rather than raising.
---@param abs_path string
---@return integer? size
function M.worktree_size(abs_path)
  local stat = vim.uv.fs_stat(abs_path)
  return stat and stat.size or nil
end

--- nil-safe wrapper around `git.blob_size`: a nil `sha` (nothing to load on that side,
--- e.g. an added file's empty base) stays nil instead of every call site re-deriving the
--- same guard.
---@param repo difit.RepoIdentity
---@param sha string?
---@return integer? size
function M.blob_size(repo, sha)
  if not sha then
    return nil
  end
  return git.blob_size(repo, sha)
end

--- The largest of `sizes` that exceeds `limit`, or nil when none do (including when every
--- element is nil -- "nothing to load on that side", not "oversized"). A single scan
--- rather than one `exceeds` call per side: "ANY consulted side over the limit" is the
--- rule (config.lua's `max_file_size` doc), and the largest offender makes the most
--- informative placeholder message when more than one side qualifies.
---@param sizes (integer|nil)[]
---@param limit integer
---@return integer? largest
function M.exceeds(sizes, limit)
  local largest
  for _, size in ipairs(sizes) do
    if size and size > limit and (not largest or size > largest) then
      largest = size
    end
  end
  return largest
end

--- Sides `ui/sidebyside.lua` actually loads full content for: the left window always
--- shows `entry.base_sha`'s blob (when there is one), the right window either the
--- worktree file or `entry.head_sha`'s blob (when there is one) depending on
--- `spec.right`. A nil element means that side has nothing to load at all (added file's
--- empty left, deleted file's empty right) -- `M.exceeds` already treats that as "not
--- consulted", not "not oversized".
---@param repo difit.RepoIdentity
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return (integer|nil)[]
function M.sidebyside_sizes(repo, entry, spec)
  local left = M.blob_size(repo, entry.base_sha)
  local right
  if entry.head_sha then
    right = spec.right == "worktree" and M.worktree_size(vim.fs.joinpath(repo.toplevel, entry.path))
      or M.blob_size(repo, entry.head_sha)
  end
  return { left, right }
end

--- The one side `ui/unified.lua` actually loads full content for: `entry.base_sha`'s
--- blob for a deleted file (its own `show_deleted` renders that blob whole, painted as
--- deleted -- the only case this view loads the base side at all), otherwise the same
--- worktree-file-or-`entry.head_sha`-blob choice sidebyside's right side makes.
---
--- Deliberately excludes the base blob in the non-deleted case: unified only ever feeds
--- it to `git diff` there (to compute hunks for the overlay), never loads it whole into a
--- buffer -- and hunk output is proportional to the actual diff, not to the file's full
--- size, so a huge base file behind a small diff needs no guard.
---@param repo difit.RepoIdentity
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return (integer|nil)[]
function M.unified_sizes(repo, entry, spec)
  if not entry.head_sha then
    return { M.blob_size(repo, entry.base_sha) }
  end
  if spec.right == "worktree" then
    return { M.worktree_size(vim.fs.joinpath(repo.toplevel, entry.path)) }
  end
  return { M.blob_size(repo, entry.head_sha) }
end

--- Human-readable byte count: B/KiB/MiB/GiB (binary, 1024-based), switching units by
--- magnitude with one decimal place once past B -- so a tiny test-configured
--- `max_file_size` (a handful of bytes) still reads sensibly instead of always rounding
--- to "0.0 MiB", while the default-sized (1 MiB+) case reads exactly like the design's
--- own example message ("2.3 MiB > 1.0 MiB").
---@param bytes integer
---@return string
function M.format(bytes)
  local units = { "KiB", "MiB", "GiB" }
  if bytes < 1024 then
    return string.format("%d B", bytes)
  end
  local value = bytes / 1024
  for i = 1, #units - 1 do
    if value < 1024 then
      return string.format("%.1f %s", value, units[i])
    end
    value = value / 1024
  end
  return string.format("%.1f %s", value, units[#units])
end

--- The placeholder buffer's sole line of text.
---@param actual integer  -- bytes, the largest oversized side (see `M.exceeds`)
---@param limit integer   -- bytes, `config.max_file_size`
---@return string
function M.message(actual, limit)
  return string.format(
    "file too large (%s > %s) -- press L to load",
    M.format(actual),
    M.format(limit)
  )
end

--- Apply the placeholder's force-load `L` key to `bufnr`: buffer-local and `nowait` (same
--- convention as every other difit keymap -- CLAUDE.md's invariants), adds `entry.path`
--- to `view.force_loaded` (a set that lives on the view instance itself -- resets on a
--- mode switch/close along with the rest of the view's per-open state, deliberately never
--- persisted), then re-runs `view:open(entry, spec)` -- the exact same entry point every
--- other transition already goes through, so a force-loaded entry renders through the
--- normal (now-unguarded) path rather than a special one.
---@param bufnr integer
---@param view difit.View  -- must also expose `force_loaded` (both views do)
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
function M.apply_force_load_keymap(bufnr, view, entry, spec)
  vim.keymap.set("n", "L", function()
    view.force_loaded[entry.path] = true
    view:open(entry, spec)
  end, { buffer = bufnr, nowait = true, silent = true, desc = "difit: force-load oversized file" })
end

return M
