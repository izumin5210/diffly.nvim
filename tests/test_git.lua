-- Tests for lua/difit/git.lua: synchronous git plumbing (repo identity, branch/rev
-- resolution, `--raw --numstat -z` diff parsing, blob hashing/reading, hunk parsing).
-- Git is never mocked: every case drives a real repository created in a temp dir via
-- tests/helpers.lua, and cross-checks results against independently-run `git` commands
-- rather than hand-computed expectations wherever practical.

local git = require("difit.git")
local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

--- Resolve symlinks on both sides before comparing paths. On macOS `$TMPDIR` resolves
--- through a `/private` symlink, so git's (already-resolved) `--show-toplevel` output
--- can otherwise differ textually from a freshly `tempname()`d dir while still pointing
--- at the same directory (see tests/test_helpers.lua for the same pattern).
---@param path string
---@return string
local function realpath(path)
  return vim.uv.fs_realpath(path)
end

--- Write raw bytes to a repo-relative path via `io.open`, bypassing `Repo:write`: that
--- helper round-trips content through `vim.fn.writefile`, which cannot carry an
--- embedded NUL byte (Neovim marshals such a Lua string to a `Blob`, which
--- `writefile()` then rejects as a list item).
---@param repo difit.test.Repo
---@param path string
---@param bytes string
local function write_bytes(repo, path, bytes)
  local full = repo.dir .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  local fd = assert(io.open(full, "wb"))
  fd:write(bytes)
  fd:close()
end

-- 1. repo_identity() ---------------------------------------------------------------

T["repo_identity(): no remote falls back to the toplevel path"] = function()
  local repo = helpers.new_repo()

  local id, err = git.repo_identity(repo.dir)
  eq(err, nil)
  eq(realpath(id.toplevel), realpath(repo.dir))
  eq(id.id, id.toplevel)

  repo:destroy()
end

T["repo_identity(): normalizes an https remote, stripping .git"] = function()
  local repo = helpers.new_repo()
  repo:git({ "remote", "add", "origin", "https://github.com/owner/repo.git" })

  local id, err = git.repo_identity(repo.dir)
  eq(err, nil)
  eq(id.id, "github.com/owner/repo")

  repo:destroy()
end

T["repo_identity(): normalizes an scp-style ssh remote, stripping .git"] = function()
  local repo = helpers.new_repo()
  repo:git({ "remote", "add", "origin", "git@github.com:owner/repo.git" })

  local id, err = git.repo_identity(repo.dir)
  eq(err, nil)
  eq(id.id, "github.com/owner/repo")

  repo:destroy()
end

T["repo_identity(): normalizes an ssh:// remote with a port, stripping .git"] = function()
  local repo = helpers.new_repo()
  repo:git({ "remote", "add", "origin", "ssh://git@github.com:22/owner/repo.git" })

  local id, err = git.repo_identity(repo.dir)
  eq(err, nil)
  eq(id.id, "github.com/owner/repo")

  repo:destroy()
end

-- 1b. remotes() ----------------------------------------------------------------------

T["remotes(): lists every configured remote name"] = function()
  local repo = helpers.new_repo()
  repo:git({ "remote", "add", "origin", "https://example.com/owner/repo.git" })
  repo:git({ "remote", "add", "upstream", "https://example.com/upstream/repo.git" })

  local id = git.repo_identity(repo.dir)
  local remotes = git.remotes(id)
  table.sort(remotes)
  eq(remotes, { "origin", "upstream" })

  repo:destroy()
end

T["remotes(): empty list when there is no remote configured"] = function()
  local repo = helpers.new_repo()
  local id = git.repo_identity(repo.dir)
  eq(git.remotes(id), {})
  repo:destroy()
end

-- 2. default_branch() ---------------------------------------------------------------

T["default_branch(): resolves origin/HEAD set by cloning a local bare origin"] = function()
  local origin_src = helpers.new_repo()
  origin_src:write("a.txt", "hi\n")
  origin_src:commit("chore: init")

  local bare_dir = vim.fn.tempname()
  local clone_dir = vim.fn.tempname()
  eq(vim.system({ "git", "clone", "-q", "--bare", origin_src.dir, bare_dir }):wait().code, 0)
  eq(vim.system({ "git", "clone", "-q", bare_dir, clone_dir }):wait().code, 0)

  local id, err = git.repo_identity(clone_dir)
  eq(err, nil)
  eq(git.default_branch(id), "origin/main")

  origin_src:destroy()
  vim.fn.delete(bare_dir, "rf")
  vim.fn.delete(clone_dir, "rf")
