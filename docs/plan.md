# difit.nvim — v1 Implementation Plan

Companion to [design.md](./design.md). This plan is written so that each work package (WP)
can be implemented by an independent agent with no coordination beyond this document.
Interface contracts here are **binding**: implement exactly these signatures and shapes.
If a contract turns out to be impossible or clearly wrong, stop and report back instead of
improvising a different interface.

## Ground rules for implementers

- TDD: write a failing test first, then the minimal implementation, then refactor.
- Never mock git. Tests create real repositories in temp directories via `tests/helpers.lua`.
  Only `gh` is faked (PATH shim script; see WP-D).
- Zero runtime dependencies. Allowed APIs: `vim.system`, `vim.uv`, `vim.json`, `vim.fs`,
  `vim.fn`, `vim.api`. Target Neovim 0.12+.
- All git invocations use `git -C <toplevel> ...` (never rely on cwd) via
  `vim.system(cmd, { text = true }):wait()`. On non-zero exit, return `nil, stderr`.
- Every public function gets LuaCATS annotations. Shared types live in
  `lua/difit/types.lua` (a `---@meta` file, never `require`d).
- Style: `stylua` (config at repo root). Run `make lint` before finishing.
- **Only create/modify files owned by your WP** (see ownership table). Do not `git commit`,
  do not create branches — the orchestrator handles git.
- Run your own tests with `make test FILE=tests/test_<yours>.lua`. The full suite may be
  red while other WPs are in flight; that is not yours to fix.
- Comments: document *why*, not *what*. English identifiers, comments, and test names.

## File ownership

| WP | Owns |
|----|------|
| 0  | `Makefile`, `stylua.toml`, `.github/workflows/ci.yml`, `tests/minimal_init.lua`, `tests/helpers.lua`, `lua/difit/types.lua`, `lua/difit/config.lua`, `.gitignore` (append) |
| A  | `lua/difit/git.lua`, `tests/test_git.lua` |
| B  | `lua/difit/state.lua`, `tests/test_state.lua` |
| C  | `lua/difit/tree.lua`, `tests/test_tree.lua` |
| D  | `lua/difit/github.lua`, `tests/test_github.lua` |
| E  | `lua/difit/session.lua`, `tests/test_session.lua` |
| F  | `lua/difit/ui/sidebyside.lua`, `tests/test_sidebyside.lua` |
| G  | `lua/difit/ui/unified.lua`, `tests/test_unified.lua` |
| H  | `lua/difit/ui/panel.lua`, `lua/difit/ui/hl.lua`, `tests/test_panel.lua` |
| I  | `lua/difit/init.lua`, `plugin/difit.lua`, `doc/difit.txt`, `README.md`, `tests/test_e2e.lua`, `tests/screenshots/` |

Dependency graph (`→` = depends on):

```
0 → (A, B, C, D) → (E, F, G, H) → I
```

A–D are mutually independent; E–H are mutually independent (E is contract-coupled to
A/B/D; H is contract-coupled to E via the session interface, tested with a fake).

---

## Shared type contracts (`lua/difit/types.lua`)

```lua
---@meta

---@class difit.RepoIdentity
---@field id string        -- normalized remote URL ("github.com/owner/repo") or toplevel path
---@field toplevel string  -- absolute path of the worktree root
---@field git_dir string   -- absolute path of the .git dir

---@class difit.ReviewKey
---@field kind "pr"|"branch"
---@field repo string           -- RepoIdentity.id
---@field pr_number integer?    -- kind == "pr"
---@field base string?          -- kind == "branch": base branch name
---@field head string?          -- kind == "branch": head branch name

---@class difit.DiffSpec
---@field repo difit.RepoIdentity
---@field base_ref string    -- resolved base ref, e.g. "origin/main"
---@field merge_base string  -- merge-base commit SHA (left side of every diff)
---@field right "worktree"|"head"
---@field review_key difit.ReviewKey

---@class difit.FileEntry
---@field path string          -- current path, relative to toplevel
---@field old_path string?     -- set for renames
---@field status "A"|"M"|"D"|"R"
---@field untracked boolean    -- true for files not yet known to git (status "A")
---@field binary boolean
---@field additions integer    -- 0 when binary
---@field deletions integer    -- 0 when binary
---@field base_sha string?     -- blob SHA at merge-base; nil when added/untracked
---@field head_sha string?     -- blob SHA of right side; nil when deleted

---@class difit.Hunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field header string    -- full "@@ ... @@ ..." line
---@field lines string[]   -- body lines incl. leading " ", "+", "-", "\" markers

---@class difit.ViewedRecord
---@field base_sha string|vim.NIL  -- vim.NIL encodes "no base blob" (added file) in JSON
---@field head_sha string|vim.NIL
---@field marked_at string         -- ISO8601 UTC

---@class difit.ReviewState
---@field version integer
---@field key difit.ReviewKey
---@field last_opened string
---@field viewed table<string, difit.ViewedRecord>  -- keyed by FileEntry.path
```

