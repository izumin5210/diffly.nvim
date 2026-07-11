# diffly.nvim — Architecture

How the plugin is structured and why the load-bearing mechanisms look the way they do.
Behavior-level decisions (what `viewed` means, key choices, scope) live in
[design.md](./design.md); this document covers the machinery. Several sections carry a
"why" note describing a bug class the current shape prevents — treat those as regression
warnings, not history trivia.

## Module map

| Module | Responsibility |
|---|---|
| `plugin/diffly.lua` | `:Diffly` command + completion, `<Plug>` mappings. Thin: routes into `require("diffly")`. |
| `lua/diffly/init.lua` | Orchestration: the tabpage-keyed session registry, open/close lifecycle, autocmds, the per-session `actions` table, sweep selector UI. |
| `lua/diffly/session.lua` | One review session: diff spec construction, entries, viewed toggles (single + batch), mode switching, subscriber notifications. No UI. |
| `lua/diffly/git.lua` | Synchronous git plumbing (`vim.system(...):wait()`): identity, refs, `diff_files` (NUL-parsed `--raw`/`--numstat`), blob content, hunks, batched `check_attrs`. |
| `lua/diffly/github.lua` | `gh` wrapper. PR detection only (base ref + PR number); every failure returns `nil, err` — never raises. |
| `lua/diffly/state.lua` | Viewed-state persistence under `stdpath('data')/diffly/`; blob-SHA invalidation; `clean`. |
| `lua/diffly/tree.lua` | Pure tree model: build (single-child dir compression), flatten (folds), file_order. |
| `lua/diffly/config.lua` | Defaults, `setup()`, `viewed_patterns` group normalization. |
| `lua/diffly/types.lua` | `---@meta` LuaCATS contracts shared across modules. |
| `lua/diffly/generated.lua` | Pure classifier ported from github-linguist's `generated.rb`: `M.generated(path, lines) -> boolean`. No git, no I/O. |
| `lua/diffly/ui/panel.lua` | File-tree panel: render pipeline, cursor preservation, panel-local keys, hide-viewed filter. |
| `lua/diffly/ui/sidebyside.lua` | Native diff-mode view: blob left, real file (or head blob) right. |
| `lua/diffly/ui/unified.lua` | Inline-overlay view: real buffer + extmark overlay, deletions as `virt_lines`. |
| `lua/diffly/ui/keymaps.lua` | Keymap specs (diff/universal layers), attach/detach lifecycle, ownership tokens. |
| `lua/diffly/ui/scratch.lua` | All `diffly://` buffer naming/options/reuse + LSP-safe highlighting. |
| `lua/diffly/ui/guard.lua` | `config.max_file_size` AND `config.collapse_generated` decisions + placeholder messages/`L` key, shared by both views (formerly `ui/size_guard.lua`, generalized once the generated-file guard needed the same shape). |
| `lua/diffly/ui/hl.lua` | Highlight groups (`default = true` links). |

Dependency direction: `init` → `session`/`ui/*` → `git`/`state`/`tree`/`config`.
`ui/panel.lua` and `init.lua` stay require-acyclic: anything the panel needs from init
(sweep selector, actions) is injected at `panel.open(session, opts)` time.

## Session lifecycle

`:Diffly [base|subcommand]` → `init.lua`:

1. **Build the session first** (`session.new`): repo identity (normalized remote URL,
   fallback toplevel path) → base resolution (`arg > config.base > PR baseRefName >
   default branch`, each name tried as-is, then `origin/<name>`, then every other
   remote) → `merge_base(base, HEAD)` → review key (`{kind="pr", pr_number}` whenever a
   PR is detected via `gh`, else `{kind="branch", base, head}`) → `state.load` →
   `git.diff_files`. Building before creating any window means a resolution failure
   leaves no half-open tab behind.
2. **Registry check**: sessions live in `entries[tabpage]`. If a live entry has the same
   review key, focus its tabpage instead of duplicating. Different keys (other repo/base)
   open concurrently in their own tabs.
