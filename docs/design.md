# diffly.nvim — Design

A [difit](https://github.com/yoshiko-pg/difit)-inspired diff viewer for Neovim: a file-tree
diff viewer (like diffview.nvim) with per-file `viewed` marks that persist across viewer
sessions for the same PR.

Status: design agreed on 2026-07-08; implemented. Structure and mechanisms are
documented in [architecture.md](./architecture.md). Sections below are kept in sync with
the code as behavior evolves.

## Goals (v1)

- File-tree panel listing files changed between the current branch and its base branch, or in a PR.
- Diff display selectable between side-by-side and unified (single column).
- Per-file `viewed` marks, persisted per PR (or per branch pair), shared across viewer
  sessions, worktrees, and clones. Never carried over to a different PR.

Out of scope for v1 (deliberately deferred): arbitrary rev comparison (`difit A B`),
staged/working-only modes, flat list toggle in the panel, fs-watch based refresh.
Line comments + AI prompt copy, deferred at v1, are now designed and phased in — see
[Comments](#comments) below.

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
- **Persistence**: JSON under `stdpath('data')/diffly/`, one file per review, filename =
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
- Cleanup is explicit via `:Diffly clean`; no automatic GC.

### UI

- **Dedicated tabpage** (diffview.nvim-style): tree panel on the left, diff on the right.
  Closing restores the previous layout.
- **Tree**: directory hierarchy with folds and single-child directory compression
  (GitHub-style `a/b/c` collapsing). Status letter (A/M/D/R), +/- counts, viewed mark per
  row. Icons via mini.icons / nvim-web-devicons when installed. The row for whichever file
  is currently open in the diff view is highlighted (`DifflyCurrentFile`) so its position in
  the tree is always visible.
- **Side-by-side**: native diff mode. Left = read-only git blob buffer (`diffly://`
  namespace), right = the real file buffer (edits and `:w` work as usual). Deleted files
  show an empty right side; untracked files an empty left side.
  - **Asymmetric diff palette**: native diff mode's highlight semantics are symmetric --
    a line missing on the other side is `DiffAdd` in whichever window has it, so the
    *before* pane paints deleted lines green -- and intra-line emphasis inherits the
    colorscheme's `DiffText` hue (often blue). A reviewer's eye scans for "red = removed
    / green = added" (the reading delta and difftastic serve), so diffly remaps the diff
    groups per window: everything in the left pane is red-family, everything in the
    right pane green-family, alignment filler muted (`NonText`). The remap rides
    diffly-owned window highlight namespaces (`nvim_win_set_hl_ns`), NOT `'winhighlight'`
    -- winhl is a single shared per-window string that other plugins read-modify-write
    (mode-colored-cursorline movers, float managers), so a remap parked there can be
    silently dropped mid-session, reverting both panes to the native symmetric colors,
    and the `vim.wo` write it takes leaks the remap into the global winhl default on
    top; a namespace has exactly one writer and takes precedence over any
    `'winhighlight'` value. Accepted cost: other plugins' winhl-based tweaks don't apply
    inside the two panes. The colors are derived from the active colorscheme
    (`ui/hl.lua`), never hardcoded: line bg = the scheme's own `DiffAdd`/`DiffDelete`
    bg, intra-line emphasis = that same hue pushed toward the scheme's `Added`/`Removed`
    accent, so the emphasis always contrasts with its line bg *and* stays in the right
    color family. Window-scoped, so the user's diff colors outside diffly are untouched. Intra-line regions themselves come from
    `diffopt`'s `inline:char` (a Neovim 0.12 default, alongside `linematch:40`); a user
    who removed those flags gets line-level asymmetry only -- accepted, diffly never
    mutates global options.
- **Unified**: inline overlay on the real buffer (worktree file, HEAD blob, or
  deleted-file blob), not a synthetic patch buffer -- so it gets the file's own syntax
  highlighting and LSP where side-by-side already did, which the old patch-text buffer
  never could. "+" lines are highlighted in place; deleted lines render as read-only
  virtual lines (`virt_lines`) anchored where the text used to sit. The buffer is
  editable in worktree mode, exactly like side-by-side's right-hand window.
- **Refresh**: automatic on `BufWritePost` and `FocusGained`, manual with `R` in the
  panel.
- **Large files**: binary files always render a placeholder regardless of size; a huge
  text file (`config.max_file_size`, default 1 MiB) gets the same treatment instead of
  loading its content, with a buffer-local `L` key to load it anyway for that view.
- **Generated files** (GitHub parity): a file recognized as vendored/lockfile/codegen
  output (github-linguist's own `generated.rb` rules, or an explicit `.gitattributes`
  `linguist-generated` override either way) keeps its panel row, `+`/`-` counts, and
  manual viewed marking -- only its diff body gets the same placeholder-plus-`L`-key
  treatment as large files, ranked just after the size guard (an oversized file's content
  is never loaded, so the heuristics never run against it). `config.collapse_generated`
  disables both the heuristics and the `.gitattributes` override; there is no separate
  diffly-specific pattern list -- `.gitattributes` is the only per-file override, same as
  on github.com.

### Comments

Design agreed 2026-07-12; all three phases (local comments, the read-only remote
overlay, batch submission + draft adoption) are implemented.

- **Purpose**: the reviewer's own tool — notes while reading a diff, feedback to hand to
  an AI coding agent (difit's flagship workflow), and drafts of PR review comments. Not a
  full PR-review client: other people's comments only ever need to be *readable* (Phase
  2), and posting is a batch *exit* (Phase 3), never the storage.
- **Local-first, always.** Comments live in the review's own state file whether or not a
  PR exists — the same "the PR is a metadata source only" principle v1 set for diffs.
  GitHub is a read-only overlay (fetched threads rendered alongside local drafts, never
  merged into local state; `isOutdated`/`isResolved` taken verbatim) and an explicit
  submit target (`:Diffly submit`: one `POST /pulls/N/reviews` with a `comments` array —
  one review, one notification — behind an event picker and a pre-submit validation pass,
  since the endpoint is atomic and rejects lines outside the PR's diff). Submitted drafts
  leave the local store and reappear through the overlay, so nothing renders twice.
- **Submit safety**: local HEAD must be the PR head (else abort with a message — the diff
  you reviewed must be what you comment on); drafts on worktree-only edits, out-of-diff
  lines, cross-hunk ranges, or outdated anchors are excluded, reported, and kept locally;
  only a *successful* POST mutates the local store. A worktree-drifted head-side draft
  re-anchors onto the PR head blob for the payload only — the draft itself keeps pointing
  at what the user sees.
- **Overlay fetch timing**: asynchronously once on session open (opening never waits on
  the network), on every *explicit* refresh (`:Diffly refresh`, a bare `:Diffly` on the
  viewer tab, the panel's `R`), and after a submit. **Never** on the debounced
  `BufWritePost`/`FocusGained` auto-refresh — saving a file must not become network
  traffic. Unresolved threads render inline with `@author` attribution (full threads,
  replies included); resolved ones hide behind a session-wide toggle (`cr` /
  `<leader>cr`); outdated ones (GitHub nulls their live line) appear only in
  `:Diffly comments`, marked. The panel `✎N` count adds unresolved remote threads,
  independent of the toggle. Remote thread positions are PR-head coordinates: exact on a
  clean `gh pr checkout`, an accepted approximation once local edits shift lines.
- **Model**: thread-shaped (`messages[]`) for future replies, but the v1 UI creates and
  edits exactly one message per thread. Anchors are a single line or a range, on either
  side, in **diffly-neutral vocabulary** (`side = "base"|"head"`, `outdated` as a plain
  boolean): provider-specific shapes (GitHub's LEFT/RIGHT, GraphQL thread ids) stay inside
  the provider module, arriving in Phase 2 with a small LuaCATS contract
  (`detect_pr` / `fetch_threads` / `submit_review`) — no registry, no config.
- **Anchoring**: a comment records its side's blob sha plus a snapshot of the commented
  lines' text. On session build and refresh, a changed sha triggers an exact whole-block
  search for the snapshot, nearest to the old position (ties go to the smaller line);
  found → the anchor follows (and persists), not found → `outdated`. Outdated threads
  never render inline — a comment pinned to the wrong line is worse than an absent one —
  but stay reachable via the panel count and `:Diffly comments`. The failed pass advances
  the anchor sha too, so unchanged content short-circuits instead of re-scanning.
  File-level sha invalidation (the viewed-mark rule) was rejected for comments: any edit
  anywhere in the file would expire every comment in it, which is wrong for the primary
  "AI agent keeps rewriting the file under review" workflow.
- **Display**: expanded inline by default — each thread as a BOXED `virt_lines` block
  (`╭─` header, `│ ` body lines, `╰─` footer) directly below the commented line (below
  the *deleted* lines it annotates, for a base-side comment on a removed line) — with a
  session-wide collapse toggle down to an eol indicator. The box is load-bearing: two
  threads on the same line would otherwise fuse into one block, and the header is where
  identity lives — `✎ draft` for local comments, `@author` (+`[resolved]`) for remote
  ones, on top of the distinct marker highlights. Both views render both sides; the
  panel shows a per-file `✎N` count (outdated included).
- **Wrapping** (default on, `comments = { wrap = true, max_width = 100 }`): virt_lines
  never wrap natively — the window `'wrap'` option only affects real lines, and
  overlong virtual lines are truncated at the window edge — so body lines soft-wrap at
  render time to the showing window's text width, capped by `max_width` (GitHub-column
  readability on wide screens; `false` uncaps). Word-boundary breaks when the line has
  spaces, display-cell character breaks otherwise (Japanese text, URLs); header, footer
  and `@author` attribution lines never wrap. Display-only: the stored body is
  untouched, so `cy`/`cY` copy the original text, and the user's own `'wrap'` setting
  in code windows is never modified. Resizes re-wrap via a debounced repaint; each
  side-by-side split wraps to its own width. The compose float follows `comments.wrap`
  (window-local `wrap`+`linebreak`) so typing looks like the eventual render.
- **Compose**: a small markdown float at the cursor, reused for editing. Submit with
  `:w`/`:wq` (the buffer is `acwrite` with a `BufWriteCmd`; Ctrl keys can be eaten by
  terminal flow control or multiplexer bindings, so vim's own save gesture must always
  work) or `<C-s>`; `q` cancels, an empty body cancels, and `:q` on an unsaved body
  warns like an unsaved file. Deleting asks for confirmation via `vim.ui.select`.
- **Writing a base-side comment from the unified view is deferred** (deleted lines are
  virtual there — the cursor can't reach them); side-by-side's left window is the
  affordance. Base-side comments *render* in both views.
- **AI prompt copy**: difit-compatible — `path:L42` (or `:L42-L48`) + body, `=====`
  between comments for copy-all — to the unnamed register, best-effort to the clipboard.
- **`:Diffly comments`**: every thread into quickfix (`[outdated]`/`[base]` markers, first
  body line), rather than a bespoke list UI. `<CR>` in the quickfix window jumps *inside*
  the diff view — the base window/mapped row for base-side threads, at the anchor's end
  line where the thread renders — and degrades to the vanilla file jump whenever the
  diffly context is gone (a foreign list, a closed review, a dropped path), so the list
  stays useful for its whole quickfix-native lifetime (`:cnext`/`:cdo` stay vanilla —
  there is no hook for them, and their batch semantics want real files anyway).
- **Keys**: a `c` family (`ca/ce/cd/ct/cy/cY`) on diffly-owned buffers; the same family
  leader-prefixed everywhere else — on a real file buffer (where most comments get
  written) the universal layer is the only one allowed, so the primary gesture is
  `<leader>ca` by design. `ca` also works on a visual range. Placeholder buffers
  (binary/oversized/generated) get no comment keys at all.
- **Navigation** (`]C`/`[C`, DEV-34): jump to the next/previous *inline-rendered* thread —
  exactly what the eye can find: local drafts plus displayable remote threads, never
  outdated ones (their position is a memory, not a location; `:Diffly comments` remains
  their channel), resolved ones only while revealed. Review-wide in document order —
  `tree.file_order` (the panel's own order, same source as `]f`), then rendered row, with
  base-side anchors interleaved through the same `base_target` hunk walk the unified view
  renders with — wrapping at the ends, silently (the `]f` precedent). Same-row threads
  collapse into one stop, so a jump always moves. Landing reuses the quickfix `<CR>`
  machinery (`focus_line`): side-by-side focuses the base window for base-side threads.
  Lives in the universal layer (navigation, like `]f`/`[f` — not part of the `c` family:
  jumping away is meaningful from any buffer, placeholders included); in the panel the
  reference point is the file row under the cursor. Uppercase `C` because the diff windows
  run in diff mode, where lowercase `]c`/`[c` is vim's own change-jump — shadowing it
  would break hunk navigation.
- **Storage**: the `comments` field the v1 schema reserved, inside the existing per-review
  state file (same key scoping, version still 1). When a PR is first detected for a
  branch that has drafts under the branch-pair key, the drafts are adopted into the
  PR-keyed store automatically (one-way, once, with a notice, fresh ids) — drafts are
  user text and must survive the key switch; viewed marks stay unmigrated as before.
- Rejected: fuzzy/partial snapshot matching (silently mis-anchored comments); rendering
  outdated threads at the top of the file (misattribution noise); persisting buffer rows
  (derived state that drifts); posting comments to GitHub as they're written (notification
  spam, and GitHub silently folds them into any pending review); GitHub-side pending
  reviews as the draft store (offline-hostile, per-keystroke API traffic).

### Agent bridge

Hunk-style local review with a coding agent (DEV-32): the human reviews in diffly, the
agent reads those drafts, fixes code, replies, and leaves its own comments — visible
live in the open UI.

- **Bidirectional**: the agent reads *and* writes local drafts (`bin/diffly info`,
  `comments list [--remote]`, `comments add/rm/reply`, `navigate`). Deliberately absent:
  viewed manipulation (viewed marking is always an explicit human action) and review
  submission (posting under the human's GitHub identity is the human's call).
- **RPC-first, headless fallback**: when a live Neovim holds this repo's review, every
  op runs inside it (single write authority — a live session rewrites the whole state
  file on save, so a second writer would clobber it and collide on `comment_seq`); the
  agent's comments appear in the human's UI the moment they're written. With no live
  session, the CLI operates on the persisted state directly through the same plugin code
  (`nvim -l`; no standalone binary — reimplementing key derivation/anchoring in another
  language was rejected as guaranteed drift).
- **Attribution**: agent-written messages carry `author` (absent = the human; schema
  version stays 1 — absent-field defaulting is the compat strategy). Rendered as
  `✎ draft @author` inline, `[@author]` in the quickfix. Submission deliberately does
  NOT filter by author: drafts are drafts, the human curates before `:Diffly submit`.
- Rejected: a Go/standalone CLI reading the state files (logic drift, and it cannot
  talk to a live session); live-session state reload/merge on refresh (delicate seq
  reconciliation for a case RPC routing removes outright).

### Interface

- Single `:Diffly` command with subcommands: `:Diffly [base]` (open/focus), `:Diffly close`,
  `:Diffly toggle`, `:Diffly clean`, with completion.
- `setup()` is optional — the plugin works with defaults; `setup()` only overrides them.
- No global keymaps. Buffer-local keymaps follow a two-layer model, modeled on
  diffview.nvim: a **universal** layer (`keymaps.universal`, leader-prefixed) of
  real-buffer-safe keys — toggle viewed, toggle side-by-side/unified, focus the panel; no
  `close` — that works identically in every diffly context: the panel, diffly-owned diff
  buffers (blob/unified), and real file buffers shown in the viewer (the side-by-side
  worktree right buffer) alike. On top of that, **local single-key shortcuts** apply only
  where the buffer is diffly-owned: the panel gets its own set (`keymaps.panel`: open,
  toggle viewed, refresh, toggle mode, close, fold) and diffly-owned diff buffers get the
  full `keymaps.diff` set (toggle viewed, toggle side-by-side/unified, focus the panel,
  close the review) in addition to `keymaps.universal` — real file buffers never get
  single-key shortcuts, since those could collide with the buffer's own, unrelated
  keymaps. On a real file buffer, `keymaps.universal` is mapped only while that buffer is
  the one currently open in the view, and removed again once the view moves on to a
  different file or closes, so a real file buffer never keeps diffly's keymaps after the
  viewer stops showing it.

### Tech

- **Zero runtime dependencies.** `vim.system` for git, `vim.json` for persistence, plain
  buffers/extmarks for UI. Optional: mini.icons / nvim-web-devicons, `gh` CLI (PR mode
  only; silently falls back to the branch-pair key with a one-time notice when absent).
- **Neovim 0.12+.**
- **Modules**: `git.lua` (diff/blob access), `github.lua` (gh wrapper, stubbable),
  `state.lua` (viewed persistence), `comments.lua` (comment model + re-anchoring),
  `tree.lua` (file tree model), `ui/panel.lua`, `ui/sidebyside.lua`, `ui/unified.lua`,
  `ui/comments.lua` (comment rendering + compose float), `ui/scratch.lua` (shared
  `diffly://` scratch-buffer find-or-create + LSP-safe highlighting), `config.lua`.

### Development

- TDD (red → green → refactor). Tests with **mini.test** (child Neovim + screenshot
  tests); git is never mocked — tests create real repositories in temp dirs. Only the
  `gh` layer is stubbable.
- CI: GitHub Actions on Neovim 0.12 stable + nightly.
- English README + vimdoc (`doc/diffly.txt`). Feature branches, Conventional Commits,
  draft PRs.
