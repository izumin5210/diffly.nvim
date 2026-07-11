-- Two content-hiding placeholder guards shared by both diff views, formerly two separate
-- concerns (`ui/size_guard.lua` was renamed here once the second guard needed the exact
-- same shape): the large-file guard (config.lua's `max_file_size`) and the generated-file
-- guard (config.lua's `collapse_generated`, GitHub-parity collapsing of vendored/lockfile/
-- codegen output -- see `lua/difit/generated.lua`). Both decide whether an entry's content
-- is worth loading at all, format a placeholder message, and share the placeholder's
-- force-load `L` key (`M.apply_force_load_keymap` doesn't care which guard triggered it).
-- Kept out of ui/sidebyside.lua and ui/unified.lua themselves (mirrors ui/scratch.lua's/
-- ui/keymaps.lua's own extractions) because both views make the exact same two decisions,
-- just applied to a different set of "sides" (see `M.sidebyside_sizes`/`M.unified_sizes`
-- below) or content sources (`M.generated_check_lines`).
--
-- Never consulted for anything but the ONE entry a view is about to `open()`: no size
-- check or generated-file check ever runs for files nobody opened (config.lua's own doc
-- on `max_file_size`/`collapse_generated`). Precedence between the two guards themselves
-- (binary > size > generated) lives in each view's `open()`, not here -- see
-- docs/architecture.md's "Rendering" section.

local config = require("difit.config")
local git = require("difit.git")
local generated = require("difit.generated")

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

--- The largest of `sizes` that exceeds `limit`, or nil when none do (including when
--- `sizes` is empty -- "nothing to load on any side", not "oversized"). A single scan
--- rather than one `exceeds` call per side: "ANY consulted side over the limit" is the
--- rule (config.lua's `max_file_size` doc), and the largest offender makes the most
--- informative placeholder message when more than one side qualifies.
---
--- Walks `sizes` with `ipairs`, which stops dead at the first `nil` -- callers MUST NOT
--- leave a "nothing to load on this side" gap as a `nil` element (`ipairs({nil, 66})`
--- silently yields zero iterations, not "skip the hole and keep going"); omit that side
--- from the list entirely instead, as `M.sidebyside_sizes`/`M.unified_sizes` both do.
---@param sizes integer[]
---@param limit integer
---@return integer? largest
function M.exceeds(sizes, limit)
  local largest
  for _, size in ipairs(sizes) do
    if size > limit and (not largest or size > largest) then
      largest = size
    end
  end
  return largest
end

--- Sides `ui/sidebyside.lua` actually loads full content for: the left window always
--- shows `entry.base_sha`'s blob (when there is one), the right window either the
--- worktree file or `entry.head_sha`'s blob (when there is one) depending on
--- `spec.right`. A side with nothing to load at all (added file's empty left, deleted
--- file's empty right) is OMITTED from the returned list entirely -- never a `nil` hole in
--- the middle of it -- because `M.exceeds` walks the list with `ipairs`, which stops dead
--- at the first `nil` it meets: `ipairs({nil, 66})` yields ZERO iterations, silently
--- skipping a legitimately oversized right side whenever the left side happens to be the
--- one that's absent (e.g. any oversized ADDED file). Building the list with `table.insert`
--- rather than a `{ left, right }` literal is what avoids ever constructing that hole.
---@param repo difit.RepoIdentity
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return integer[]
function M.sidebyside_sizes(repo, entry, spec)
  local sizes = {}
  local left = M.blob_size(repo, entry.base_sha)
  if left then
    table.insert(sizes, left)
  end
  if entry.head_sha then
    local right = spec.right == "worktree"
        and M.worktree_size(vim.fs.joinpath(repo.toplevel, entry.path))
      or M.blob_size(repo, entry.head_sha)
    if right then
      table.insert(sizes, right)
    end
  end
  return sizes
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
--- Same "never a `nil` hole" contract as `M.sidebyside_sizes` above -- a side with nothing
--- to load (e.g. a deleted file with no `base_sha` either, vanishingly rare but possible)
--- is omitted rather than included as `nil`.
---@param repo difit.RepoIdentity
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return integer[]
function M.unified_sizes(repo, entry, spec)
  local size
  if not entry.head_sha then
    size = M.blob_size(repo, entry.base_sha)
  elseif spec.right == "worktree" then
    size = M.worktree_size(vim.fs.joinpath(repo.toplevel, entry.path))
  else
    size = M.blob_size(repo, entry.head_sha)
  end
  return size and { size } or {}
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

--- The generated-file placeholder's sole line of text -- unlike `M.message`, this one
--- never varies per entry (no size/limit to report), so it's a plain constant rather than
--- a formatter.
---@return string
function M.generated_message()
  return "Generated files are not rendered by default -- press L to load"
end

--- Which content to run `generated.lua`'s heuristics against for `entry` in `spec`: the
--- side the view is about to render as the file's "current" content -- the worktree file
--- or `entry.head_sha`'s blob, or `entry.base_sha`'s blob when the file was deleted (no
--- head side to speak of). This is difit's OWN decision, not linguist's or GitHub's:
--- linguist classifies a single blob at a time (no diff/side concept at all), and GitHub's
--- own choice of which side of a PR diff it runs its collapsing heuristics against isn't
--- documented or observable. One side is picked (not run separately per side, the way the
--- size guard's `M.sidebyside_sizes` does) because "generated" is a single yes/no per
--- entry -- sidebyside would otherwise need to reconcile two independent verdicts for its
--- two windows.
---@param repo difit.RepoIdentity
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return string[]? lines
function M.generated_check_lines(repo, entry, spec)
  if not entry.head_sha then
    if not entry.base_sha then
      return {}
    end
    return git.file_content(repo, { sha = entry.base_sha })
  end
  if spec.right == "worktree" then
    return git.file_content(repo, { path = entry.path })
  end
  return git.file_content(repo, { sha = entry.head_sha })
end

--- Is `entry` a generated file, per GitHub-parity precedence (docs/architecture.md
--- "Rendering"): `config.collapse_generated == false` short-circuits to "never" (no
--- `.gitattributes` lookup, no content read -- the whole feature is off); otherwise
--- `spec.generated_attrs[entry.path]` (the session's batched `git check-attr
--- linguist-generated` result, see `session.lua`) wins BOTH ways when present -- "unset"/
--- "false" forces "not generated" and skips heuristics entirely, anything else present
--- forces "generated" without even reading content; only when the attribute is
--- unspecified (`spec.generated_attrs[entry.path] == nil`) do the `generated.lua`
--- heuristics run, against `M.generated_check_lines`'s content. A content read that fails
--- (a real git/fs failure, not "nothing to load") degrades to "not generated" here without
--- notifying -- the normal render path this entry falls through to on a `false` verdict
--- will attempt the exact same read and notify once there, so notifying here too would be
--- a duplicate.
---@param repo difit.RepoIdentity
---@param entry difit.FileEntry
---@param spec difit.DiffSpec
---@return boolean
function M.is_generated(repo, entry, spec)
  if not config.get().collapse_generated then
    return false
  end

  local attrs = spec.generated_attrs or {}
  local raw = attrs[entry.path]
  if raw ~= nil then
    return raw ~= "unset" and raw ~= "false"
  end

  local lines = M.generated_check_lines(repo, entry, spec)
  if not lines then
    return false
  end
  return generated.generated(entry.path, lines)
end

--- Apply the placeholder's force-load `L` key to `bufnr`: buffer-local and `nowait` (same
--- convention as every other difit keymap -- CLAUDE.md's invariants), adds `entry.path`
--- to `view.force_loaded` (a set that lives on the view instance itself -- resets on a
--- mode switch/close along with the rest of the view's per-open state, deliberately never
--- persisted), then re-runs `view:open(entry, spec)` -- the exact same entry point every
--- other transition already goes through, so a force-loaded entry renders through the
--- normal (now-unguarded) path rather than a special one. Shared verbatim by both guards:
--- `view.force_loaded` doesn't distinguish which one showed the placeholder, so forcing
--- past either also bypasses the other for the rest of this view instance's lifetime (see
--- both views' `open()`).
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
