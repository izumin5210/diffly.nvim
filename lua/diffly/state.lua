-- Viewed-state persistence (design.md "Viewed state"). One JSON file per review key
-- under `vim.fn.stdpath('data')/diffly`, keyed by a hash of the review key so state is
-- shared across worktrees/clones of the same repo but never carried over to a different
-- PR or branch pair. Marking a file viewed records the (base blob sha, head blob sha)
-- pair at mark time; `is_viewed` re-checks that pair against the current entry so new
-- commits invalidate the mark (GitHub-style) while untouched files stay viewed.

local M = {}

--- Test seam: overrides the state directory (normally
--- `vim.fn.stdpath('data') .. '/diffly'`) when set. Only ever assigned by tests; this is
--- filesystem location, not behavior, so it is safe to poke from outside.
---@type string?
M._dir = nil

--- Test seam: overrides the pre-rename (difit.nvim) state directory that the one-time
--- migration below looks for. Only ever assigned by tests, same rationale as `M._dir`.
---@type string?
M._legacy_dir = nil

--- Test seam: whether the legacy-dir migration has already run. Tests reset this
--- alongside `M._dir`/`M._legacy_dir` so each case gets its own migration attempt instead
--- of sharing the real run from module load.
---@type boolean
M._migrated = false

---@return string
local function legacy_dir()
  return M._legacy_dir or (vim.fn.stdpath("data") .. "/difit")
end

--- One-time migration from the plugin's pre-rename (difit.nvim) state directory: moves it
--- wholesale to the new location so existing `viewed` marks survive the rename instead of
--- silently resetting. Only fires when the new directory doesn't exist yet -- an existing
--- new directory means either migration already happened or the user is already on
--- diffly.nvim -- and never raises: a failed rename (cross-device, permissions, ...) just
--- falls through to the (now-empty) new directory. Runs at most once per session, gated
--- lazily behind `state_dir()` rather than at require time, so the test seams above can
--- redirect both paths before it ever runs.
---@param new string
local function migrate_legacy_dir_once(new)
  if M._migrated then
    return
  end
  M._migrated = true

  local old = legacy_dir()
  if old == new or not vim.uv.fs_stat(old) or vim.uv.fs_stat(new) then
    return
  end
  pcall(vim.uv.fs_rename, old, new)
end

---@return string
local function state_dir()
  local dir = M._dir or (vim.fn.stdpath("data") .. "/diffly")
  migrate_legacy_dir_once(dir)
  return dir
end

---@param key diffly.ReviewKey
---@return string @absolute path of the state file for this review key
function M.file_path(key)
  local suffix
  if key.kind == "pr" then
    suffix = tostring(key.pr_number)
  else
    suffix = key.base .. "\0" .. key.head
  end
  local hash = vim.fn.sha256(key.kind .. "\0" .. key.repo .. "\0" .. suffix)
  return state_dir() .. "/" .. hash .. ".json"
end

---@param key diffly.ReviewKey
---@return diffly.ReviewState
function M.load(key)
  local path = M.file_path(key)
  local fresh = { version = 1, key = key, viewed = {}, comments = {}, comment_seq = 0 }

  local f = io.open(path, "r")
  if not f then
    return fresh
  end
  local content = f:read("*a")
  f:close()

  -- luanil.object turns JSON `null` into a plain Lua `nil`, so an absent base_sha/
  -- head_sha in a viewed record round-trips as a genuinely absent table key, matching
  -- the in-memory ViewedRecord shape used everywhere else.
  local ok, decoded = pcall(vim.json.decode, content, { luanil = { object = true } })
  if not ok or type(decoded) ~= "table" then
    vim.notify(
      string.format("diffly: ignoring corrupt state file %s (%s)", path, decoded),
      vim.log.levels.WARN
    )
    return fresh
  end

  decoded.version = decoded.version or 1
  decoded.key = decoded.key or key
  decoded.viewed = decoded.viewed or {}
  -- Comment fields arrived after the first release; state files written before them (or
  -- by it) must load with the same shape a fresh state has.
  decoded.comments = decoded.comments or {}
  decoded.comment_seq = decoded.comment_seq or 0
  return decoded
end

---@param st diffly.ReviewState
function M.save(st)
  st.last_opened = os.date("!%Y-%m-%dT%H:%M:%SZ")

  vim.fn.mkdir(state_dir(), "p")

  local path = M.file_path(st.key)
  local tmp_path = path .. ".tmp"

  local f = assert(io.open(tmp_path, "w"))
  f:write(vim.json.encode(st))
  f:close()

  -- `os.rename` maps to plain `rename(2)` on POSIX but to `MoveFileEx` *without*
  -- `MOVEFILE_REPLACE_EXISTING` on Windows, so it fails with EEXIST there the moment the
  -- destination already exists (i.e. every save after the first one). `vim.uv.fs_rename`
  -- (libuv) requests the replace-existing flag on Windows too, so this is atomic
  -- everywhere.
  local ok, err = vim.uv.fs_rename(tmp_path, path)
  if not ok then
    error(string.format("diffly: failed to save state to %s: %s", path, err or "unknown error"))
  end
end

---@param st diffly.ReviewState
---@param entry diffly.FileEntry
function M.mark(st, entry)
  st.viewed[entry.path] = {
    base_sha = entry.base_sha,
    head_sha = entry.head_sha,
    marked_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
end

---@param st diffly.ReviewState
---@param path string
function M.unmark(st, path)
  st.viewed[path] = nil
end

---@param st diffly.ReviewState
---@param entry diffly.FileEntry
---@return boolean
function M.is_viewed(st, entry)
  local record = st.viewed[entry.path]
  if not record then
    return false
  end
  -- Plain `==` already treats nil == nil as equal, which is exactly "absent on both
  -- sides counts as a match" for added/deleted files.
  return record.base_sha == entry.base_sha and record.head_sha == entry.head_sha
end

---@param opts {all: boolean?, key: diffly.ReviewKey?}
---@return integer removed
function M.clean(opts)
  opts = opts or {}

  if opts.key then
    return vim.fn.delete(M.file_path(opts.key)) == 0 and 1 or 0
  end

  if opts.all then
    local removed = 0
    for _, path in ipairs(vim.fn.glob(state_dir() .. "/*.json", true, true)) do
      if vim.fn.delete(path) == 0 then
        removed = removed + 1
      end
    end
    return removed
  end

  return 0
end

return M
