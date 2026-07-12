---@meta
-- Shared type contracts for diffly.nvim. This file is never `require`d; it exists purely
-- for LuaCATS annotations / editor tooling, so every WP shares one vocabulary instead of
-- redefining ad-hoc shapes.

---@class diffly.RepoIdentity
---@field id string        -- normalized remote URL ("github.com/owner/repo") or toplevel path
---@field toplevel string  -- absolute path of the worktree root

---@class diffly.ReviewKey
---@field kind "pr"|"branch"
---@field repo string           -- RepoIdentity.id
---@field pr_number integer?    -- kind == "pr"
---@field base string?          -- kind == "branch": base branch name
---@field head string?          -- kind == "branch": head branch name

---@class diffly.DiffSpec
---@field repo diffly.RepoIdentity
---@field base_ref string    -- resolved base ref, e.g. "origin/main"
---@field merge_base string  -- merge-base commit SHA (left side of every diff)
---@field right "worktree"|"head"
---@field review_key diffly.ReviewKey
---@field generated_attrs table<string, string>  -- path -> raw `git check-attr
--- linguist-generated` value (absent key == "unspecified"); batched once per session
--- build/refresh by `session.lua`, consumed by `ui/guard.lua`'s `M.is_generated`

---@class diffly.FileEntry
---@field path string          -- current path, relative to toplevel
---@field old_path string?     -- set for renames
---@field status "A"|"M"|"D"|"R"
---@field untracked boolean    -- true for files not yet known to git (status "A")
---@field binary boolean
---@field additions integer    -- 0 when binary
---@field deletions integer    -- 0 when binary
---@field base_sha string?     -- blob SHA at merge-base; nil when added/untracked
---@field head_sha string?     -- blob SHA of right side; nil when deleted

---@class diffly.Hunk
---@field old_start integer -- base-side origin; consumed by base-side comment anchoring
---@field new_start integer
---@field new_count integer
---@field header string    -- full "@@ ... @@ ..." line
---@field lines string[]   -- body lines incl. leading " ", "+", "-", "\" markers

---@class diffly.ViewedRecord
---@field base_sha string|vim.NIL  -- vim.NIL encodes "no base blob" (added file) in JSON
---@field head_sha string|vim.NIL
---@field marked_at string         -- ISO8601 UTC

---@class diffly.CommentAnchor
---@field side "base"|"head"    -- diffly-neutral vocabulary; provider-specific side names
--- (GitHub's LEFT/RIGHT etc.) never appear in core types
---@field start_line integer    -- 1-based, inclusive, within the side's own content
---@field end_line integer      -- >= start_line; == start_line for a single-line comment
---@field sha string            -- blob sha of the side's content this anchor was last
--- valid against (base: FileEntry.base_sha; head: FileEntry.head_sha)
---@field snapshot string[]     -- exact text of start_line..end_line at anchor time; the
--- re-anchor search key. Never rewritten on a successful move (an exact match means
--- identical text anyway).
---@field outdated boolean?     -- true when the last re-anchor pass could not find the
--- snapshot; absent (nil) otherwise -- never false, so JSON stays minimal

---@class diffly.CommentMessage
---@field body string           -- markdown
---@field created_at string     -- ISO8601 UTC
---@field updated_at string?

---@class diffly.CommentThread
---@field id string             -- "c<N>" from ReviewState.comment_seq; unique per review
---@field path string           -- FileEntry.path at creation time
---@field anchor diffly.CommentAnchor
---@field messages diffly.CommentMessage[]  -- thread-shaped for future replies; the v1 UI
--- only ever creates/edits messages[1]

---@class diffly.ReviewState
---@field version integer
---@field key diffly.ReviewKey
---@field last_opened string
---@field viewed table<string, diffly.ViewedRecord>  -- keyed by FileEntry.path
---@field comments table<string, diffly.CommentThread[]>  -- keyed by FileEntry.path
---@field comment_seq integer   -- monotonic thread-id counter; only ever incremented

---@class diffly.RemoteAnchor
---@field side "base"|"head"    -- provider-translated; GitHub's LEFT/RIGHT never leaves github.lua
---@field start_line integer    -- startLine (or line when single-line); the ORIGINAL position
--- when the thread is outdated -- GitHub nulls the live line, but quickfix needs one
---@field end_line integer
---@field outdated boolean?     -- isOutdated verbatim; true-or-absent like the local convention

---@class diffly.RemoteMessage
---@field author string         -- comment author login; "ghost" when the account is gone
---@field body string

--- A review thread fetched from the forge -- session-held and read-only, NEVER written
--- into diffly.ReviewState. Deliberately a separate class from diffly.CommentThread (no
--- sha/snapshot: remote threads are never re-anchored or persisted) while staying
--- placement-compatible: ui/comments.lua's placement math only reads
--- anchor.side/start_line/end_line/outdated, which both classes share.
---@class diffly.RemoteThread
---@field id string             -- provider thread node id (opaque)
---@field path string
---@field anchor diffly.RemoteAnchor
---@field messages diffly.RemoteMessage[]  -- the full thread, replies included
---@field remote true
---@field resolved boolean      -- isResolved verbatim

--- Cancellation handle for an in-flight `fetch_threads` (the codebase's one async
--- subprocess pattern). `cancel` is idempotent: kills the underlying process and
--- suppresses the completion callback.
---@class diffly.FetchHandle
---@field cancel fun()

--- The forge-provider contract (docs/design.md "Comments"): the functions the comment
--- feature consumes, in diffly-neutral vocabulary. `lua/diffly/github.lua` is the sole
--- implementation -- deliberately no registry/config until a second forge exists.
---@class diffly.Provider
---@field available fun(): boolean
---@field detect_pr fun(repo: diffly.RepoIdentity): diffly.PrInfo|nil, string|nil
---@field fetch_threads fun(repo: diffly.RepoIdentity, pr: diffly.PrInfo, on_done: fun(threads_by_path: table<string, diffly.RemoteThread[]>|nil, err: string|nil)): diffly.FetchHandle|nil, string|nil
---@field submit_review fun(repo: diffly.RepoIdentity, pr: diffly.PrInfo, submission: diffly.ReviewSubmission): boolean|nil, string|nil