end

T["default_branch(): falls back to main when there is no remote"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "hi\n")
  repo:commit("chore: init")

  local id = git.repo_identity(repo.dir)
  eq(git.default_branch(id), "main")

  repo:destroy()
end

-- 3. merge_base() --------------------------------------------------------------------

T["merge_base(): returns the fork point on the fixture repo"] = function()
  local repo = helpers.fixture_branch_repo()
  local id = git.repo_identity(repo.dir)
  local expected = vim.trim(repo:git({ "rev-parse", "main" }))

  local got, err = git.merge_base(id, "main", "feature")
  eq(err, nil)
  eq(got, expected)

  repo:destroy()
end

-- 4. diff_files(right = "head") -------------------------------------------------------

T["diff_files(): right=head reports A/M/D/R entries from the fixture"] = function()
  local repo, paths = helpers.fixture_branch_repo()
  local id = git.repo_identity(repo.dir)
  local base_sha = vim.trim(repo:git({ "rev-parse", "main" }))

  local entries, err = git.diff_files(id, base_sha, "head", { include_untracked = true })
  eq(err, nil)

  local got_paths = {}
  for _, e in ipairs(entries) do
    table.insert(got_paths, e.path)
  end
  eq(got_paths, { paths.deleted, paths.modified, paths.new, paths.renamed_to })

  local by_path = {}
  for _, e in ipairs(entries) do
    by_path[e.path] = e
  end

  --- @param rev string
  --- @param path string
  --- @return string
  local function blob_sha(rev, path)
    return vim.trim(repo:git({ "rev-parse", rev .. ":" .. path }))
  end

  local deleted = by_path[paths.deleted]
  eq(deleted.status, "D")
  eq(deleted.old_path, nil)
  eq(deleted.untracked, false)
  eq(deleted.binary, false)
  eq(deleted.additions, 0)
  eq(deleted.deletions, 7)
  eq(deleted.base_sha, blob_sha(base_sha, paths.deleted))
  eq(deleted.head_sha, nil)

  local modified = by_path[paths.modified]
  eq(modified.status, "M")
  eq(modified.old_path, nil)
  eq(modified.additions, 5)
  eq(modified.deletions, 1)
  eq(modified.base_sha, blob_sha(base_sha, paths.modified))
  eq(modified.head_sha, blob_sha("HEAD", paths.modified))

  local added = by_path[paths.new]
  eq(added.status, "A")
  eq(added.old_path, nil)
  eq(added.untracked, false)
  eq(added.additions, 7)
  eq(added.deletions, 0)
  eq(added.base_sha, nil)
  eq(added.head_sha, blob_sha("HEAD", paths.new))

  local renamed = by_path[paths.renamed_to]
  eq(renamed.status, "R")
  eq(renamed.old_path, paths.renamed_from)
  eq(renamed.additions, 4)
  eq(renamed.deletions, 0)
  eq(renamed.base_sha, blob_sha(base_sha, paths.renamed_from))
  eq(renamed.head_sha, blob_sha("HEAD", paths.renamed_to))

  repo:destroy()
end

-- 5. diff_files(right = "worktree") ---------------------------------------------------

T["diff_files(): right=worktree reports uncommitted, untracked and deleted files"] = function()
  local repo = helpers.new_repo()
  repo:write("tracked.txt", { "a", "b", "c" })
  repo:write("to_delete.txt", "bye\n")
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local base_sha = vim.trim(repo:git({ "rev-parse", "HEAD" }))

  repo:write("tracked.txt", { "a", "b", "c", "d" })
  repo:write("untracked.txt", "new content\n")
  vim.fn.delete(repo.dir .. "/to_delete.txt")

  local entries, err = git.diff_files(id, base_sha, "worktree", { include_untracked = true })
  eq(err, nil)

  local by_path = {}
  for _, e in ipairs(entries) do
    by_path[e.path] = e
  end

  eq(by_path["tracked.txt"].status, "M")
  eq(by_path["tracked.txt"].head_sha, vim.trim(repo:git({ "hash-object", "tracked.txt" })))

  eq(by_path["to_delete.txt"].status, "D")
  eq(by_path["to_delete.txt"].head_sha, nil)

  eq(by_path["untracked.txt"].status, "A")
  eq(by_path["untracked.txt"].untracked, true)
  eq(by_path["untracked.txt"].head_sha, vim.trim(repo:git({ "hash-object", "untracked.txt" })))

  local without_untracked, err2 =
    git.diff_files(id, base_sha, "worktree", { include_untracked = false })
  eq(err2, nil)
  local paths_without = {}
  for _, e in ipairs(without_untracked) do
    table.insert(paths_without, e.path)
  end
  table.sort(paths_without)
  eq(paths_without, { "to_delete.txt", "tracked.txt" })

  repo:destroy()
