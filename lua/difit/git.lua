-- Synchronous git plumbing wrapper. This is the only module that shells out to `git`;
-- every other WP consumes difit.FileEntry / difit.Hunk shapes produced here instead of
-- parsing git output itself. Every git invocation is `-C <toplevel>`-scoped so callers
-- never depend on Neovim's cwd.

local M = {}

--- Run `git -C cwd <args...>` synchronously.
---@param cwd string
---@param args string[]
---@return string|nil stdout
---@return string|nil err  -- trimmed stderr, present (possibly empty) on failure
local function run(cwd, args)
  local cmd = { "git", "-C", cwd }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or "")
  end
  return res.stdout or ""
end

--- Normalize a remote URL to "host/owner/repo": strips scheme, user, port and a
--- trailing ".git". Handles https URLs, scp-like ssh ("user@host:path") and explicit
--- "ssh://" URLs. Falls back to returning the input unchanged for anything else (e.g. a
--- local filesystem path used as a remote), which is an acceptable identity on its own.
---@param url string
---@return string
local function normalize_remote_url(url)
  url = vim.trim(url):gsub("%.git$", "")

  -- scp-like syntax: user@host:owner/repo (no scheme).
  if not url:match("^%a[%w+.%-]*://") then
    local host, path = url:match("^[%w._%-]+@([%w.%-]+):(.+)$")
    if host then
      return (host .. "/" .. path):gsub("/+$", "")
    end
  end

  -- scheme://[user@]host[:port]/path
  local rest = url:match("^%a[%w+.%-]*://(.+)$")
  if rest then
    -- Drop an optional "user@" prefix first so it can't be swallowed into the host
    -- capture below (matching greedily-then-backtracking would otherwise mis-split
    -- when there is no "@" at all in the URL).
    rest = rest:gsub("^[^@/]*@", "")
    local host, path = rest:match("^([^/:]+):?%d*(/.+)$")
    if host then
      path = path:gsub("^/+", "")
      return (host .. "/" .. path):gsub("/+$", "")
    end
  end

  return url
end

--- Split a NUL-terminated `-z` byte stream into its tokens, dropping the trailing
--- empty token produced by the final terminator (if any).
---@param s string
---@return string[]
local function split_z(s)
  local tokens = {}
  local start = 1
  while true do
    local nul = s:find("\0", start, true)
    if not nul then
      if start <= #s then
        table.insert(tokens, s:sub(start))
      end
      break
    end
    table.insert(tokens, s:sub(start, nul - 1))
    start = nul + 1
  end
  return tokens
end

---@param sha string?
---@return boolean
local function is_zero_sha(sha)
  return sha ~= nil and sha:match("^0+$") ~= nil
end

--- Strip at most one trailing newline, then split into lines. Plain `vim.split(...,
--- {trimempty = true})` would also eat a legitimate leading blank line, which this
--- avoids.
---@param text string
---@return string[]
local function split_lines(text)
  text = text:gsub("\n$", "")
  if text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

---@param text string
---@return integer
local function count_lines(text)
  if text == "" then
    return 0
  end
  local body = text:gsub("\n$", "")
  local _, n = body:gsub("\n", "")
  return n + 1
end

--- Approximate git's own binary heuristic (a NUL byte anywhere in the content) for a
--- file git does not know about yet (untracked), since `--numstat` can't tell us.
---@param full_path string
---@return boolean binary
---@return integer additions
local function classify_untracked(full_path)
  local fd = io.open(full_path, "rb")
  if not fd then
    return false, 0
  end
  local content = fd:read("*a") or ""
  fd:close()
  if content:find("\0", 1, true) then
    return true, 0
  end
  return false, count_lines(content)
end

--- Parse the combined `--raw --numstat -z` token stream into raw and numstat records,
--- correlated positionally (git emits them in the same order for both sections).
---@param tokens string[]
---@return table[]|nil raw
---@return table[]|nil numstat
---@return string|nil err
local function parse_raw_numstat_tokens(tokens)
  local raw, idx = {}, 1
  while tokens[idx] and tokens[idx]:sub(1, 1) == ":" do
    local mode_old, mode_new, sha1, sha2, status =
      tokens[idx]:match("^:(%d+) (%d+) (%x+) (%x+) (%a)%d*$")
    if not mode_old then
      return nil, nil, "unrecognized `git diff --raw` record: " .. tokens[idx]
    end
    idx = idx + 1

    local rec =
      { mode_old = mode_old, mode_new = mode_new, sha1 = sha1, sha2 = sha2, status = status }
    if status == "R" or status == "C" then
      rec.old_path = tokens[idx]
      rec.path = tokens[idx + 1]
      idx = idx + 2
    else
      rec.path = tokens[idx]
      idx = idx + 1
    end
    table.insert(raw, rec)
  end

  local numstat = {}
  while tokens[idx] do
    local added, deleted, path = tokens[idx]:match("^(%S+)\t(%S+)\t(.*)$")
    if not added then
      return nil, nil, "unrecognized `git diff --numstat` record: " .. tokens[idx]
    end
    idx = idx + 1

    local rec = { added = added, deleted = deleted }
    if path == "" then
      rec.old_path = tokens[idx]
      rec.path = tokens[idx + 1]
      idx = idx + 2
    else
      rec.path = path
    end
    table.insert(numstat, rec)
  end

  return raw, numstat