`vim.NIL` note: `base_sha`/`head_sha` may legitimately be absent (added/deleted files).
In-memory, use plain `nil` inside `ViewedRecord`-shaped tables and compare with a helper
that treats `nil == nil` as a match; on JSON round-trip absent keys simply stay absent.

---

## WP-0 — Scaffolding

**`stylua.toml`**: `indent_type = "Spaces"`, `indent_width = 2`, `column_width = 100`.

**`Makefile`** targets:
- `deps`: clone `https://github.com/echasnovski/mini.nvim` (depth 1) into `deps/mini.nvim`
  unless present.
- `test`: `nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"`.
  With `FILE=...`: `-c "lua MiniTest.run_file('$(FILE)')"`.
- `lint`: `stylua --check lua tests`.
- `fmt`: `stylua lua tests`.

**`tests/minimal_init.lua`**: prepend repo root and `deps/mini.nvim` to `runtimepath`;
`require('mini.test').setup()`.

**`tests/helpers.lua`** public API (used by every other WP; implement precisely):

```lua
local helpers = {}

-- Fresh repo in a new temp dir. Runs `git init -b main`, sets user.name/email locally,
-- disables gpg signing and hooks (core.hooksPath=/dev/null on POSIX is fine to skip; just
-- ensure commits work in CI). Returns a repo handle.
---@return difit.test.Repo
function helpers.new_repo() end

---@class difit.test.Repo
---@field dir string  -- toplevel
local Repo = {}
function Repo:git(args) end          -- run git -C dir <args...>, error on failure, return stdout
function Repo:write(path, content) end  -- create dirs as needed; content: string|string[]
function Repo:commit(msg) end        -- git add -A && git commit -m msg
function Repo:branch(name) end       -- git switch -c name
function Repo:destroy() end          -- recursive delete (best effort)

-- Standard fixture used by many WPs: main with two commits, branch "feature" off main
-- with commits that add src/new.lua, modify src/mod.lua (also modified differently is NOT
-- needed), delete src/gone.lua, and rename src/old_name.lua -> src/renamed.lua (content
-- >50% identical so -M detects it). Returns repo, plus a table of the involved paths.
function helpers.fixture_branch_repo() end

-- Child-process Neovim via MiniTest.new_child_neovim, restarted with tests/minimal_init.lua
-- and cwd set to `dir`. Returns the child.
function helpers.new_child(dir) end

-- Prepend a temp dir to PATH containing an executable shell script named `name` with
-- `body` (sh script text). Returns a function that removes it from PATH again.
function helpers.path_shim(name, body) end
```

**`lua/difit/config.lua`**:

```lua
local M = {}

M.defaults = {
  base = nil,                -- string|nil: base branch override
  right = "worktree",        -- "worktree"|"head"
  include_untracked = true,
  auto_advance = true,       -- jump to next un-viewed file after marking
  icons = true,              -- use mini.icons / nvim-web-devicons when available
  panel = { width = 35 },
  keymaps = {
    panel = {
      open = "<CR>",         -- open file diff / toggle dir fold when on a dir row
      toggle_viewed = "v",
      refresh = "R",
      toggle_mode = "s",     -- side-by-side <-> unified
      close = "q",
      fold = "za",
    },
    -- applied ONLY in difit-owned buffers (blob/unified), never in real file buffers
    diff = { toggle_viewed = "v" },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)  -- deep-extend force into M.options
function M.get()        -- returns M.options
return M
```

Any keymap value set to `false` disables that mapping.

**`.github/workflows/ci.yml`**: on push/PR. Jobs: `lint` (stylua-action, `--check lua tests`),
`test` (matrix: neovim `stable`, `nightly`; use `rhysd/action-setup-vim` with `neovim: true`;
run `make deps && make test`).

