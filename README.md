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
  (single-column patch view).
- Per-file **viewed** marks, persisted per PR (or per branch pair), shared across viewer
  sessions, worktrees, and clones of the same repo — but never carried over to a different
  PR. Marks invalidate automatically (GitHub-style) when either side of the diff changes.
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
:Difit clean    " remove viewed state for the current review (prompts first)
:Difit clean all
```

`:Difit <Tab>` completes both the subcommands above and your repo's local branch names.

### Keymaps

No global keymaps are defined; everything below is buffer-local to difit's own buffers and
configurable via `keymaps.panel`/`keymaps.diff` (see [Configuration](#configuration)).

| Where        | Key    | Action                                                      |
| ------------ | ------ | ------------------------------------------------------------ |
| Panel        | `<CR>` | Open the file under the cursor / toggle a directory's fold  |
| Panel        | `v`    | Toggle viewed (auto-advances to the next un-viewed file)    |
| Panel        | `R`    | Refresh the diff                                            |
| Panel        | `s`    | Toggle side-by-side ⇔ unified                                |
| Panel        | `q`    | Close the review UI                                         |
| Panel        | `za`   | Toggle fold (mirrors native `za`)                            |
| Diff buffers | `v`    | Toggle viewed for the current file                           |
| Unified diff | `<CR>` | Jump to the corresponding real-file line (hardcoded)         |

Real file buffers (e.g. the side-by-side view's right-hand window) get no default mapping;
map `<Plug>(difit-toggle-viewed)` yourself to toggle viewed from there too:

```lua
vim.keymap.set("n", "<leader>gv", "<Plug>(difit-toggle-viewed)")
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
  panel = { width = 35 },
  keymaps = {
    panel = {
      open = "<CR>",        -- open file diff / toggle fold on a dir row
      toggle_viewed = "v",
      refresh = "R",
      toggle_mode = "s",    -- side-by-side <-> unified
      close = "q",
      fold = "za",
    },
    -- applied ONLY in difit-owned buffers (blob/unified), never real files
    diff = { toggle_viewed = "v" },
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
