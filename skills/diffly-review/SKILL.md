---
name: diffly-review
description: Read and answer code-review comments in diffly.nvim (the user's local diff review inside Neovim), and leave your own inline review comments there. Use when the user asks you to address their diffly review comments, to review a branch and comment inline in their editor, or mentions diffly threads or `:Diffly`.
---

# diffly-review

diffly.nvim is a local diff-review UI inside the user's Neovim: a file panel plus
side-by-side/unified diffs, with inline comment threads stored per review (branch pair,
or the branch's GitHub PR). You drive it through its CLI:

```sh
DIFFLY="{{DIFFLY_BIN}}"
```

Run commands from inside the repository under review. Every command prints JSON on
stdout and errors on stderr. If the user has the review open in Neovim, your writes
appear in their UI instantly — even while their Neovim is Ctrl-Z suspended. With no
editor running, the same commands operate on the saved review state.

## Workflow

1. **Orient** — `"$DIFFLY" info`
   - `review_key` (PR-keyed or branch-pair), `base_ref`, `merge_base`, `live` (is a
     running Neovim holding this review?), `current_path` (what the user is looking at).
   - `files[]`: `path`, `status` (A/M/D/R), `additions`/`deletions`, `viewed` (has the
     human finished reading this file?), `comments` (thread count).
   - The CLI hands you coordinates; git hands you code — read the actual diff with
     `git diff <merge_base>` or `git show`.

2. **Read the review** — `"$DIFFLY" comments list`
   - Messages with **no `author` field are the human's** — treat those threads as your
     work queue. `"author": "agent"` marks messages you wrote.
   - `anchor.side`: `head` = the file as it is on disk now; `base` = the pre-change
     side. `start_line`..`end_line` are 1-based lines of that side's own content.
   - `anchor.outdated: true` = the commented code is gone from the current diff.
   - Add `--remote` to also list the GitHub PR's review threads (read-only, ids are
     opaque node ids, `resolved` flags included).

3. **Address feedback** — fix the code, then answer each handled thread:

   ```sh
   "$DIFFLY" comments reply c3 --body 'extracted the helper as suggested'
   ```

   Reply rather than delete: the human decides when a thread is done.
   `comments rm <id>` is for retracting your *own* mistaken notes only.

4. **Leave your own findings**:

   ```sh
   "$DIFFLY" comments add --file src/mod.lua --line 42 --body 'this races the timer'
   "$DIFFLY" comments add --file src/mod.lua --line 42 --end-line 48 --body -   # body from stdin
   "$DIFFLY" comments add --file src/mod.lua --side base --line 7 --body 'why was this removed?'
   ```

   `--side head` is the default. Comment on removed/old code with `--side base` (line
   numbers then refer to the base version). Bodies are markdown; keep them short and
   specific — one finding per thread.

5. **Walk the user somewhere** (live session only):

   ```sh
   "$DIFFLY" navigate --file src/mod.lua --line 42
   ```

   Exit code 2 means no editor is running — just tell the user in chat instead.

## Rules

- **Never mark files viewed.** No CLI for it exists, by design: "viewed" is the human's
  own reading progress.
- **Never submit the review to GitHub.** `:Diffly submit` posts under the human's
  identity; only they run it.
- Thread ids (`c1`, `c2`, …) come from `add`/`list` output — never invent them.
- Do not use `--headless` while the user's editor may be open: it bypasses the live
  session and the editor's next save can overwrite your write. It is only for repos
  where no Neovim is running at all.
- If a command hangs, the user's Neovim is likely stuck on a blocking prompt (e.g.
  hit-enter) — ask them to dismiss it.

## Output shapes

```jsonc
// comments list  (`remote` only with --remote)
{"comments": [{"id": "c3", "path": "src/mod.lua",
  "anchor": {"side": "head", "start_line": 4, "end_line": 4, "outdated": false},
  "messages": [{"body": "…", "created_at": "…", "author": "agent"}]}],
 "remote": [{"id": "PRRT_…", "path": "…", "resolved": false, "anchor": {"…": "…"},
  "messages": [{"author": "alice", "body": "…"}]}]}

// info
{"review_key": {"kind": "pr", "repo": "github.com/o/r", "pr_number": 7},
 "base_ref": "origin/main", "merge_base": "<sha>", "right": "worktree",
 "live": true, "server": "/path/to/socket", "current_path": "src/mod.lua",
 "files": [{"path": "src/mod.lua", "status": "M", "additions": 3, "deletions": 1,
   "binary": false, "viewed": false, "comments": 2}]}
```

`add` and `reply` print the affected thread; `rm` prints `{"deleted": "c3"}`.
Exit codes: 0 ok · 1 error (message on stderr) · 2 `navigate` without a live editor.