**`.gitignore`**: append `deps/`.

**Acceptance**: `make deps && make test` passes with one trivial smoke test
(`tests/test_helpers.lua` may be added by WP-0 to validate helpers: fixture repo produces
expected `git status` etc. — this file is WP-0-owned as an exception).

---

## WP-A — `lua/difit/git.lua`

Synchronous git plumbing. Public API:

```lua
---@param cwd string @any path inside the repo
---@return difit.RepoIdentity|nil, string|nil err
function M.repo_identity(cwd)
-- toplevel: `git rev-parse --show-toplevel`; git_dir: `--absolute-git-dir`.
-- id: `git remote get-url origin` normalized; when no origin remote → id = toplevel.
-- Normalization: "https://host/owner/repo(.git)" | "git@host:owner/repo(.git)"
--   | "ssh://git@host(:port)?/owner/repo(.git)" → "host/owner/repo" (strip trailing "/").

---@return string|nil name @e.g. "origin/main"
function M.default_branch(repo)
-- `git symbolic-ref --short refs/remotes/origin/HEAD` → e.g. "origin/main".
-- Fallback: first existing of origin/main, origin/master, main, master
--   (check with `git rev-parse --verify --quiet <ref>`).

---@return string|nil sha
function M.rev_parse(repo, rev)

---@return string|nil sha
function M.merge_base(repo, a, b)

---@return string|nil name @current branch, nil when detached
function M.current_branch(repo)  -- `git branch --show-current`

---@param base_sha string
---@param right "worktree"|"head"
---@param opts {include_untracked: boolean}
---@return difit.FileEntry[]|nil, string|nil err
function M.diff_files(repo, base_sha, right, opts)
-- right == "head":     `git diff --raw --numstat -z -M <base_sha> HEAD`
-- right == "worktree": `git diff --raw --numstat -z -M <base_sha>`
--   plus untracked via `git ls-files --others --exclude-standard -z` (status "A",
--   untracked=true) when opts.include_untracked.
-- Parse the -z stream: all --raw records come first, then all --numstat records.
--   raw:      ":mode mode sha1 sha2 STATUS\0path\0" (renames: "R<score>\0old\0new\0")
--   numstat:  "add\tdel\t\0old\0new\0" for renames, "add\tdel\tpath\0" otherwise;
--   binary files report "-\t-" → binary=true, additions/deletions=0.
-- base_sha/head_sha from the raw record; an all-zero SHA means "not a real blob":
--   * left all-zero → base_sha = nil (added)
--   * right all-zero (worktree diffs) → compute via hash_objects for existing files,
--     nil for deleted files.
-- Sort result by path.

---@param paths string[] @relative to toplevel
---@return table<string,string>|nil @path → blob sha
function M.hash_objects(repo, paths)
-- `git hash-object --stdin-paths` with newline-joined paths on stdin (run from toplevel).

---@param locator {sha: string}|{path: string}
---@return string[]|nil lines
function M.file_content(repo, locator)
-- {sha=...}: `git cat-file blob <sha>`; {path=...}: read the worktree file (vim.fn.readfile
-- equivalent via io). Returns lines without trailing newline artifacts.

---@param entry difit.FileEntry
---@param base_sha string
---@param right "worktree"|"head"
---@return difit.Hunk[]|nil, string|nil err
function M.hunks(repo, entry, base_sha, right)
-- `git diff -M -U3 <base_sha> [HEAD] -- <old_path or path> <path>`; untracked files:
-- `git diff --no-index /dev/null <path>` (exit code 1 is success for --no-index).
-- Parse @@ headers into difit.Hunk.
```

**Tests** (`tests/test_git.lua`, using `helpers.fixture_branch_repo` and purpose-built repos):

1. `repo_identity`: https remote, ssh scp-style remote, `ssh://` remote, no-remote fallback
   to toplevel; `.git` suffix stripped.
2. `default_branch`: with `origin/HEAD` set (use a local bare clone as origin); fallback to
   `main` when no remote.
3. `merge_base` returns the fork point on the fixture repo.
4. `diff_files` (right=head): fixture yields A/M/D/R entries with correct paths, old_path
   for the rename, correct additions/deletions, base_sha/head_sha match
   `git rev-parse <rev>:<path>`.