end

--- Turn correlated raw/numstat records into difit.FileEntry-shaped tables. Entries
--- whose right-hand blob sha is all-zero (unstaged worktree changes) get a `_needs_hash`
--- marker for the caller to resolve via a single batched `hash-object` call.
---@param raw table[]
---@param numstat table[]
---@return difit.FileEntry[]
local function build_entries(raw, numstat)
  local entries = {}
  for i, r in ipairs(raw) do
    local n = numstat[i]
    local binary = n.added == "-" or n.deleted == "-"

    local head_sha, needs_hash
    if r.status == "D" then
      head_sha = nil
    elseif is_zero_sha(r.sha2) then
      needs_hash = true
    else
      head_sha = r.sha2
    end

    -- NB: not `is_zero_sha(r.sha1) and nil or r.sha1` -- that idiom breaks when the
    -- "true" branch value is itself `nil`, since `x and nil` is `nil`, which is falsy,
    -- so `or r.sha1` would always win.
    local base_sha = r.sha1
    if is_zero_sha(r.sha1) then
      base_sha = nil
    end

    table.insert(entries, {
      path = r.path,
      old_path = r.old_path,
      status = r.status,
      untracked = false,
      binary = binary,
      additions = binary and 0 or (tonumber(n.added) or 0),
      deletions = binary and 0 or (tonumber(n.deleted) or 0),
      base_sha = base_sha,
      head_sha = head_sha,
      _needs_hash = needs_hash,
    })
  end
  return entries
end

--- Parse a `@@ -old_start,old_count +new_start,new_count @@ ...` header. Git omits the
--- ",count" part entirely when count == 1 (e.g. "@@ -1 +1 @@").
---@param line string
---@return integer? old_start, integer? old_count, integer? new_start, integer? new_count
local function match_hunk_header(line)
  local old_start, old_count, new_start, new_count =
    line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then
    return nil
  end
  return tonumber(old_start),
    old_count ~= "" and tonumber(old_count) or 1,
    tonumber(new_start),
    new_count ~= "" and tonumber(new_count) or 1
end

---@param diff_text string
---@return difit.Hunk[]
local function parse_hunks(diff_text)
  local hunks = {}
  local current
  for _, line in ipairs(vim.split(diff_text, "\n", { plain = true })) do
    local old_start, old_count, new_start, new_count = match_hunk_header(line)
    if old_start then
      current = {
        old_start = old_start,
        old_count = old_count,
        new_start = new_start,
        new_count = new_count,
        header = line,
        lines = {},
      }
      table.insert(hunks, current)
    elseif current then
      local marker = line:sub(1, 1)
      if marker == " " or marker == "+" or marker == "-" or marker == "\\" then
        table.insert(current.lines, line)
      end
    end
  end
  return hunks
end

--- Resolve repo identity from any path inside a git worktree.
---@param cwd string @any path inside the repo
---@return difit.RepoIdentity|nil, string|nil err
function M.repo_identity(cwd)
  local toplevel, err = run(cwd, { "rev-parse", "--show-toplevel" })
  if not toplevel then
    return nil, err
  end
  toplevel = vim.trim(toplevel)

  local git_dir
  git_dir, err = run(cwd, { "rev-parse", "--absolute-git-dir" })
  if not git_dir then
    return nil, err
  end
  git_dir = vim.trim(git_dir)

  local id
  local remote_url = run(cwd, { "remote", "get-url", "origin" })
  if remote_url and vim.trim(remote_url) ~= "" then
    id = normalize_remote_url(remote_url)
  else
    id = toplevel
  end

  return { id = id, toplevel = toplevel, git_dir = git_dir }
end

