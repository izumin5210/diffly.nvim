-- Viewed-state persistence (design.md "Viewed state"). One JSON file per review key
-- under `vim.fn.stdpath('data')/difit`, keyed by a hash of the review key so state is
-- shared across worktrees/clones of the same repo but never carried over to a different
-- PR or branch pair. Marking a file viewed records the (base blob sha, head blob sha)
-- pair at mark time; `is_viewed` re-checks that pair against the current entry so new
-- commits invalidate the mark (GitHub-style) while untouched files stay viewed.

local M = {}

--- Test seam: overrides the state directory (normally
--- `vim.fn.stdpath('data') .. '/difit'`) when set. Only ever assigned by tests; this is
--- filesystem location, not behavior, so it is safe to poke from outside.
---@type string?
M._dir = nil

---@return string
local function state_dir()
  return M._dir or (vim.fn.stdpath("data") .. "/difit")
end

---@param key difit.ReviewKey
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

---@param key difit.ReviewKey
---@return difit.ReviewState
function M.load(key)
  local path = M.file_path(key)
  local fresh = { version = 1, key = key, viewed = {} }

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
      string.format("difit: ignoring corrupt state file %s (%s)", path, decoded),
      vim.log.levels.WARN
    )
    return fresh
  end

  decoded.version = decoded.version or 1
  decoded.key = decoded.key or key
  decoded.viewed = decoded.viewed or {}
  return decoded
end

---@param st difit.ReviewState
function M.save(st)
  st.last_opened = os.date("!%Y-%m-%dT%H:%M:%SZ")

  vim.fn.mkdir(state_dir(), "p")

  local path = M.file_path(st.key)
  local tmp_path = path .. ".tmp"

  local f = assert(io.open(tmp_path, "w"))
  f:write(vim.json.encode(st))
  f:close()

  local ok, err = os.rename(tmp_path, path)
  if not ok then
    error(string.format("difit: failed to save state to %s: %s", path, err or "unknown error"))
  end
end

---@param st difit.ReviewState
---@param entry difit.FileEntry
function M.mark(st, entry)
  st.viewed[entry.path] = {
    base_sha = entry.base_sha,
    head_sha = entry.head_sha,
    marked_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
end

---@param st difit.ReviewState
---@param path string
function M.unmark(st, path)
  st.viewed[path] = nil
end

---@param st difit.ReviewState
---@param entry difit.FileEntry
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

---@param opts {all: boolean?, key: difit.ReviewKey?}
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
