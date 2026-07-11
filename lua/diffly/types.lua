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
---@field new_start integer
---@field new_count integer
---@field header string    -- full "@@ ... @@ ..." line
---@field lines string[]   -- body lines incl. leading " ", "+", "-", "\" markers

---@class diffly.ViewedRecord
---@field base_sha string|vim.NIL  -- vim.NIL encodes "no base blob" (added file) in JSON
---@field head_sha string|vim.NIL
---@field marked_at string         -- ISO8601 UTC

---@class diffly.ReviewState
---@field version integer
---@field key diffly.ReviewKey
---@field last_opened string
---@field viewed table<string, diffly.ViewedRecord>  -- keyed by FileEntry.path