5. `diff_files` (right=worktree): uncommitted edit appears; its head_sha equals
   `git hash-object` of the file; untracked file appears with untracked=true and is absent
   when include_untracked=false; deleted-in-worktree file has head_sha=nil.
6. Binary file (write bytes with a NUL) → binary=true, counts 0.
7. Paths with spaces round-trip correctly (the -z parsing test).
8. `file_content` by sha and by path agree for an unmodified file.
9. `hunks`: modified file yields hunks whose reconstructed "+"-lines equal the new file
   content in the changed region; untracked file yields one all-"+" hunk; header numbers
   match `git diff` raw output.

---

## WP-B — `lua/difit/state.lua`

Viewed-state persistence under `vim.fn.stdpath('data') .. '/difit'`.

```lua
---@param key difit.ReviewKey
---@return string @absolute path of the state file
function M.file_path(key)
-- filename: vim.fn.sha256(key.kind .. "\0" .. key.repo .. "\0" .. suffix) .. ".json"
-- where suffix = tostring(pr_number) for "pr", base .. "\0" .. head for "branch".

---@return difit.ReviewState
function M.load(key)
-- Missing file → fresh state {version=1, key=key, viewed={}}.
-- Corrupt JSON → vim.notify(WARN) once, fresh state (do not delete the old file).

---@param st difit.ReviewState
function M.save(st)
-- Sets last_opened = now (ISO8601 UTC, os.date("!%Y-%m-%dT%H:%M:%SZ")).
-- mkdir -p the dir; atomic write: write to "<path>.tmp" then os.rename.

---@param st difit.ReviewState
---@param entry difit.FileEntry
function M.mark(st, entry)      -- records {base_sha, head_sha, marked_at} under entry.path

function M.unmark(st, path)

---@param st difit.ReviewState
---@param entry difit.FileEntry
---@return boolean
function M.is_viewed(st, entry)
-- true iff a record exists for entry.path AND record.base_sha == entry.base_sha AND
-- record.head_sha == entry.head_sha, where nil/absent on both sides counts as equal.

---@return integer removed
function M.clean(opts)  -- opts.all=true → remove every state file; returns count.
                        -- opts.key → remove just that review's file.
```

**Tests**: fresh load; mark→save→load round-trip preserves records; `is_viewed` true on
matching pair, false after head_sha changes (invalidation), false after base_sha changes;
nil-sha handling for added files (mark an entry with base_sha=nil, reload, still viewed);
unmark; atomic save leaves no `.tmp` on success; corrupt file → fresh state without error;
`clean{all=true}` removes files; distinct keys (pr 1 vs pr 2; pr vs branch; different
branch pairs) map to distinct paths; same key → stable path. Point the state dir at a temp
dir in tests by overriding `M._dir` (module-level, documented as test seam) — acceptable
because it is filesystem location, not behavior.

---

## WP-C — `lua/difit/tree.lua`

Pure data structure; no vim APIs except `vim.deepcopy`-class utilities. Must be testable
without a child process.

```lua
---@class difit.TreeNode
---@field type "dir"|"file"
---@field name string           -- display name; compressed dirs: "a/b/c"
---@field path string           -- full relative path of this node
---@field children difit.TreeNode[]?  -- dirs only; dirs first then files, each alphabetical
---@field entry difit.FileEntry?      -- files only

---@param entries difit.FileEntry[]
---@return difit.TreeNode @root node (type="dir", path="", name="")
function M.build(entries)
-- Chains of single-child directories collapse into one node ("src/ui/widgets").
-- A dir with one file child does NOT collapse into the file.

---@class difit.TreeRow
---@field node difit.TreeNode
---@field depth integer  -- root children have depth 0

---@param root difit.TreeNode
---@param folded table<string, boolean>  -- dir path → folded?
---@return difit.TreeRow[]
function M.flatten(root, folded)  -- pre-order; folded dirs emit their row but no children

---@return string[] @paths of all file nodes in flatten order (ignoring folds)
function M.file_order(root)
```

**Tests**: single root file; nested structure ordering (dirs before files, alphabetical);
single-child chain compression incl. compressed node path correctness; no compression when
a dir has 2 children; flatten with a folded dir hides descendants but keeps the dir row;
`file_order` matches flatten order with no folds; empty input → root with no children.

---

## WP-D — `lua/difit/github.lua`

