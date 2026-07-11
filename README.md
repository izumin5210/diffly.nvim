# difit.nvim

A [difit](https://github.com/yoshiko-pg/difit)-inspired diff viewer for Neovim: a
file-tree diff viewer (like diffview.nvim) with per-file **viewed** marks that persist
across viewer sessions for the same pull request.

<!-- TODO: screenshots -->

## Features

- File-tree panel listing everything changed between your current branch and its base
  branch (or a detected GitHub pull request), with status letters, `+`/`-` counts, folding,
  and directory compression.
- Diff display selectable between side-by-side (native Neovim diff mode) and unified
  (single column). Both show the real file — not a synthetic patch buffer — so you get the
  file's own syntax highlighting and LSP in either mode; unified overlays the diff on top
  with extmarks (deleted lines render as read-only virtual lines).
- Per-file **viewed** marks, persisted per PR (or per branch pair), shared across viewer
  sessions, worktrees, and clones of the same repo — but never carried over to a different
  PR. Marks invalidate automatically (GitHub-style) when either side of the diff changes.
- Bulk viewed marking, still explicit-trigger only: mark/unmark an entire directory
  subtree (`V`) or every file matching configurable glob patterns (`S` / `:Difit sweep`,
  `viewed_patterns` — e.g. lockfiles, generated output) in one step.
- Zero runtime dependencies: everything is built on `vim.system`, `vim.json`, and plain
  buffers/extmarks. `gh` and an icon provider are both optional, purely additive.

Out of scope for v1 (deliberately): arbitrary rev comparison (`difit A B`), staged/working-
only modes, inline comments, a flat-list panel toggle, filesystem-watch-based refresh.

## Requirements

- Neovim **0.12+**
- `git` on `$PATH`
- Optional: [`gh`](https://cli.github.com/) — enables PR-based base-branch detection and
  PR-keyed viewed state; falls back to a branch-pair key when absent.
- Optional: [mini.icons](https://github.com/echasnovski/mini.nvim) or
  [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) — enables file icons
  in the panel.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "izumin5210/difit.nvim",
  cmd = "Difit",
  opts = {},
}
```

`opts = {}` calls `require("difit").setup({})`; `setup()` is entirely optional otherwise —
the plugin works with its defaults untouched.

## Quickstart

```vim
:Difit          " review the current branch against its detected base
:Difit main     " review against an explicit base branch
:Difit close    " close the review UI and restore your previous layout
:Difit toggle   " open, or close if already open
:Difit refresh  " recompute the diff
:Difit focus    " focus the panel window from wherever you currently are
:Difit sweep    " bulk-toggle every file matching `viewed_patterns` (see below)
:Difit clean    " remove viewed state for the current review (prompts first)
:Difit clean all
```

`:Difit <Tab>` completes both the subcommands above and your repo's local branch names.

### Keymaps

No global keymaps are defined. Everything below is buffer-local and configurable via
`keymaps.universal`/`keymaps.panel`/`keymaps.diff` (see [Configuration](#configuration)).

difit.nvim uses a two-layer keymap model, modeled on diffview.nvim: a **universal** layer
of leader-prefixed keys that work identically in *every* difit context — the panel,
difit-owned diff buffers, and real file buffers shown in the viewer alike — plus **local**
single-key shortcuts that only apply where the buffer is difit-owned (so they can never
collide with a real file's own, unrelated keymaps).

#### Universal (all difit windows)

| Key         | Action                                             |
| ----------- | --------------------------------------------------- |
| `<leader>v` | Toggle viewed for the current file (auto-advances)   |
| `<leader>s` | Toggle side-by-side ⇔ unified                         |
| `<leader>e` | Focus the panel                                       |
| `]f`        | Open the next file (ALL files, not just un-viewed ones) |
| `[f`        | Open the previous file (ditto)                        |

Works everywhere: the panel, difit-owned blob buffers, and real file buffers currently
shown in the viewer — worktree-mode side-by-side's right-hand window, and worktree-mode
unified's single window alike — the one place these keys matter most, since real buffers
get no local shortcuts at all. There is no universal `close`: closing a real file buffer
isn't "closing the review".

`]f`/`[f` always cycle through every file in the review, regardless of the panel's `H`
filter below (see [File panel](#file-panel)) — the filter only changes what's *drawn* in
the tree, never what's *reachable*. Skipping already-viewed files while moving forward is
what `<leader>v`/`v`'s auto-advance is already for.

#### File panel

| Key    | Action                                                     |
| ------ | ------------------------------------------------------------- |
| `<CR>` | Open the file under the cursor / toggle a directory's fold      |
| `v`    | Toggle viewed (auto-advances to the next un-viewed file)        |
| `R`    | Refresh the diff                                                |
| `s`    | Toggle side-by-side ⇔ unified                                    |
| `q`    | Close the review UI                                             |
| `za`   | Toggle fold (mirrors native `za`)                                |
| `H`    | Toggle hiding already-viewed files (display only — see below)   |
| `S`    | Bulk-toggle every file matching `viewed_patterns` (see below)   |
| `V`    | On a directory row: bulk-toggle every file in that subtree. On a file row: same as `v` |

`H` only changes what the tree *shows*: progress counts (`3/12 viewed`) stay global, and
navigation (`]f`/`[f`, `<leader>v`'s auto-advance) is entirely unaffected. While active,
the progress line gains a `(hidden)` suffix, e.g. `3/12 viewed (hidden)`. Directories that
end up with no un-viewed files left disappear along with their contents.

`S` and `V` are described in full under [Bulk viewed marking](#bulk-viewed-marking).

#### difit diff buffers

Difit-owned buffers only — the side-by-side blob windows, and unified's own blob buffers
(HEAD mode, or a deleted file's read-only content) — never real file buffers, which get
only the universal layer above.

| Key | Action                              |
| --- | ------------------------------------ |
| `v` | Toggle viewed for the current file   |
| `s` | Toggle side-by-side ⇔ unified         |
| `q` | Close the review UI                   |

`<Plug>` mappings are also available if you'd rather bind your own keys (e.g. to reach
these actions from buffers difit doesn't map by default):

```lua
vim.keymap.set("n", "<leader>gv", "<Plug>(difit-toggle-viewed)")
vim.keymap.set("n", "<leader>gs", "<Plug>(difit-toggle-mode)")
vim.keymap.set("n", "<leader>gp", "<Plug>(difit-focus-panel)")
vim.keymap.set("n", "]f", "<Plug>(difit-next-file)")
vim.keymap.set("n", "[f", "<Plug>(difit-prev-file)")
```

## Configuration

Full defaults, exactly as declared in `lua/difit/config.lua`:

```lua
require("difit").setup({
  base = nil,             -- string|nil: base branch override
  right = "worktree",     -- "worktree"|"head"
  include_untracked = true,
  auto_advance = true,    -- jump to next un-viewed file after marking
  icons = true,           -- use mini.icons / nvim-web-devicons when present
  viewed_patterns = {},   -- glob patterns for bulk-viewed marking (`S`/`:Difit sweep`)
  panel = { width = 35 },
  keymaps = {
    panel = {
      open = "<CR>",        -- open file diff / toggle fold on a dir row
      toggle_viewed = "v",
      refresh = "R",
      toggle_mode = "s",    -- side-by-side <-> unified
      close = "q",
      fold = "za",
      toggle_hide_viewed = "H", -- hide/show already-viewed rows (display only)
      sweep = "S",                  -- bulk-toggle files matching `viewed_patterns`
      toggle_viewed_subtree = "V",  -- bulk-toggle every file under a dir row
    },
    -- applied ONLY in difit-owned buffers (blob/unified), IN ADDITION to keymaps.universal
    diff = { toggle_viewed = "v", toggle_mode = "s", focus_panel = "<leader>e", close = "q" },
    -- the universal layer: works everywhere (panel, owned diff buffers, AND real file
    -- buffers shown in the viewer); real file buffers get ONLY this group
    universal = {
      toggle_viewed = "<leader>v",
      toggle_mode = "<leader>s",
      focus_panel = "<leader>e",
      next_file = "]f", -- open the next file (ALL files, unaffected by keymaps.panel's H)
      prev_file = "[f", -- open the previous file (ditto)
    },
  },
})
```

Set any keymap value to `false` to disable it.

## Viewed-state semantics

Viewed marks are keyed by `owner/repo#number` when a GitHub PR is detected for the current
branch via `gh`, or otherwise by the repo identity plus the `base..head` branch pair — the
two keyspaces never mix, by design. Repo identity is the normalized remote URL when one
exists (shared across worktrees/clones), otherwise the worktree's toplevel path.

Marking a file records the pair of blob SHAs (base side, right-hand side) it had at that
moment; if either side no longer matches at render time, the file counts as un-viewed
again (GitHub-style invalidation), while files nobody touched keep their mark across any
number of new commits. See `:help difit-viewed-state` for the full details.

## Bulk viewed marking

Marking files "viewed" is still manual-trigger-only — nothing is ever marked as a side
effect of scrolling, opening, or refreshing a diff. `S` (panel) / `:Difit sweep` and `V`
(panel) are just two more explicit triggers, for when you want to mark (or unmark) several
files at once instead of one `v` press per file — e.g. lockfiles and generated output you
never intend to read line-by-line.

**`viewed_patterns`** — a list of glob patterns (gitignore-inspired), matched against every
file in the current diff:

- A pattern with **no `/`** matches the entry's **basename**, anywhere in the tree —
  `"*.lock"` matches both `yarn.lock` and `packages/api/Gemfile.lock`.
- A pattern **containing `/`** matches the **full toplevel-relative path** instead —
  `"dist/**"` matches everything under `dist/`, but not `packages/api/dist/bundle.js`.
- Patterns are compiled with `vim.glob.to_lpeg` (the same glob dialect Neovim's LSP client
  uses): `**` crosses directory boundaries, a single `*` does not.

```lua
require("difit").setup({
  viewed_patterns = {
    "*.lock",             -- yarn.lock, pnpm-lock.yaml, Gemfile.lock, anywhere in the tree
    "*.snap",              -- generated test snapshots, anywhere in the tree
    "dist/**",             -- everything under a top-level generated output dir
    "**/generated/**",     -- everything under any "generated" dir, at any depth
  },
})
```

An invalid pattern is skipped (never raises) and warned about once per Neovim session, not
once per sweep.

**`S`** (panel key) / **`:Difit sweep`** bulk-toggle every file matching `viewed_patterns`.
**`V`** (panel key), pressed on a directory row, bulk-toggles every file in that subtree
instead — no configuration needed; pressed on a file row, it behaves exactly like `v`.

Both are **tri-state**: if at least one matching/subtree file is currently un-viewed, the
whole batch is marked viewed; only once *every* file in the batch is already viewed does
pressing it again unmark them all. That makes repeating the same key a clean toggle rather
than a one-way ratchet. Each batch persists with a single save and reports a compact
result, e.g. `difit: marked 5 files as viewed` / `difit: unmarked 5 files`. Progress
(`3/12 viewed`) updates exactly like any other mark. `V` on a directory sees the subtree's
full file list regardless of the panel's `H` filter or folds — those are display concerns
only, same as everywhere else in the panel.

`config.auto_advance` applies after a batch exactly like `v`: a batch that **marked** files
jumps to the next un-viewed file afterward; a batch that **unmarked** files never does.

## Development

```sh
make deps   # clone mini.nvim (test dependency) into deps/
make test   # run the full mini.test suite
make lint   # stylua --check
make fmt    # stylua (auto-format)
```

Tests never mock git: `tests/helpers.lua` creates real repositories in temporary
directories, and only the `gh` layer is faked (a PATH shim). See `docs/design.md` and
`docs/plan.md` for the full design rationale and implementation plan.

## Credits

Inspired by [yoshiko-pg/difit](https://github.com/yoshiko-pg/difit).