3. **Tab + panel + ctx**: `tab split`, `panel.open` (left split, `winfixwidth/height`,
   `winfixbuf`, `vim.w[win].diffly` sentinel), then a per-session
   `ctx = { anchor = panel_win, claim = placeholder_win, actions = build_actions(tab) }`
   handed to every view the factory creates. First un-viewed file opens automatically.
4. **Per-entry augroup**: `BufWritePost` (files under toplevel) + `FocusGained` →
   200 ms debounced `session:refresh()`. Timer and augroup die in teardown.

**Teardown funnel**: exactly one idempotent `close_entry(tabpage)` (stop timer, clear
augroup, `session:close()` — which saves state — `panel:close()`, close the tab with a
last-tab guard, restore the origin tab, deregister). Every detector routes there:
explicit `:Diffly close`/`q`, a `TabClosed` reconciliation pass, and a `WinClosed` watch
on the panel's sentinel. *Why*: teardown taken from N entry points used to strand timers
and autocmds; a funnel makes double-close a no-op instead of an error.

## View contract

Both views implement `diffly.View`: `open(entry, spec)` / `close()`, built by
`M.new(ctx)`.

- `ctx.anchor` — the window to split rightward from (the panel). Views **never read the
  current window**; they absorb `ctx.claim` (the initial placeholder) once, otherwise
  split fresh from the anchor, record every window they create, and destroy exactly
  those in `close()`. *Why*: claiming "the current window" once grabbed the panel during
  a mode switch and died on its `winfixbuf` (E1513) — placement must not depend on where
  focus happens to be.
