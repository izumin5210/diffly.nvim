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

## Git workflow

Conventional Commits (`feat:`/`fix:`/`refactor:`/`docs:`/...), feature branches, draft
PRs. Small commits per logical unit.
