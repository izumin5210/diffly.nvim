# Pre-v1 refactoring plan

Synthesized from the v1 review findings plus architecture studies of diffview.nvim and
codediff.nvim (esmuellert/codediff.nvim). Goal: remove the structural debt found during
v1 development before tagging v1. Behavior-preserving except where flagged.

## Phases

Phases run sequentially (they touch overlapping files). Tests must be green after each.

### R1 — Session registry & lifecycle funnel (`init.lua`, `session.lua`)

Replaces the `M._session`/`M._panel`/`M._viewer_tab` singletons.

- `sessions` table keyed by **tabpage handle** (codediff `active_diffs` / diffview
  `lib.views` pattern), each entry holding `{ session, panel, origin_tab }`.
  `current_entry()` resolves via `nvim_get_current_tabpage()`.
- `:Difit` semantics: if a live session exists with the **same review key**, focus its
  tabpage; otherwise open a new viewer tabpage. Multiple concurrent reviews (different
  repos/bases) become possible. *(behavior change, flagged)*
- One idempotent `close(tabpage)`; every detector funnels into it:
  - explicit `:Difit close` / `q`,
  - `TabClosed` (reconcile registry against `nvim_list_tabpages()`, diffview
    `dispose_stray_views` pattern),
  - `WinClosed` with a `vim.w[win].difit` sentinel on difit-owned windows — when no
    difit window survives in the tab, tear the session down (codediff pattern).
- Global autocmds registered once behind a guard; per-session augroup for the
  BufWritePost/FocusGained refresh + debounce timer, stopped/cleared inside `close()`.

### R2 — View window ownership + explicit anchor (`ui/sidebyside.lua`, `ui/unified.lua`, `session.lua`)

Kills the root cause of the E1513/window-leak class of bugs.

- Views stop reading "the current window". `View:open(entry, spec, ctx)` where
  `ctx.anchor` is the winid to split from (the panel window) and `ctx.claim` is an
  optional window the view may absorb (the initial placeholder created with the tab).
- Views keep an `owned_wins` list; `close()` destroys every owned window (diffview
  `Layout:destroy`). Windows are validated and recreated on demand
  (`Layout:validate`/`ensure` pattern — `ensure_windows` already has the right shape).
- `Session:set_mode` order becomes **build new → open → then close old** (diffview
  `StandardView:use_entry`), so windows never vanish before replacements exist.
- Delete `reap_stray_windows`, `_known_view_wins`, `live_view_windows`, and the
  `is_unclaimable` guard (obsolete once views never claim the current window).

### R3 — Seam de-globalization (`ui/*.lua`, `init.lua`)

- Remove module-level `_on_toggle_viewed` / `_on_toggle_mode` / `_on_focus_panel` /
  `_on_close` slots from both views.
- Keymap callbacks capture the **tabpage** and resolve the live session through the R1
  registry on every keypress (codediff `ui/view/keymaps.lua` pattern; diffview actions
  do the same via `lib.get_current_view()`). An `actions` table built per session is
  passed through `ctx` for the views' buffer-local maps.
- `<Plug>` mappings and `M.toggle_viewed_current`/`M.toggle_mode`/`M.focus` resolve the
  current tabpage's session. Per-file keymap attach/detach on real buffers stays as-is
  (difit already handles the file-switch detach codediff lacks).

### R4 — Cleanup & polish (small, mostly independent)

- `ui/scratch.lua`: shared find-or-create helper for `difit://` scratch buffers
  (options, naming, reuse) — currently triplicated across panel/sidebyside/unified.
- LSP-safe syntax on `difit://` buffers (codediff finding): never fire FileType
  autocmds on custom-URI buffers (LSP `didOpen` on them can crash servers). Use
  `vim.treesitter.start(buf, lang)` when a parser exists, else set `syntax` directly.
- Error honesty in blob loading: `set_left`'s `git.file_content(...) or {}` silently
  renders an empty buffer on real git errors (codediff has the same trap, flagged as an
  anti-pattern). Distinguish "no blob at this rev" (legit empty) from errors (notify).
- `vim.fs.joinpath` for path joins; promote the child gh PATH-shim from
  `tests/test_github.lua`/`tests/test_e2e.lua` into `tests/helpers.lua`.
- Dead code: drop `RepoIdentity.git_dir` (and its extra subprocess per open),
  `PrInfo.owner_repo`, `Hunk.old_start`/`old_count` (the future inline overlay anchors
  on new-side positions; deleted text comes from hunk lines); single owner for
  `hl.setup()` (init.lua).

## Explicitly not adopting (studied and rejected)

- diffview's coroutine async runtime and codediff's async-callback git layer — difit's
  synchronous `vim.system():wait()` is right-sized for one-file-at-a-time operations;
  revisit only if profiling shows UI stalls.
- diffview's OOP class system and Diff1–4×Hor/Ver layout hierarchy (exists for
  merge-tool / multi-way diffs), generic Panel base + incremental renderer.
- codediff's C/FFI diff engine, LRU blob cache, live `TextChanged` re-diff loop,
  TabLeave suspend/resume, getter/setter accessor sprawl.

## Notes for the future inline-overlay unified view (v2) -- IMPLEMENTED

codediff's rendering model was the blueprint, now implemented in `ui/unified.lua`: the
real buffer (worktree file, HEAD blob, or deleted-file blob) holds the actual content;
"+" lines get a line-level `DifitOverlayAdd` extmark; each contiguous run of "-" lines
becomes ONE `virt_lines` extmark (`DifitOverlayDelete` chunks) anchored where the text
used to sit, with two anchoring edge cases confirmed against real `git diff -U3` output
(a deletion landing before the buffer's first/last real line clamps to row 0 or the last
line respectively -- see the comments on `ui/unified.lua`'s `compute_overlay` and the
edge-case tests in `tests/test_unified.lua`); one dedicated namespace per view instance;
full clear-and-redraw per render. R2's `View` contract (open/close/owned windows) was
exactly the seam it plugged into -- no changes to that contract were needed. The old
`git.hunks`-fed patch-text buffer and its `<CR>` jump-to-file machinery are gone.