--- Resolve the remote's default branch, falling back to the first existing well-known
--- local/remote branch name.
---@param repo difit.RepoIdentity
---@return string|nil name @e.g. "origin/main"
function M.default_branch(repo)
  local out = run(repo.toplevel, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  if out then
    out = vim.trim(out)
    if out ~= "" then
      return out
    end
  end

  for _, candidate in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if run(repo.toplevel, { "rev-parse", "--verify", "--quiet", candidate }) then
      return candidate
    end
  end

  return nil
end

---@param repo difit.RepoIdentity
---@param rev string
---@return string|nil sha
---@return string|nil err
function M.rev_parse(repo, rev)
  local out, err = run(repo.toplevel, { "rev-parse", rev })
  if not out then
    return nil, err
  end
  return vim.trim(out)
end

---@param repo difit.RepoIdentity
---@param a string
---@param b string
---@return string|nil sha
---@return string|nil err
function M.merge_base(repo, a, b)
  local out, err = run(repo.toplevel, { "merge-base", a, b })
  if not out then
    return nil, err
  end
  return vim.trim(out)
end

---@param repo difit.RepoIdentity
---@return string|nil name @current branch, nil when detached
---@return string|nil err
function M.current_branch(repo)
  local out, err = run(repo.toplevel, { "branch", "--show-current" })
  if not out then
    return nil, err
  end
  out = vim.trim(out)
  if out == "" then
    return nil
  end
  return out
end

---@param repo difit.RepoIdentity
---@param base_sha string
---@param right "worktree"|"head"
---@param opts {include_untracked: boolean}?
---@return difit.FileEntry[]|nil, string|nil err
function M.diff_files(repo, base_sha, right, opts)
  opts = opts or {}

  local args = { "diff", "--raw", "--numstat", "-z", "-M", "--no-abbrev", base_sha }
  if right == "head" then
    table.insert(args, "HEAD")
  end

  local out, err = run(repo.toplevel, args)
  if not out then
    return nil, err
  end

  local raw, numstat, parse_err = parse_raw_numstat_tokens(split_z(out))
  if not raw then
    return nil, parse_err
  end
  local entries = build_entries(raw, numstat)

  -- Resolve worktree blobs left all-zero by `--raw` (unstaged edits/adds) in one batch.
  local to_hash = {}
  for _, e in ipairs(entries) do
    if e._needs_hash then
      table.insert(to_hash, e.path)
    end
  end
  if #to_hash > 0 then
    local hashes, hash_err = M.hash_objects(repo, to_hash)
    if not hashes then
      return nil, hash_err
    end
    for _, e in ipairs(entries) do
      if e._needs_hash then
        e.head_sha = hashes[e.path]
      end
    end
  end
  for _, e in ipairs(entries) do
    e._needs_hash = nil
  end

  if right == "worktree" and opts.include_untracked then
    local ls, ls_err = run(repo.toplevel, { "ls-files", "--others", "--exclude-standard", "-z" })
    if not ls then
      return nil, ls_err
    end
    local untracked_paths = split_z(ls)

    local hashes = {}
    if #untracked_paths > 0 then
      local h, hash_err = M.hash_objects(repo, untracked_paths)
      if not h then
        return nil, hash_err
      end
      hashes = h
    end

    for _, path in ipairs(untracked_paths) do
      local binary, additions = classify_untracked(repo.toplevel .. "/" .. path)
      table.insert(entries, {
        path = path,
        old_path = nil,
        status = "A",
        untracked = true,
        binary = binary,
        additions = additions,
        deletions = 0,
        base_sha = nil,
        head_sha = hashes[path],
      })
    end
  end

  table.sort(entries, function(a, b)
    return a.path < b.path
  end)

  return entries
end

---@param repo difit.RepoIdentity
---@param paths string[] @relative to toplevel
---@return table<string,string>|nil @path -> blob sha
---@return string|nil err
function M.hash_objects(repo, paths)
  if #paths == 0 then
    return {}
  end

  local input = table.concat(paths, "\n") .. "\n"
  local res = vim
    .system({ "git", "-C", repo.toplevel, "hash-object", "--stdin-paths" }, { text = true, stdin = input })
    :wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or "")
  end

  local shas = vim.split(vim.trim(res.stdout or ""), "\n", { plain = true })
  local map = {}
  for i, path in ipairs(paths) do
    map[path] = shas[i]
  end
  return map
end

---@param repo difit.RepoIdentity
---@param locator {sha: string}|{path: string}
---@return string[]|nil lines
---@return string|nil err
function M.file_content(repo, locator)
  if locator.sha then
    local out, err = run(repo.toplevel, { "cat-file", "blob", locator.sha })
    if not out then
      return nil, err
    end
    return split_lines(out)
  end

  if locator.path then
    local full = repo.toplevel .. "/" .. locator.path
    local ok, lines = pcall(vim.fn.readfile, full)
    if not ok then
      return nil, tostring(lines)
    end
    return lines
  end

  return nil, "file_content: locator needs either `sha` or `path`"
end

---@param repo difit.RepoIdentity
---@param entry difit.FileEntry
---@param base_sha string
---@param right "worktree"|"head"
---@return difit.Hunk[]|nil, string|nil err
function M.hunks(repo, entry, base_sha, right)
  local cmd = { "git", "-C", repo.toplevel, "diff" }
  local ok_codes

  if entry.untracked then
    vim.list_extend(cmd, { "--no-index", "-U3", "/dev/null", entry.path })
    -- --no-index always behaves as `--exit-code`: 1 means "diff found", not an error.
    ok_codes = { [0] = true, [1] = true }
  else
    vim.list_extend(cmd, { "-M", "-U3", base_sha })
    if right == "head" then
      table.insert(cmd, "HEAD")
    end
    vim.list_extend(cmd, { "--", entry.old_path or entry.path, entry.path })
    ok_codes = { [0] = true }
  end

  local res = vim.system(cmd, { text = true }):wait()
  if not ok_codes[res.code] then
    return nil, vim.trim(res.stderr or "")
  end

  return parse_hunks(res.stdout or "")
end

return M