`gh` wrapper. All functions must not error when `gh` is missing — return `nil, err`.

```lua
---@return boolean
function M.available()  -- vim.fn.executable("gh") == 1

---@class difit.PrInfo
---@field number integer
---@field base_ref string    -- baseRefName, e.g. "main"
---@field owner_repo string  -- "owner/repo", parsed from the PR url

---@param repo difit.RepoIdentity
---@return difit.PrInfo|nil, string|nil err
function M.detect_pr(repo)
-- `gh pr view --json number,baseRefName,url` with cwd = repo.toplevel, 10s timeout.
-- Non-zero exit (no PR / not logged in) → nil, stderr. Parse owner/repo from url
-- "https://github.com/OWNER/REPO/pull/N" → "OWNER/REPO".
```

**Tests** (child Neovim + `helpers.path_shim`): shim `gh` printing canned JSON → PrInfo
fields correct; shim exiting 1 with stderr → `nil, err`; `available()` true with shim;
without shim and with PATH stripped of real gh → `available()` false and `detect_pr`
returns nil without raising.

---

## WP-E — `lua/difit/session.lua`

Orchestration core. No direct UI: renders happen via subscribed callbacks and an injected
view factory (real factories are wired by WP-I; tests inject fakes).

```lua
---@class difit.SessionOpts
---@field base string?            -- CLI arg override
---@field right ("worktree"|"head")?
---@field view_factory fun(mode: "sidebyside"|"unified"): difit.View
---@field github table?           -- injectable github module (default require("difit.github"))

---@class difit.View
---@field open fun(self, entry: difit.FileEntry, spec: difit.DiffSpec)
---@field close fun(self)

---@class difit.Session
---@field spec difit.DiffSpec
---@field entries difit.FileEntry[]
---@field state difit.ReviewState
---@field mode "sidebyside"|"unified"
---@field current_path string?
local Session = {}

---@param opts difit.SessionOpts
---@return difit.Session|nil, string|nil err
function M.new(opts)
-- 1. git.repo_identity(cwd)
-- 2. base resolution: opts.base > config.get().base > github PR baseRefName (when
--    detect_pr succeeds) > git.default_branch. Resolve to a ref that rev-parses
--    (try "<name>" then "origin/<name>").
-- 3. merge_base(base_ref, "HEAD"); error when base doesn't resolve or merge-base fails.
-- 4. review_key: PR detected → {kind="pr", repo=id, pr_number}; else {kind="branch",
--    repo=id, base=<short base name>, head=current_branch or "HEAD"}.
-- 5. state.load, diff_files → entries.

function Session:refresh()          -- recompute merge_base + entries; notify subscribers
function Session:subscribe(fn)      -- fn() called after refresh/toggle/mode change
function Session:open_file(path)    -- sets current_path, view:open(entry, spec)
function Session:toggle_viewed(path)  -- mark/unmark + state.save + notify; returns new bool
function Session:is_viewed(path)
function Session:next_unviewed(after_path)  -- tree.file_order order, wraps around; nil if none
function Session:progress()         -- {viewed = n, total = #entries}
function Session:set_mode(mode)     -- switch view; reopen current_path in new mode
function Session:close()            -- view:close(); state.save
```

**Tests** (child Neovim, real repos, fake view recording calls, fake github module):
base precedence (arg beats config beats PR beats default); PR detection produces pr key
and PR base; no PR → branch key with correct base/head names; entries populated from
fixture; toggle_viewed persists across `M.new` (same key) but not across a different
branch pair; next_unviewed skips viewed files, wraps, returns nil when all viewed;
progress counts; refresh picks up a new commit (entry list changes); set_mode reopens
current file through the new view; subscriber notified on toggle/refresh.

---

## WP-F — `lua/difit/ui/sidebyside.lua`

```lua
---@return difit.View
function M.new()
```

Behavior of `open(entry, spec)` in the current (difit-owned) tabpage:
- Ensure a two-window diff layout to the right of the panel (create on first open,
  reuse after).
- Left window: blob buffer named `difit://<short base sha>/<path>`; content
  `git.file_content{sha=entry.base_sha}`; empty scratch for added/untracked
  (`difit://empty/<path>`). Buffer opts: `buftype=nofile`, `modifiable=false`,
  `bufhidden=hide`; filetype from `vim.filetype.match({ filename = entry.path })`.
  Reuse an existing buffer with the same name instead of recreating.
