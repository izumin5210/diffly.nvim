# diffly.nvim — working rules

File-tree diff viewer for Neovim with persistent per-file `viewed` marks (difit-inspired).
Behavior and the reasoning behind it: `docs/design.md`. Structure and load-bearing
mechanisms: `docs/architecture.md`. Read the relevant section there before changing the
corresponding code.

## Commands

- `make deps` — clone mini.nvim into `deps/` (test-only dependency; never touch `deps/`)
- `make test FILE=tests/test_x.lua` — one suite, use during development
- `make test` — full suite; must be green before you finish
- `make lint` / `make fmt` — stylua check / format

## Hard rules

- **Zero runtime dependencies.** `vim.*` stdlib only (`vim.system`, `vim.uv`, `vim.json`,
  `vim.fs`, `vim.glob`, ...). Neovim 0.12+.
- **Never mock git.** Tests build real repositories in temp dirs via `tests/helpers.lua`
  (`new_repo`, `fixture_branch_repo`). The only faked binary is `gh`, via
  `helpers.path_shim` / `helpers.child_path_shim`.
- TDD: failing test first. UI behavior is tested in child Neovim processes
  (`helpers.new_child`, mini.test).
- LuaCATS annotations on public APIs. Comments explain *why*, never *what*. English
  identifiers, comments, and test names.
- Never run `git commit/branch/push/stash` unless you are the orchestrating session and
  the work is verified.

## Screenshot goldens (`tests/screenshots/`)

Regenerate only when rendering legitimately changes, only the affected goldens, and rerun
the suite twice to prove determinism. Known flakiness sources (already handled in the e2e
setup — keep it that way): tempname-derived paths leaking into the statusline, the
tabline, and icon providers (goldens run with icons off, `showtabline=0`).

## Invariants — do not break these

- Views never read "the current window". Window placement flows through
  `ctx.anchor`/`ctx.claim`; views track the windows they create and destroy them in
  `close()` (`ui/sidebyside.lua`, `ui/unified.lua`).
- `Session:set_mode` opens the new view **before** closing the old one. Both views'
  lifetimes overlap on purpose; per-buffer ownership tokens keep keymap attach/detach
  correct across the overlap (`ui/keymaps.lua`).
- A view's `close()` must never delete an owned buffer another live window still shows.
  `ui/scratch.lua` buffer names have no per-view component, so sidebyside and unified can
  share one buffer (binary/head-mode/oversized placeholders); `nvim_buf_delete` closes
  every window still displaying the buffer it deletes, not just the caller's own —
  deleting unconditionally during the `set_mode` overlap above silently destroyed the
  incoming view's window and dropped focus back to the panel. Guard with
  `vim.fn.win_findbuf` before deleting (`ui/sidebyside.lua`, `ui/unified.lua`).
- Session teardown goes through `init.lua`'s idempotent `close_entry` funnel only
  (explicit close, `TabClosed` reconciliation, `WinClosed` sentinel all route there).
- No module-level mutable seams. Keymap actions resolve the live session through the
  tabpage-keyed registry at call time; stale actions notify instead of erroring.
- Every diffly keymap is buffer-local **and `nowait`** (buffer-local otherwise loses the
  ambiguity wait against longer global mappings).
- Real file buffers get only the leader-prefixed `keymaps.universal` layer — never
  single-key maps (they would shadow core editing keys), never `keymaps.diff`.
- `diffly://` buffers never get `'filetype'` set — a FileType event would trigger LSP
  `didOpen` on a custom URI, which can crash servers. Use `vim.treesitter.start` or
  `'syntax'` directly (`ui/scratch.lua` owns this).
- Viewed state is keyed per review (PR number, else branch pair) and invalidated by
  blob-SHA pair comparison — never by path alone (`state.lua`).
- Bulk viewed operations (`sweep`, subtree toggle) save state and notify subscribers
  exactly once per batch (`Session:toggle_viewed_batch`).
- Viewed marking is always an explicit user action. No automatic marking, no fs-watching
  (`docs/architecture.md` lists rejected designs — don't reintroduce them without new
  evidence).
- Comment virt_lines live in a per-view comment namespace owned by the view — never by
  `ui/comments.lua`, and never unified's overlay ns ("one ns per concern"). A real buffer
  must be stripped of it whenever the view stops showing that buffer (same rule as
  `keymaps.universal`), and `close()` clears it from surviving shared owned buffers.
- Comment anchors persist `(side, lines, sha, snapshot)` and are rewritten ONLY in
  `session.lua`'s build/refresh re-anchor pass — render code never writes state. Outdated
  threads never render inline (panel `✎N` + `:Diffly comments` are the discoverability
  channels).
- Same-position virt_lines from different namespaces have NO stable stacking order
  (`priority` has no effect on them; the marktree reshuffles equal keys across
  clear-and-redraw repaints — measured on 0.12.3). Never make cross-namespace stacking
  depend on paint order: unified anchors deletion runs BELOW the preceding row
  (`compute_overlay`), a distinct marktree key that renders in the same visual gap but
  deterministically above the comment box's `(row, above)` mark. Pinned by the unified
  comments golden and test_unified's stacking case.
- Comment bodies soft-wrap at render time to the showing window's width capped by
  `comments.max_width` (`ui/comments.lua` `wrap_line`/`wrap_width`) — virt_lines never
  wrap natively, and the window `'wrap'` option is never touched (code windows keep the
  user's setting). Display-only: stored bodies and `cy`/`cY` output stay original. Width
  changes repaint via `Session:refresh_comment_render`: the debounced
  WinResized/VimResized hook in `init.lua` plus a synchronous repaint at the end of
  `set_mode` (the open-before-close overlap opens the new view transiently narrow).
- Remote review threads are session-held and read-only — never written into the
  persisted ReviewState. The views render them through `threads_for_render`; cursor
  actions read `state.comments` only.
- `github.fetch_threads` is the ONE async subprocess pattern: completions wholly
  `vim.schedule`d, re-resolving `entries[tab]` (silent when closed), handle cancelled in
  `close_entry`. Don't add more async seams; git stays synchronous.
- The debounced `BufWritePost`/`FocusGained` refresh NEVER refetches remote threads —
  only explicit user actions (`:Diffly refresh`, panel `R`, post-submit) do. Saving a
  file must not become network traffic (e2e pins this against the gh shim's call log).
- Submitting a review mutates the local store ONLY after a successful POST (the endpoint
  is atomic; on failure every draft must remain intact), and `plan_submission` never
  mutates the drafts it maps.
- The agent bridge writes through a live session whenever one exists: `bin/diffly`
  probes (`--server` → `$NVIM` → serverlist peers) and dispatches via RPC; headless
  writes are only for sessionless repos, and an explicit `--server` miss refuses instead
  of falling back (a second state writer clobbers the live session's save and collides
  on `comment_seq`). CLI stdout is machine-readable JSON only — under `nvim -l`,
  `print()`/`vim.notify` land on stderr; never write to stdout from plugin code.

## Git workflow

Conventional Commits (`feat:`/`fix:`/`refactor:`/`docs:`/...), feature branches, draft
PRs. Small commits per logical unit.

Releases are automated with [tagpr](https://github.com/Songmu/tagpr): git tags are the
only version source (no in-repo version file), and merging tagpr's release PR cuts the
tag, CHANGELOG, and GitHub Release. See `docs/releasing.md` — never tag by hand.