end

-- 6. binary files ----------------------------------------------------------------------

T["diff_files(): a binary file reports binary=true and zero counts"] = function()
  local repo = helpers.new_repo()

  write_bytes(repo, "bin.dat", "\0\1\2binary-v1")
  repo:commit("chore: add binary")

  local id = git.repo_identity(repo.dir)
  local base_sha = vim.trim(repo:git({ "rev-parse", "HEAD" }))

  write_bytes(repo, "bin.dat", "\0\1\2binary-v2-longer")
  repo:commit("feat: modify binary")

  local entries, err = git.diff_files(id, base_sha, "head", { include_untracked = true })
  eq(err, nil)
  eq(#entries, 1)
  eq(entries[1].path, "bin.dat")
  eq(entries[1].status, "M")
  eq(entries[1].binary, true)
  eq(entries[1].additions, 0)
  eq(entries[1].deletions, 0)

  repo:destroy()
end

-- 7. paths with spaces -------------------------------------------------------------------

T["diff_files(): paths with spaces round-trip through -z parsing"] = function()
  local repo = helpers.new_repo()
  -- Trailing newlines matter here: git's rename-similarity heuristic does not detect
  -- the rename below as well when either side is missing its final "\n" (both sides
  -- ended up scored under the default 50% threshold in practice), so use string
  -- content (which keeps the trailing separator) rather than a bare line table.
  repo:write("a dir/old name.txt", "one\ntwo\nthree\n")
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local base_sha = vim.trim(repo:git({ "rev-parse", "HEAD" }))

  -- Staged rename (keeps most lines, so -M still detects it) plus a further unstaged
  -- edit, and a separate untracked file -- all with spaces in their names.
  repo:git({ "mv", "a dir/old name.txt", "a dir/new name.txt" })
  repo:write("a dir/new name.txt", "one\ntwo\nthree\nfour\n")
  repo:write("another dir/untracked file.txt", "hi\n")

  local entries, err = git.diff_files(id, base_sha, "worktree", { include_untracked = true })
  eq(err, nil)

  local by_path = {}
  for _, e in ipairs(entries) do
    by_path[e.path] = e
  end

  local renamed = by_path["a dir/new name.txt"]
  eq(renamed ~= nil, true)
  eq(renamed.status, "R")
  eq(renamed.old_path, "a dir/old name.txt")
  eq(renamed.head_sha, vim.trim(repo:git({ "hash-object", "a dir/new name.txt" })))

  local untracked = by_path["another dir/untracked file.txt"]
  eq(untracked ~= nil, true)
  eq(untracked.untracked, true)
  eq(untracked.status, "A")

  repo:destroy()
end

-- 8. file_content() ----------------------------------------------------------------------

T["file_content(): by sha and by path agree for an unmodified file"] = function()
  local repo = helpers.new_repo()
  repo:write("f.txt", { "line1", "line2", "line3" })
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local sha = vim.trim(repo:git({ "rev-parse", "HEAD:f.txt" }))

  local by_sha, err1 = git.file_content(id, { sha = sha })
  eq(err1, nil)
  local by_path, err2 = git.file_content(id, { path = "f.txt" })
  eq(err2, nil)

  eq(by_sha, { "line1", "line2", "line3" })
  eq(by_path, { "line1", "line2", "line3" })
  eq(by_sha, by_path)

  repo:destroy()
end

-- 8b. blob_size() -------------------------------------------------------------------------

T["blob_size(): matches the worktree file's actual byte length"] = function()
  local repo = helpers.new_repo()
  repo:write("f.txt", { "hello", "world", "a third line" })
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local sha = vim.trim(repo:git({ "rev-parse", "HEAD:f.txt" }))
  local expected = vim.uv.fs_stat(repo.dir .. "/f.txt").size

  eq(git.blob_size(id, sha), expected)

  repo:destroy()
end

T["blob_size(): nil for a sha that doesn't resolve to an object"] = function()
  local repo = helpers.new_repo()
  local id = git.repo_identity(repo.dir)

  eq(git.blob_size(id, "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"), nil)

  repo:destroy()
end

-- 8c. check_attrs() ------------------------------------------------------------------------

T["check_attrs(): reports set/unset/false/unspecified for a committed .gitattributes"] = function()
  local repo = helpers.new_repo()
  repo:write("set.txt", "a\n")
  repo:write("unset.txt", "b\n")
  repo:write("explicit-false.txt", "c\n")
  repo:write("unspecified.txt", "d\n")
  repo:write(".gitattributes", {
    "set.txt linguist-generated",
    "unset.txt -linguist-generated",
    "explicit-false.txt linguist-generated=false",
  })
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local attrs, err = git.check_attrs(
    id,
    "linguist-generated",
    { "set.txt", "unset.txt", "explicit-false.txt", "unspecified.txt" }
  )
  eq(err, nil)
  eq(attrs["set.txt"], "set")
  eq(attrs["unset.txt"], "unset")
  eq(attrs["explicit-false.txt"], "false")
  -- "unspecified" (no matching .gitattributes rule) is represented by an ABSENT key, not
  -- the literal string "unspecified" -- callers (ui/guard.lua's M.is_generated) treat a
  -- nil lookup as "run the heuristics instead".
  eq(attrs["unspecified.txt"], nil)

  repo:destroy()
end

T["check_attrs(): an explicit custom value (e.g. linguist-generated=true) is reported verbatim"] = function()
  local repo = helpers.new_repo()
  repo:write("custom.txt", "a\n")
  repo:write(".gitattributes", { "custom.txt linguist-generated=true" })
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local attrs = git.check_attrs(id, "linguist-generated", { "custom.txt" })
  eq(attrs["custom.txt"], "true")

  repo:destroy()
end

T["check_attrs(): an UNCOMMITTED edit to .gitattributes takes effect immediately"] = function()
  local repo = helpers.new_repo()
  repo:write("f.txt", "a\n")
  repo:write(".gitattributes", { "f.txt linguist-generated" })
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  eq(git.check_attrs(id, "linguist-generated", { "f.txt" })["f.txt"], "set")

  -- Rewrite .gitattributes on disk WITHOUT committing (or even staging) the change --
  -- check-attr's default behavior (no `--cached`) reads the working tree, not the index/
  -- HEAD, so this must be visible right away. This is a deliberate divergence from
  -- upstream linguist itself, which queries the INDEX (`priority: [:index]` in its rugged
  -- source) -- documented in git.lua's own doc comment on `M.check_attrs`.
  repo:write(".gitattributes", { "f.txt -linguist-generated" })
  eq(git.check_attrs(id, "linguist-generated", { "f.txt" })["f.txt"], "unset")

  repo:destroy()
end

T["check_attrs(): a path with no .gitattributes at all is unspecified (absent key), never an error"] = function()
  local repo = helpers.new_repo()
  repo:write("f.txt", "a\n")
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local attrs, err = git.check_attrs(id, "linguist-generated", { "f.txt", "nonexistent/path.txt" })
  eq(err, nil)
  eq(attrs["f.txt"], nil)
  eq(attrs["nonexistent/path.txt"], nil)

  repo:destroy()
end

T["check_attrs(): empty paths list short-circuits to an empty table without invoking git"] = function()
  local repo = helpers.new_repo()
  local id = git.repo_identity(repo.dir)

  eq(git.check_attrs(id, "linguist-generated", {}), {})

  repo:destroy()
end

T["check_attrs(): a path with a space doesn't shift the -z token stream for its neighbors"] = function()
  -- .gitattributes patterns can't straightforwardly match a path containing a literal
  -- space (git's own pattern syntax has no clean escape for it), so this doesn't assert
  -- anything about "a dir/f.txt" itself -- it plants it BETWEEN two attributed files and
  -- checks both still report the RIGHT value, which would drift the moment `check_attrs`'s
  -- `(i - 1) * 3 + 3` token-offset arithmetic misaligned around an embedded space.
  local repo = helpers.new_repo()
  repo:write("before.txt", "a\n")
  repo:write("a dir/f.txt", "b\n")
  repo:write("after.txt", "c\n")
  repo:write(".gitattributes", { "before.txt linguist-generated", "after.txt -linguist-generated" })
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local attrs =
    git.check_attrs(id, "linguist-generated", { "before.txt", "a dir/f.txt", "after.txt" })
  eq(attrs["before.txt"], "set")
  eq(attrs["a dir/f.txt"], nil)
  eq(attrs["after.txt"], "unset")

  repo:destroy()
end

-- 9. hunks() ------------------------------------------------------------------------------

T["hunks(): modified file hunks reconstruct the new content and match git's headers"] = function()
  local repo = helpers.new_repo()
  local base_lines = {}
  for i = 1, 30 do
    base_lines[i] = tostring(i)
  end
  repo:write("big.txt", base_lines)
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local base_sha = vim.trim(repo:git({ "rev-parse", "HEAD" }))

  local new_lines = vim.deepcopy(base_lines)
  new_lines[2] = "CHANGED-2"
  new_lines[29] = "CHANGED-29"
  repo:write("big.txt", new_lines)

  local entries = git.diff_files(id, base_sha, "worktree", {})
  local entry
  for _, e in ipairs(entries) do
    if e.path == "big.txt" then
      entry = e
    end
  end
  eq(entry ~= nil, true)

  local hunks, err = git.hunks(id, entry, base_sha, "worktree")
  eq(err, nil)
  eq(#hunks, 2)

  -- Cross-check header numbers against an independently-run `git diff` invocation.
  local raw = repo:git({ "diff", "-M", "-U3", base_sha, "--", "big.txt", "big.txt" })
  local expected_headers = {}
  for header in raw:gmatch("(@@[^\n]*@@)") do
    table.insert(expected_headers, header)
  end
  eq(#expected_headers, 2)
  for i, hunk in ipairs(hunks) do
    eq(vim.startswith(hunk.header, expected_headers[i]), true)
  end

  -- Reconstruct each hunk's contribution to the new file (context + additions) and
  -- compare against the real new-file content in that region.
  local new_content = git.file_content(id, { path = "big.txt" })
  for _, hunk in ipairs(hunks) do
    local reconstructed = {}
    for _, line in ipairs(hunk.lines) do
      local marker, body = line:sub(1, 1), line:sub(2)
      if marker == " " or marker == "+" then
        table.insert(reconstructed, body)
      end
    end
    local expected_region = {}
    for i = hunk.new_start, hunk.new_start + hunk.new_count - 1 do
      table.insert(expected_region, new_content[i])
    end
    eq(reconstructed, expected_region)
  end

  repo:destroy()
end

T["hunks(): untracked file yields a single all-'+' hunk"] = function()
  local repo = helpers.new_repo()
  repo:write("placeholder.txt", "x\n")
  repo:commit("chore: base")

  local id = git.repo_identity(repo.dir)
  local base_sha = vim.trim(repo:git({ "rev-parse", "HEAD" }))

  repo:write("new_untracked.txt", "alpha\nbeta\ngamma\n")

  local entry = {
    path = "new_untracked.txt",
    old_path = nil,
    status = "A",
    untracked = true,
    binary = false,
    additions = 3,
    deletions = 0,
    base_sha = nil,
    head_sha = vim.trim(repo:git({ "hash-object", "new_untracked.txt" })),
  }

  local hunks, err = git.hunks(id, entry, base_sha, "worktree")
  eq(err, nil)
  eq(#hunks, 1)
  eq(hunks[1].header, "@@ -0,0 +1,3 @@")
  eq(#hunks[1].lines, 3)
  for _, line in ipairs(hunks[1].lines) do
    eq(line:sub(1, 1), "+")
  end
  eq(
    vim.tbl_map(function(l)
      return l:sub(2)
    end, hunks[1].lines),
    { "alpha", "beta", "gamma" }
  )

  repo:destroy()
end

return T