- Right window: `right=="worktree"` → `:edit` the real file (deleted files: empty scratch
  `difit://deleted/<path>`); `right=="head"` → blob buffer of `entry.head_sha` (read-only,
  same rules as left).
- Run `diffthis` in both windows, cursor to the right window, first change (`]c`-ish:
  `normal! gg]c` guarded for no-change files).
- Binary entries: no diff; show a one-line scratch "binary file" in both windows.
- Apply `config.keymaps.diff` in difit-owned buffers only (never on real file buffers).
- `close()`: `diffoff` where applicable, wipe owned `difit://` buffers, never touch real
  file buffers' content.

**Tests** (child Neovim, screenshotless — assert via API): modified file → two windows
with `&diff` set, left buffer named `difit://…` and non-modifiable, right buffer is the
real file (`bufname == path`); added file → left is empty scratch; deleted → right empty
scratch; head mode → right is read-only blob whose content matches the committed file;
reopening a second file reuses the same windows (window count stable); close() leaves no
`difit://` buffers and unsets `&diff`; editing the right buffer then `:w` works
(worktree mode).

---

## WP-G — `lua/difit/ui/unified.lua`

```lua
---@return difit.View
function M.new()
```

- `open(entry, spec)`: one window (right of panel), read-only scratch buffer
  `difit://unified/<path>`, `filetype=diff` (gets stock syntax highlighting).
- Content: `diff --git a/<old> b/<new>` header line, then each hunk header + body from
  `git.hunks`. Binary entries: single "binary file" line.
- `<CR>` (from `config.keymaps.diff`… no — jump is hardcoded `<CR>`, toggle_viewed comes
  from config) on a body line jumps to the corresponding line of the real file in a
  window outside the viewer's diff area (use the previous window or a new split right of
  the panel): for "+"/" " lines compute new-file line from the hunk header offset; for
  "-" lines jump to `new_start` of the hunk.
- `close()`: wipe owned buffers.

**Tests**: buffer content contains the hunk header and expected +/- lines for the fixture's
modified file; `filetype == "diff"`; buffer not modifiable; `<CR>` on a "+" line opens the
real file with the cursor on the exact line (compute expected line from fixture content);
`<CR>` on a context line works; binary file shows placeholder; close wipes buffers.

---

## WP-H — `lua/difit/ui/panel.lua` + `lua/difit/ui/hl.lua`

`hl.lua`: define highlight groups (with `default = true` links):
`DifitPanelHeader`→`Title`, `DifitPanelDir`→`Directory`, `DifitStatusAdded`→`DiffAdd`(fg-ish → `Added`),
`DifitStatusModified`→`Changed`, `DifitStatusDeleted`→`Removed`, `DifitStatusRenamed`→`Special`,
`DifitViewed`→`Comment`, `DifitCounts`→`Comment`, `DifitCheckbox`→`Special`.

`panel.lua`:

```lua
---@param session difit.Session  -- only the documented Session interface is used
---@return difit.Panel
function M.open(session)  -- creates the left vertical split (config.panel.width) in the
                          -- current tabpage with a difit://panel buffer

---@class difit.Panel
function Panel:render()   -- re-reads session state and redraws
function Panel:close()
function Panel:focus()
```

Rendering (plain text + extmark highlights, `modifiable=false` outside render):

```
difit  main…feature/x (PR #123)
3/12 viewed
▸ folded/dir
▾ lua/difit
    [ ] M state.lua        +42 −3
    [✓] A new.lua          +10 −0
```

- Header: `base…head` plus `(PR #N)` when review_key.kind == "pr"; progress line from
  `session:progress()`.
- Dir rows: fold marker + name, `DifitPanelDir`. File rows: checkbox, status letter with
  its status group, filename, `+a −d` counts (`DifitCounts`), whole row `DifitViewed` when
  viewed. Icons before filename when `config.icons` and a provider is installed (feature-
  detect `mini.icons` then `nvim-web-devicons`; omit silently otherwise).
- Renamed rows show `old → new` (compressed to basenames when long is fine; keep simple:
  full relative paths).
- Panel keeps `folded` table + cursor row → node mapping. Keymaps from
  `config.keymaps.panel`: open (file → `session:open_file`; dir → toggle fold), fold,
  toggle_viewed (then `session:next_unviewed` + move cursor there + `session:open_file`
  when `config.auto_advance`), refresh (`session:refresh`), toggle_mode
  (`session:set_mode` to the other mode), close (`session:close`).
