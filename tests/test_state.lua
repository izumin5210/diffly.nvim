-- Tests for lua/diffly/state.lua: viewed-state persistence (file_path, load, save, mark,
-- unmark, is_viewed, clean). No real git repo is needed here -- shas are just opaque
-- strings from state.lua's point of view -- so plain fixture tables stand in for
-- diffly.ReviewKey / diffly.FileEntry. The state directory is redirected to a fresh temp
-- dir per test via the documented `M._dir` test seam so runs never touch the real
-- stdpath('data') location or leak between cases.

local state = require("diffly.state")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      state._dir = vim.fn.tempname()
      vim.fn.mkdir(state._dir, "p")
      -- Also redirect the legacy-dir seam to an unused tempname (never created) so the
      -- one-time migration's `fs_stat` finds nothing and no-ops -- otherwise it would
      -- fall back to the real `stdpath('data')/difit`, which this plugin's own pre-rename
      -- installs may genuinely have populated on this machine.
      state._legacy_dir = vim.fn.tempname()
      -- Every case gets its own migration attempt instead of inheriting whichever case
      -- happened to run first in this process.
      state._migrated = false
    end,
    post_case = function()
      vim.fn.delete(state._dir, "rf")
      state._dir = nil
      if state._legacy_dir then
        vim.fn.delete(state._legacy_dir, "rf")
      end
      state._legacy_dir = nil
      state._migrated = false
    end,
  },
})

local branch_key =
  { kind = "branch", repo = "github.com/owner/repo", base = "main", head = "feature" }

T["load() returns a fresh state when no file exists"] = function()
  local st = state.load(branch_key)
  eq(st.version, 1)
  eq(st.key, branch_key)
  eq(st.viewed, {})
end

T["mark -> save -> load round-trips records"] = function()
  local st = state.load(branch_key)
  local entry = { path = "src/a.lua", base_sha = "aaa", head_sha = "bbb" }
  state.mark(st, entry)
  state.save(st)

  local reloaded = state.load(branch_key)
  eq(reloaded.viewed["src/a.lua"].base_sha, "aaa")
  eq(reloaded.viewed["src/a.lua"].head_sha, "bbb")
  eq(type(reloaded.viewed["src/a.lua"].marked_at), "string")
end

T["is_viewed() true for a matching sha pair"] = function()
  local st = state.load(branch_key)
  local entry = { path = "src/a.lua", base_sha = "aaa", head_sha = "bbb" }
  state.mark(st, entry)
  eq(state.is_viewed(st, entry), true)
end

T["is_viewed() false after head_sha changes (new commit invalidates)"] = function()
  local st = state.load(branch_key)
  state.mark(st, { path = "src/a.lua", base_sha = "aaa", head_sha = "bbb" })

  local changed = { path = "src/a.lua", base_sha = "aaa", head_sha = "ccc" }
  eq(state.is_viewed(st, changed), false)
end

T["is_viewed() false after base_sha changes (rebase invalidates)"] = function()
  local st = state.load(branch_key)
  state.mark(st, { path = "src/a.lua", base_sha = "aaa", head_sha = "bbb" })

  local changed = { path = "src/a.lua", base_sha = "zzz", head_sha = "bbb" }
  eq(state.is_viewed(st, changed), false)
end

T["is_viewed() false for a path that was never marked"] = function()
  local st = state.load(branch_key)
  eq(state.is_viewed(st, { path = "src/never.lua", base_sha = "a", head_sha = "b" }), false)
end

T["nil base_sha (added file) round-trips through save/load and stays viewed"] = function()
  local st = state.load(branch_key)
  local entry = { path = "src/new.lua", base_sha = nil, head_sha = "bbb" }
  state.mark(st, entry)
  state.save(st)

  local reloaded = state.load(branch_key)
  eq(reloaded.viewed["src/new.lua"].base_sha, nil)
  eq(state.is_viewed(reloaded, entry), true)
end

T["unmark() removes a record"] = function()
  local st = state.load(branch_key)
  local entry = { path = "src/a.lua", base_sha = "aaa", head_sha = "bbb" }
  state.mark(st, entry)

  state.unmark(st, entry.path)

  eq(st.viewed[entry.path], nil)
  eq(state.is_viewed(st, entry), false)
end

T["save() is atomic: no .tmp file left behind on success"] = function()
  local st = state.load(branch_key)
  state.mark(st, { path = "src/a.lua", base_sha = "aaa", head_sha = "bbb" })
  state.save(st)

  local path = state.file_path(branch_key)
  eq(vim.uv.fs_stat(path) ~= nil, true)
  eq(vim.uv.fs_stat(path .. ".tmp"), nil)
end

T["save() overwrites an existing state file on a second save (vim.uv.fs_rename, not os.rename)"] = function()
  -- Regression for the Windows-only bug where `os.rename` (bare `MoveFileEx`, no
  -- REPLACE_EXISTING there) fails with EEXIST once the destination already exists --
  -- i.e. every save after the first one. This can't reproduce the Windows failure mode
  -- on POSIX CI, but it does exercise "save a second time onto an existing file",
  -- guarding against any regression in the atomic-overwrite path itself.
  local st = state.load(branch_key)
  state.mark(st, { path = "src/a.lua", base_sha = "aaa", head_sha = "bbb" })
  state.save(st)

  state.mark(st, { path = "src/b.lua", base_sha = "ccc", head_sha = "ddd" })
  state.save(st)

  local reloaded = state.load(branch_key)
  eq(reloaded.viewed["src/a.lua"].base_sha, "aaa")
  eq(reloaded.viewed["src/b.lua"].base_sha, "ccc")

  local path = state.file_path(branch_key)
  eq(vim.uv.fs_stat(path) ~= nil, true)
  eq(vim.uv.fs_stat(path .. ".tmp"), nil)
