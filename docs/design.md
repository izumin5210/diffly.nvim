# difit.nvim — Design

A [difit](https://github.com/yoshiko-pg/difit)-inspired diff viewer for Neovim: a file-tree
diff viewer (like diffview.nvim) with per-file `viewed` marks that persist across viewer
sessions for the same PR.

Status: design agreed on 2026-07-08. Not yet implemented.

## Goals (v1)

- File-tree panel listing files changed between the current branch and its base branch, or in a PR.
- Diff display selectable between side-by-side and unified (single column).
- Per-file `viewed` marks, persisted per PR (or per branch pair), shared across viewer
  sessions, worktrees, and clones. Never carried over to a different PR.

Out of scope for v1 (deliberately deferred): arbitrary rev comparison (`difit A B`),
staged/working-only modes, line comments + AI prompt copy (schema stays extensible for it),
flat list toggle in the panel, fs-watch based refresh.

## Decisions

### Positioning

- **Standalone plugin.** No dependency on diffview.nvim (its file panel has no public
  extension point for custom indicators). Side-by-side uses Neovim's native diff mode.

### Diff sources (v1)

- **Branch vs base**: compare `merge-base(base, HEAD)` (three-dot semantics) against the
  working tree.
- **PR mode**: the PR is a *metadata source only* — used to resolve the base branch and to
  key the viewed state. The diff itself is always generated from local git. Reviewing
  someone else's PR means `gh pr checkout` first.
- Base branch resolution: command argument > config > auto-detect (`origin/HEAD`, then
  `main`/`master`).
- Right side of the diff: **working tree** by default (uncommitted edits show up
  immediately); switchable to HEAD via config/argument. Untracked files are included
  (config to exclude).

### Viewed state

- **Key**: `owner/repo#number` when a PR for the current branch is detected via `gh`;
  fallback to `repo + base..head` branch pair otherwise. The two spaces are independent;
  no migration between them.
- **Invalidation (GitHub-style)**: marking a file viewed records its `(base blob SHA,
  head blob SHA)` pair. If the pair no longer matches at render time, the file counts as
  un-viewed again. Unchanged files survive new commits. Working-tree/untracked SHAs come
  from `git hash-object`.
- **Persistence**: JSON under `stdpath('data')/difit/`, one file per review, filename =
  hash of the key. Repo identity = normalized remote URL (fallback: toplevel path), so
  state is shared across worktrees and clones.
- **Schema** (extensible; `comments` may be added later):

  ```json
  {
    "version": 1,
    "key": { "...": "pr or branch-pair identity" },
    "last_opened": "...",
    "viewed": {
      "path/to/file": { "base_sha": "...", "head_sha": "...", "marked_at": "..." }
    }
  }
  ```

- **Interaction**: manual toggle only (no auto-mark on scroll), same key from the tree
  panel and from the diff. Marking advances to the next un-viewed file (config to
  disable). Viewed files are greyed out in the tree; the panel header shows progress
  (e.g. `viewed 3/12`).
- Cleanup is explicit via `:Difit clean`; no automatic GC.

### UI

- **Dedicated tabpage** (diffview.nvim-style): tree panel on the left, diff on the right.
  Closing restores the previous layout.
- **Tree**: directory hierarchy with folds and single-child directory compression
  (GitHub-style `a/b/c` collapsing). Status letter (A/M/D/R), +/- counts, viewed mark per
  row. Icons via mini.icons / nvim-web-devicons when installed.
- **Side-by-side**: native diff mode. Left = read-only git blob buffer (`difit://`
  namespace), right = the real file buffer (edits and `:w` work as usual). Deleted files
  show an empty right side; untracked files an empty left side.
- **Unified**: read-only formatted patch buffer with a jump-to-file key. The view layer
  keeps a boundary so this can later be replaced by an inline-overlay implementation.
- **Refresh**: automatic on `BufWritePost` and `FocusGained`, manual with `R` in the
  panel.

### Interface

- Single `:Difit` command with subcommands: `:Difit [base]` (open/focus), `:Difit close`,
  `:Difit toggle`, `:Difit clean`, with completion.
- `setup()` is optional — the plugin works with defaults; `setup()` only overrides them.
- No global keymaps. Buffer-local keymaps are provided by default and configurable: the
  panel and difit-owned diff buffers (blob/unified) get the full `keymaps.diff` set
  (toggle viewed, toggle side-by-side/unified, focus the panel, close the review). Real
  file buffers shown in the viewer (the side-by-side worktree right buffer) get a
  separate, leader-prefixed `keymaps.file` set (toggle viewed/mode, focus the panel; no
  `close`) — mapped only while that buffer is the one currently open in the view, and
  removed again once the view moves on to a different file or closes, so a real file
  buffer never keeps difit's keymaps after the viewer stops showing it.

### Tech

- **Zero runtime dependencies.** `vim.system` for git, `vim.json` for persistence, plain
  buffers/extmarks for UI. Optional: mini.icons / nvim-web-devicons, `gh` CLI (PR mode
  only; silently falls back to the branch-pair key with a one-time notice when absent).
- **Neovim 0.12+.**
- **Modules**: `git.lua` (diff/blob access), `github.lua` (gh wrapper, stubbable),
  `state.lua` (viewed persistence), `tree.lua` (file tree model), `ui/panel.lua`,
  `ui/sidebyside.lua`, `ui/unified.lua`, `ui/scratch.lua` (shared `difit://` scratch-buffer
  find-or-create + LSP-safe highlighting), `config.lua`.

### Development

- TDD (red → green → refactor). Tests with **mini.test** (child Neovim + screenshot
  tests); git is never mocked — tests create real repositories in temp dirs. Only the
  `gh` layer is stubbable.
- CI: GitHub Actions on Neovim 0.12 stable + nightly.
- English README + vimdoc (`doc/difit.txt`). Feature branches, Conventional Commits,
  draft PRs.