- Subscribes to the session (`session:subscribe`) and re-renders on notification.

**Tests** (child Neovim with a scripted fake session object implementing the Session
interface): render shows header, progress, tree rows in `tree.flatten` order; viewed file
shows `[✓]` and un-viewed `[ ]`; pressing toggle_viewed on a file row calls
`session:toggle_viewed(path)` and (auto_advance) moves cursor to the fake's
`next_unviewed`; `<CR>` on a file calls `open_file`; `<CR>`/`za` on a dir folds (children
disappear on re-render); `R` calls refresh; `s` calls set_mode with the flipped mode; `q`
calls close; buffer is not modifiable; panel width matches config.

---

## WP-I — Integration (`init.lua`, `plugin/difit.lua`, docs, e2e)

- `plugin/difit.lua`: guard `vim.g.loaded_difit`; define `:Difit` via
  `nvim_create_user_command` with `nargs="*"` and completion over
  `{"close","toggle","clean","refresh"}` + local branch names.
- `require("difit")`:
  - `setup(opts)` → `config.setup(opts)`.
  - `open(args)`: parse first arg — known subcommand or base branch name. Creates the
    dedicated tabpage (remember origin tabpage), builds the real view factory
    (sidebyside/unified), `session.new`, `panel.open`, opens the first un-viewed file.
    Repeated `:Difit` while open → focus the viewer tabpage.
  - `close()`: session close, panel close, close the tab, return to origin tabpage.
  - `toggle()`, `refresh()`, `clean()` (with a `vim.fn.confirm` guard; `clean` operates on
    the current review's key, `clean all` on everything).
- Autocmds (augroup `difit`, only while a session is open): `BufWritePost` for files under
  `spec.repo.toplevel`, and `FocusGained` → debounce 200ms (`vim.uv.new_timer`) →
  `session:refresh()`.
- Viewed toggling from diff buffers: `config.keymaps.diff.toggle_viewed` applied to
  difit-owned buffers (delegated to the views — verify it flows end-to-end here); also
  provide `<Plug>(difit-toggle-viewed)` for users to map in real file buffers.
- `doc/difit.txt`: commands, config defaults table, keymaps, viewed-state semantics
  (key + invalidation), health notes (gh optional). `README.md`: pitch, screenshot
  placeholder, requirements (0.12+, optional gh/icons), lazy.nvim install snippet, config
  defaults, difit attribution.
- **e2e tests** (`tests/test_e2e.lua`, child Neovim on fixture repos; this is where
  `expect_screenshot` is used — commit the golden files):
  1. `:Difit` on the fixture opens a new tabpage: panel left + diff windows; screenshot.
  2. Mark a file viewed via panel key → progress updates, auto-advance opens next file;
     screenshot after.
  3. `:Difit close` restores the original tabpage/layout.
  4. Reopen `:Difit` → viewed marks survived (same branch key, no gh).
  5. Commit a change to a viewed file in the fixture → reopen → that file un-viewed again
     (blob-SHA invalidation), untouched viewed file still viewed.
  6. With a `gh` PATH shim (PR #7) → header shows `(PR #7)`; state file differs from the
     branch-key run (separate spaces).
  7. `s` switches to unified (screenshot), `<CR>` jump works from unified.
  8. `BufWritePost`: edit+write a file in the right window → panel counts change.
  9. `:Difit main` (explicit base) beats auto-detection.
  10. Deleted and renamed files open without errors in both modes.

---

## Delegation & verification protocol (orchestrator)

1. Phases run in order 0 → 1 → 2 → 3; WPs inside a phase run as parallel Sonnet agents in
   the shared working tree (ownership is disjoint; agents must not touch `deps/`).
2. Agent prompt = pointer to `docs/design.md` + `docs/plan.md` + its WP id + ground rules;
   agents report API deviations instead of improvising.
3. After each WP lands: orchestrator reviews the diff, runs `make lint` and the WP's test
   file, then the full suite at phase end; one commit per WP
   (`feat(git): ...` / `test: ...` style, Conventional Commits).
4. Phase 3 ends with: full suite on 0.12, stylua, a code-review agent pass over the whole
   diff, manual smoke check in a real repo, PR body update.