- `Session:set_mode` builds and opens the new view **before** closing the old one
  (diffview's `StandardView:use_entry` order), so the diff area never collapses
  mid-switch. Consequence: two views' lifetimes overlap briefly, which is why keymap
  attach/detach uses per-buffer ownership tokens (below).
- `ctx.actions` (`toggle_viewed(path)`, `toggle_mode`, `focus_panel`, `close`,
  `next_file`, `prev_file`) is built once per session in `init.lua`; each action
  captures the **tabpage handle** and resolves the live registry entry at call time.
  Stale invocations notify instead of erroring. *Why*: module-level callback slots were
  process-global mutable state — two sessions clobbered each other.

## Keymap system

Three layers, all buffer-local **and `nowait`**:

| Layer | Keys (defaults) | Applied to |
|---|---|---|
| `keymaps.universal` | `<leader>v/s/e`, `]f`, `[f` | every diffly context: panel, owned buffers, and the real file buffer currently shown |
| `keymaps.panel` | `v s R q za H S V <CR>` | panel buffer only |
| `keymaps.diff` | `v s q <leader>e` | diffly-owned diff buffers only (blob, head blob) — never real buffers |

- `nowait` is what makes buffer-local maps actually win: without it, a longer global
  mapping sharing the prefix (`<leader>vx`) drags the keypress into the ambiguity
  timeout and can steal it.
- Apply order on owned buffers is deterministic: `diff` first, `universal` second (last
  write wins on a configured collision).
- Real buffers: `universal` attaches when the buffer becomes the shown file and detaches
  on file switch / view close, guarded by `vim.b` ownership tokens because view
  lifetimes overlap during `set_mode` — a detach only proceeds if the detaching view
  still owns the buffer's maps.

## Rendering

- **Side-by-side**: Neovim's native diff mode. Left = read-only blob buffer of the
  merge-base file; right = the real worktree buffer via `:edit` (so editing, `:w`, LSP
  all behave normally) or a head blob in `right = "head"` mode.
- **Unified (inline overlay)**: one window showing the real buffer (or head/deleted-file
  blob), with the diff overlaid in a per-view namespace: `+` lines get
  `DifflyOverlayAdd` line extmarks; each contiguous `-` run renders as one `virt_lines`
  extmark (`DifflyOverlayDelete`) anchored where the text used to sit. Anchoring edge
  cases (top-of-file, EOF, whole-file-emptied) are documented at `compute_overlay` and
  pinned by tests against real `git diff -U3` output. Full clear-and-redraw per render.
  *Why this model*: a rendered patch buffer can never have source syntax or LSP; the
  real buffer gets both for free, and deletions-as-virtual-lines keep line numbers,
  marks, and search honest.
- **`diffly://` buffers** (`ui/scratch.lua`): named
  `diffly://<kind>/<session discriminator>/<rest>` — the discriminator exists because two
  concurrent reviews can share blob SHAs, and identical names once made one session's
  cleanup close the other's window. Highlighting is applied without ever setting
  `'filetype'` (LSP `didOpen` on custom URIs can crash servers): `vim.treesitter.start`
  when a parser exists, else `'syntax'`.
- **Panel**: plain lines + extmark highlights, rebuilt per render; cursor follows the
  node it was on across background refreshes; `winfixwidth` + an `ensure_width` check
  keep the configured width through window churn. The row matching `session.current_path`
  gets a whole-row `DifflyCurrentFile` background extmark at a below-default priority, so
  segment/viewed foreground groups still show through on top of it; `Session:open_file`
  notifies subscribers only when `current_path` actually changes, which is what keeps this
  highlight from going stale after `]f`/`[f`/`<CR>`/auto-advance.
- **Large-file guard** (`ui/guard.lua`, `config.max_file_size`): lazily, at
  `open()` time for the one entry being opened, both views check whether the content they
  are about to load (sidebyside: base blob + right side; unified: whichever single side
  it renders, skipping the base blob it only ever feeds to `git diff` for hunks) exceeds
  the limit, and render a binary-style placeholder instead when it does, with a
  buffer-local `L` key that adds the path to a per-view `force_loaded` set (reset by a
  fresh view instance, i.e. a mode switch or close -- never persisted) and reopens.
  Binary detection is checked first and always wins outright. *Why lazy*: `max_file_size`
  must never add a subprocess call for a file nobody opened.
- **Generated-file guard** (`ui/guard.lua`'s `M.is_generated`, `lua/diffly/generated.lua`,
  `config.collapse_generated`): GitHub-parity collapsing of vendored/lockfile/codegen
  output, sharing the large-file guard's exact placeholder/`L`-key/`force_loaded`
  mechanics -- only the message and the detection source differ. Detection precedence per
  entry, evaluated lazily at `open()` time, same as the size guard:
  1. binary wins outright, same as the size guard;
  2. the size guard itself runs next -- an oversized entry's content is never loaded, so
     the generated-file heuristics (which need to read it) never get a chance to run for
     it, and a `.gitattributes` override never gets consulted either; an accepted
     divergence from a hypothetical "check generated first" ordering, since running
     heuristics on unloaded content would defeat the size guard's entire point;
  3. `spec.generated_attrs[entry.path]` -- the session's batched `git check-attr -z
     linguist-generated --stdin` result (`git.lua`'s `M.check_attrs`, computed once per
     session build/`refresh()`, never per `open()`) -- wins BOTH ways when present:
     `-linguist-generated`/`linguist-generated=false` forces "not generated" and skips
     heuristics entirely; any other explicit value forces "generated" without even
     reading content; absent (git reported "unspecified") falls through to (4).
     Deliberately reads the WORKING TREE (no `--cached`), unlike upstream linguist itself
     (which queries the index) -- an uncommitted `.gitattributes` edit takes effect
     immediately, matching what a diff-against-worktree review tool wants.
  4. `lua/diffly/generated.lua`'s heuristics (a verbatim port of github-linguist's
     `generated.rb`) run against the content the view is about to render as the file's
     "current" side -- worktree file, `entry.head_sha`'s blob, or `entry.base_sha`'s blob
     for a deleted file. This side choice is diffly's OWN decision (`ui/guard.lua`'s
     `M.generated_check_lines`): linguist itself classifies one blob at a time with no
     diff/side concept, and GitHub's own choice of which side of a PR diff it runs its
     collapsing heuristics against isn't documented or observable.
- **Owned-buffer close() vs. shared names**: a binary/head-mode/oversized/generated
  placeholder's buffer name (`ui/scratch.lua`) has no per-view component, so sidebyside and
  unified can end up sharing the exact same buffer for the same file. `Session:set_mode`
  opens the incoming view before closing the outgoing one, so the outgoing view's
  `close()` can run while the incoming view's window is already showing that shared buffer
  -- `nvim_buf_delete` closes every window still displaying the buffer it deletes, not just
  the caller's own, so deleting unconditionally would silently destroy the incoming
  view's window and drop focus back to the panel. Both views' `close()` skip the delete
  when `vim.fn.win_findbuf` still finds a window on it; whichever view still owns a
  window on it wipes it in its own `close()` later.

## Viewed state

- One JSON file per review under `stdpath('data')/diffly/`, filename =
  `sha256(kind .. "\0" .. repo .. "\0" .. suffix)`. Repo identity is the normalized
  remote URL, so worktrees and clones of the same repo share state.
- **Legacy dir migration** (`state.lua`, from the difit.nvim → diffly.nvim rename): the
  first `state_dir()` call in a session checks for a pre-rename `stdpath('data')/difit/`
  directory; if it exists and the new `diffly/` one doesn't yet, it's renamed wholesale
  (`vim.uv.fs_rename`, `pcall`'d) so existing `viewed` marks survive upgrading. A failed
  rename just falls through to the new (empty) directory rather than raising. Runs at most
  once per session, gated by `M._migrated`; `M._legacy_dir` mirrors `M._dir` as a
  test-only seam.
- A mark records the file's `(base_sha, head_sha)` blob pair; `is_viewed` requires the
  current pair to match — a file whose diff changed drops back to un-viewed (GitHub
  semantics), untouched files survive new commits. Worktree-side SHAs come from
  `git hash-object`.
- Bulk operations (`S`/`:Diffly sweep` over `viewed_patterns` groups, `V` over a subtree)
  are tri-state toggles (mark the un-viewed remainder, or unmark everything if all are
  viewed) through `Session:toggle_viewed_batch`: one `state.save`, one subscriber
  notification per batch. Pattern groups compile via `vim.glob.to_lpeg`; a pattern
  without `/` matches basenames, with `/` the toplevel-relative path.
- Marking is always explicit (`v`, `<leader>v`, `V`, `S`, `<Plug>` mappings) — never
  automatic.

## Deliberately rejected designs

Studied (diffview.nvim, codediff.nvim) and rejected — do not reintroduce without new
evidence, e.g. profiling data or a concrete user problem:

- **Async git runtime** (coroutine framework or callback layer): operations are
  one-file-at-a-time; synchronous `vim.system():wait()` is right-sized.
- **OOP class system / layout class hierarchy**: two sibling views satisfying one small
  interface don't need inheritance machinery.
- **C/FFI diff engine**: `git diff` (and `vim.diff()` if ever needed) suffice.
- **fs-watching / live `TextChanged` re-diff**: event-driven refresh (`BufWritePost`,
  `FocusGained`, manual `R`) is simpler and sufficient.
- **Automatic viewed-marking** (on scroll/open): silent marks hide unreviewed changes.
- **LRU blob caches / incremental render diffing**: renders are already cheap at review
  scale; caches add invalidation bugs.
- **TabLeave suspend/resume for keymaps**: unnecessary once attach/detach is scoped to
  "the buffer currently shown" with ownership tokens.

## Testing architecture

- mini.test; each `tests/test_<module>.lua` mirrors one module; `tests/test_e2e.lua`
  drives the whole plugin in a child Neovim, including screenshot goldens.
- git is never mocked: `tests/helpers.lua` builds real repositories
  (`new_repo`, `fixture_branch_repo`) in temp dirs. `gh` is faked with executable PATH
  shims (`path_shim` for in-process, `child_path_shim` for child Neovim).
- UI assertions go through the child's API (`helpers.new_child`); `vim.ui.select` is
  stubbed inside the child where menus are involved.
- Goldens: regenerate only what a legitimate rendering change affects; determinism
  pitfalls and policy are in CLAUDE.md.