end

T["save() stamps last_opened"] = function()
  local st = state.load(branch_key)
  eq(st.last_opened, nil)
  state.save(st)
  eq(type(st.last_opened), "string")
  eq(st.last_opened:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil, true)
end

T["corrupt JSON file: load() returns a fresh state and warns once"] = function()
  local path = state.file_path(branch_key)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "{ not valid json" }, path, "b")

  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notified, { msg = msg, level = level })
  end
  local ok, st = pcall(state.load, branch_key)
  vim.notify = orig_notify

  eq(ok, true)
  eq(st.version, 1)
  eq(st.viewed, {})
  eq(#notified, 1)
  eq(notified[1].level, vim.log.levels.WARN)

  -- The corrupt file itself is left untouched, not deleted.
  eq(vim.fn.readfile(path), { "{ not valid json" })
end

T["file_path(): the same key always yields the same path"] = function()
  local a = state.file_path(branch_key)
  local b = state.file_path(branch_key)
  eq(a, b)
end

T["file_path(): distinct keys (pr vs pr, pr vs branch, branch pair vs branch pair) differ"] = function()
  local pr1 = { kind = "pr", repo = "github.com/owner/repo", pr_number = 1 }
  local pr2 = { kind = "pr", repo = "github.com/owner/repo", pr_number = 2 }
  local branch1 =
    { kind = "branch", repo = "github.com/owner/repo", base = "main", head = "feature" }
  local branch2 = { kind = "branch", repo = "github.com/owner/repo", base = "main", head = "other" }

  local paths = {
    pr1 = state.file_path(pr1),
    pr2 = state.file_path(pr2),
    branch1 = state.file_path(branch1),
    branch2 = state.file_path(branch2),
  }

  local seen = {}
  for name, p in pairs(paths) do
    eq(seen[p], nil)
    seen[p] = name
  end
end

T["clean({all=true}) removes every state file and returns the removed count"] = function()
  local other_key = { kind = "pr", repo = "github.com/owner/repo", pr_number = 42 }
  state.save(state.load(branch_key))
  state.save(state.load(other_key))

  local removed = state.clean({ all = true })

  eq(removed, 2)
  eq(vim.uv.fs_stat(state.file_path(branch_key)), nil)
  eq(vim.uv.fs_stat(state.file_path(other_key)), nil)
end

T["clean({key=...}) removes only that review's file"] = function()
  local other_key = { kind = "pr", repo = "github.com/owner/repo", pr_number = 42 }
  state.save(state.load(branch_key))
  state.save(state.load(other_key))

  local removed = state.clean({ key = branch_key })

  eq(removed, 1)
  eq(vim.uv.fs_stat(state.file_path(branch_key)), nil)
  eq(vim.uv.fs_stat(state.file_path(other_key)) ~= nil, true)
end

T["legacy dir migration: an existing pre-rename dir is renamed wholesale on first use"] = function()
  -- This test manages its own dirs instead of the pre_case default: migration only fires
  -- when the *new* dir doesn't exist yet, so the eagerly-mkdir'd `state._dir` from
  -- pre_case would suppress it.
  vim.fn.delete(state._dir, "rf")
  local old_dir = vim.fn.tempname()
  local new_dir = vim.fn.tempname()
  vim.fn.mkdir(old_dir, "p")
  vim.fn.writefile({ "legacy" }, old_dir .. "/leftover.json")

  state._dir = new_dir
  state._legacy_dir = old_dir
  state._migrated = false

  local st = state.load(branch_key)
  state.mark(st, { path = "src/a.lua", base_sha = "aaa", head_sha = "bbb" })
  state.save(st)

  eq(vim.uv.fs_stat(old_dir), nil)
  eq(vim.uv.fs_stat(new_dir) ~= nil, true)
  eq(vim.fn.filereadable(new_dir .. "/leftover.json") == 1, true)

  local reloaded = state.load(branch_key)
  eq(reloaded.viewed["src/a.lua"].base_sha, "aaa")
end

T["legacy dir migration: does nothing when the new dir already exists"] = function()
  -- pre_case already created `state._dir`, so the new dir exists before any state op
  -- runs; a legacy dir sitting alongside it must survive untouched.
  local old_dir = vim.fn.tempname()
  vim.fn.mkdir(old_dir, "p")
  vim.fn.writefile({ "legacy" }, old_dir .. "/leftover.json")
  state._legacy_dir = old_dir

  state.save(state.load(branch_key))

  eq(vim.uv.fs_stat(old_dir) ~= nil, true)
  eq(vim.fn.filereadable(old_dir .. "/leftover.json") == 1, true)

  vim.fn.delete(old_dir, "rf")
end

T["legacy dir migration: does nothing when no legacy dir exists"] = function()
  -- pre_case's `state._legacy_dir` is an unused tempname (never created); this just
  -- documents that the common case (no pre-rename install) never touches the filesystem
  -- for the old dir beyond the stat check, and normal load/save still works.
  local st = state.load(branch_key)
  state.mark(st, { path = "src/a.lua", base_sha = "aaa", head_sha = "bbb" })
  state.save(st)

  local reloaded = state.load(branch_key)
  eq(reloaded.viewed["src/a.lua"].base_sha, "aaa")
end

return T
