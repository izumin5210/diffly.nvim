-- Tests for lua/diffly/session.lua: the orchestration core (base resolution, review-key
-- derivation, viewed-state persistence, next-unviewed navigation, view lifecycle). Git is
-- never mocked -- every case drives a real repository via tests/helpers.lua. Only the
-- view (`opts.view_factory`) and `gh` (`opts.github`) seams are faked, exactly as
-- `diffly.SessionOpts` intends: both are injected values, not shimmed subprocesses.
--
-- Everything (session, its fakes, config, state) runs inside a child Neovim per test case
-- (never the test-runner process itself): the fakes need real Lua closures with shared
-- upvalues to record calls, and closures can't cross the child/parent RPC boundary, so
-- they are *defined inside the child* via `child.lua(...)` and driven from here only
-- through serializable arguments/results.

local helpers = dofile("tests/helpers.lua")

local eq = MiniTest.expect.equality

-- Installs, inside the child, a recording fake view factory and a stubbable fake
-- `github` module:
--   _G.__log            ordered {event="open"|"close", mode=..., path=...?} list
--   _G.__factory_modes   ordered list of modes `view_factory` was called with
--   _G.__pr_result       {info=diffly.PrInfo?, err=string?} returned by the next detect_pr
--   _G.__github_calls    number of times detect_pr was invoked
--   _G.__gh_available    boolean returned by the fake's `available()` (default true --
--                        matches the "gh works, just no PR" case being the silent one)
--   _G.__view_factory / _G.__fake_github  ready to pass as SessionOpts fields
local INSTALL_FAKES = [[
  _G.__log = {}
  _G.__factory_modes = {}

  local function make_view(mode)
    return {
      mode = mode,
      open = function(self, entry, _spec)
        table.insert(_G.__log, { event = "open", mode = self.mode, path = entry.path })
      end,
      close = function(self)
        table.insert(_G.__log, { event = "close", mode = self.mode })
      end,
      refresh_comments = function(self)
        table.insert(_G.__log, { event = "refresh_comments", mode = self.mode })
      end,
    }
  end

  _G.__view_factory = function(mode)
    table.insert(_G.__factory_modes, mode)
    return make_view(mode)
  end

  _G.__pr_result = { info = nil, err = "no fake pr configured" }
  _G.__github_calls = 0
  _G.__gh_available = true
  _G.__fake_github = {
    detect_pr = function(_repo)
      _G.__github_calls = _G.__github_calls + 1
      local r = _G.__pr_result
      return r.info, r.err
    end,
    available = function()
      return _G.__gh_available
    end,
  }
]]

---@param child table
local function install_fakes(child)
  child.lua(INSTALL_FAKES)
end

--- Configure what the fake `github.available()` returns on every subsequent call.
---@param child table
---@param available boolean
local function set_gh_available(child, available)
  child.lua("_G.__gh_available = ...", { available })
end

--- Replace `vim.notify` inside the child with one that records every call into
--- `_G.__notifications`, so tests can assert on the gh-missing notice (session.lua) --
--- without this, `vim.notify`'s real implementation would just print to `:messages`.
---@param child table
local function install_notify_capture(child)
  child.lua([[
    _G.__notifications = {}
    vim.notify = function(msg, level)
      table.insert(_G.__notifications, { msg = msg, level = level })
    end
  ]])
end

---@param child table
---@return table[]
local function notifications(child)
  return child.lua_get("_G.__notifications")
end

--- Configure what the fake `github.detect_pr` returns on its next call(s).
---@param child table
---@param info diffly.PrInfo?
---@param err string?
local function set_pr_result(child, info, err)
  -- `nil` in a leading arg position round-trips through nvim_exec_lua as `vim.NIL`
  -- (msgpack null), not a genuine Lua `nil` -- coerce it back so the fake's `detect_pr`
  -- returns exactly what a real "no PR" result looks like (plain nil, per github.lua).
  child.lua(
    [[
      local info, err = ...
      if info == vim.NIL then
        info = nil
      end
      _G.__pr_result = { info = info, err = err }
    ]],
    { info, err }
  )
end

--- Point the child's `diffly.state` module at a fresh directory (the documented `_dir`
--- test seam), so runs never touch the real `stdpath('data')` location.
---@param child table
---@param dir string
local function point_state_dir(child, dir)
  child.lua("require('diffly.state')._dir = ...", { dir })
end

--- `session.new(opts)` inside the child, with the fakes above pre-wired into
--- `view_factory`/`github`; `extra` overrides/adds SessionOpts fields (e.g. `base`,
--- `right`). Returns `{ok, err}` (never the session itself: it holds live closures that
--- can't cross the RPC boundary) -- callers use `session_field`/the method wrappers
--- below to inspect `_G.__session` afterwards.
---@param child table
---@param extra table?
---@return {ok: boolean, err: string?}
local function new_session(child, extra)
  return child.lua(
    [[
      local extra = ...
      local opts = vim.tbl_extend(
        "force",
        { view_factory = _G.__view_factory, github = _G.__fake_github },
        extra or {}
      )
      local session, err = require("diffly.session").new(opts)
      _G.__session = session
      return { ok = session ~= nil, err = err }
    ]],
    { extra or {} }
  )
end

--- `child.lua_get`/`child.lua` return `vim.NIL` (msgpack null) for a genuine Lua `nil`
--- crossing the RPC boundary, not plain `nil` -- normalize it back so callers can compare
--- against `nil` the way they would for an in-process value.
---@param v any
---@return any
local function denil(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---@param child table
---@param expr string @Lua expression relative to `_G.__session`, e.g. "spec.base_ref"
local function session_field(child, expr)
  return denil(child.lua_get("_G.__session." .. expr))
end

---@param child table
---@return string[]
local function entry_paths(child)
  return child.lua_get([[(function()
    local paths = {}
    for _, e in ipairs(_G.__session.entries) do
      table.insert(paths, e.path)
    end
    return paths
  end)()]])
end

---@param child table
---@param path string
---@return boolean
local function toggle_viewed(child, path)
  return child.lua("return _G.__session:toggle_viewed(...)", { path })
end

---@param child table
---@param path string
---@return boolean
local function is_viewed(child, path)
  return child.lua("return _G.__session:is_viewed(...)", { path })
end

---@param child table
---@param after_path string?
---@return string|nil
local function next_unviewed(child, after_path)
  if after_path == nil then
    return denil(child.lua_get("_G.__session:next_unviewed()"))
  end
  return denil(child.lua("return _G.__session:next_unviewed(...)", { after_path }))
end

---@param child table
---@param after_path string?
---@return string|nil
local function next_file(child, after_path)
  if after_path == nil then
    return denil(child.lua_get("_G.__session:next_file()"))
  end
  return denil(child.lua("return _G.__session:next_file(...)", { after_path }))
end

---@param child table
---@param before_path string?
---@return string|nil
local function prev_file(child, before_path)
  if before_path == nil then
    return denil(child.lua_get("_G.__session:prev_file()"))
  end
  return denil(child.lua("return _G.__session:prev_file(...)", { before_path }))
end

---@param child table
---@return {viewed: integer, total: integer}
local function progress(child)
  return child.lua_get("_G.__session:progress()")
end

---@param child table
---@param path string
local function open_file(child, path)
  child.lua("_G.__session:open_file(...)", { path })
end

---@param child table
---@param mode "sidebyside"|"unified"
local function set_mode(child, mode)
  child.lua("_G.__session:set_mode(...)", { mode })
end

---@param child table
local function refresh(child)
  child.lua("_G.__session:refresh()")
end

---@param child table
local function close_session(child)
  child.lua("_G.__session:close()")
end

--- Installs a subscriber that just counts notifications; read it back with
--- `notify_count`.
---@param child table
local function install_notify_counter(child)
  child.lua([[
    _G.__notify_count = 0
    _G.__session:subscribe(function()
      _G.__notify_count = _G.__notify_count + 1
    end)
  ]])
end

---@param child table
---@return integer
local function notify_count(child)
  return child.lua_get("_G.__notify_count")
end

---@param child table
---@return table[]
local function view_log(child)
  return child.lua_get("_G.__log")
end

---@param child table
---@return string[]
local function factory_modes(child)
  return child.lua_get("_G.__factory_modes")
end

---@param child table
---@param patterns string[]
local function set_viewed_patterns(child, patterns)
  child.lua("require('diffly.config').setup({ viewed_patterns = ... })", { patterns })
end

---@param child table
---@param paths string[]
---@return {marked: integer, unmarked: integer, matched: integer}
local function toggle_viewed_batch(child, paths)
  return child.lua("return _G.__session:toggle_viewed_batch(...)", { paths })
end

---@param child table
---@param group_name string?
---@return {marked: integer, unmarked: integer, matched: integer}
local function sweep_patterns(child, group_name)
  -- Wrapped in parens: `Session:sweep_patterns` now returns TWO values (result, scope/err
  -- -- see `sweep_with_scope` below for both of them at once), and `(...)` truncates a
  -- multi-value expression down to exactly one, the same trick Lua itself uses for
  -- `(f())`. Keeps every existing call site below (written against the pre-groups
  -- single-return signature) working unchanged.
  if group_name == nil then
    return child.lua_get("(_G.__session:sweep_patterns())")
  end
  return child.lua(
    "local group_name = ...; return (_G.__session:sweep_patterns(group_name))",
    { group_name }
  )
end

--- Both return values of ONE `sweep_patterns(group_name)` call, bundled into a single
--- table -- needed (rather than two separate single-purpose helpers each making their own
--- call) because `sweep_patterns` is tri-state: calling it twice to read `result` and
--- `scope` separately would itself flip un-marked files back to marked (or vice versa)
--- between the two calls, corrupting exactly the assertion the test is trying to make.
---@param child table
---@param group_name string?
---@return {result: {marked: integer, unmarked: integer, matched: integer}|nil, scope: string}
local function sweep_with_scope(child, group_name)
  -- `{ group_name }` would collapse to an empty args list when `group_name` is nil (same
  -- pitfall `next_unviewed`/`next_file`/`prev_file` above already work around) -- the
  -- child-side script reads `...` conditionally instead of relying on that collapsing
  -- back to a real `nil` on this side.
  if group_name == nil then
    return child.lua([[
      local result, scope = _G.__session:sweep_patterns()
      return { result = result, scope = scope }
    ]])
  end
  return child.lua(
    [[
      local group_name = ...
      local result, scope = _G.__session:sweep_patterns(group_name)
      return { result = result, scope = scope }
    ]],
    { group_name }
  )
end

---@param child table
---@return diffly.PatternGroupInfo[]
local function pattern_groups(child)
  return child.lua_get("_G.__session:pattern_groups()")
end

--- Spy on `require('diffly.state').save` inside the child, counting calls without changing
--- its behavior. `session.lua` holds the SAME cached module table `require()` returns, so
--- reassigning the field here is visible to every `state.save(...)` call session.lua makes.
---@param child table
local function install_save_spy(child)
  child.lua([[
    _G.__save_count = 0
    local state = require("diffly.state")
    local orig_save = state.save
    state.save = function(...)
      _G.__save_count = _G.__save_count + 1
      return orig_save(...)
    end
  ]])
end

---@param child table
---@return integer
local function save_count(child)
  return child.lua_get("_G.__save_count")
end

local T = MiniTest.new_set()

-- 1. base resolution precedence --------------------------------------------------------

T["M.new(): base resolution -- arg beats config beats detected PR base beats default"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature") -- current branch from here on
  repo:git({ "branch", "arg-base" })
  repo:git({ "branch", "pr-base" })
  -- "main" (repo:new_repo()'s default branch) doubles as the "default branch" fallback.

  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, { number = 999, base_ref = "pr-base" }, nil)

  -- opts.base wins over everything else, including a detected PR.
  local res = new_session(child, { base = "arg-base" })
  eq(res.ok, true)
  eq(session_field(child, "spec.base_ref"), "arg-base")

  -- No opts.base: the detected PR's base wins over the repo default; review_key becomes
  -- PR-kind.
  res = new_session(child, {})
  eq(res.ok, true)
  eq(session_field(child, "spec.base_ref"), "pr-base")
  eq(session_field(child, "spec.review_key.kind"), "pr")
  eq(session_field(child, "spec.review_key.pr_number"), 999)

  -- No opts.base, no PR detected: falls back to git.default_branch() ("main", the only
  -- well-known candidate that exists since there's no remote).
  set_pr_result(child, nil, "no pull requests found")
  res = new_session(child, {})
  eq(res.ok, true)
  eq(session_field(child, "spec.base_ref"), "main")
  eq(session_field(child, "spec.review_key.kind"), "branch")
  eq(session_field(child, "spec.review_key.base"), "main")
  eq(session_field(child, "spec.review_key.head"), "feature")

  -- config.get().base beats the (still no-PR) default, but loses to a later opts.base.
  child.lua([[require("diffly.config").options.base = "arg-base"]])
  res = new_session(child, {})
  eq(res.ok, true)
  eq(
    session_field(child, "spec.base_ref"),
    "arg-base",
    "config.base should win over the default branch"
  )

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["M.new(): errors when the base name doesn't resolve as a ref"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")

  local res = new_session(child, { base = "does-not-exist-anywhere" })
  eq(res.ok, false)
  eq(type(res.err), "string")

  child.stop()
  repo:destroy()
end

T["M.new(): opts.view_factory is required"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")

  local child = helpers.new_child(repo.dir)
  local res = child.lua([[
    local session, err = require("diffly.session").new({})
    return { ok = session ~= nil, err = err }
  ]])
  eq(res.ok, false)
  eq(type(res.err), "string")

  child.stop()
  repo:destroy()
end

-- 2. fixture repo: entries, branch review_key, right precedence ------------------------

T["M.new(): fixture repo -- entries, branch review_key (no PR), base/head naming"] = function()
  local repo, paths = helpers.fixture_branch_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr for this branch")

  local res = new_session(child, {})
  eq(res.ok, true)
  eq(session_field(child, "spec.base_ref"), "main")
  eq(session_field(child, "spec.review_key.kind"), "branch")
  eq(session_field(child, "spec.review_key.base"), "main")
  eq(session_field(child, "spec.review_key.head"), "feature")
  eq(entry_paths(child), { paths.deleted, paths.modified, paths.new, paths.renamed_to })

  child.stop()
  repo:destroy()
end

T["M.new(): DiffSpec.right comes from opts.right, else config.get().right"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")

  local res = new_session(child, { right = "head" })
  eq(res.ok, true)
  eq(session_field(child, "spec.right"), "head")

  child.lua([[require("diffly.config").options.right = "head"]])
  res = new_session(child, {})
  eq(res.ok, true)
  eq(
    session_field(child, "spec.right"),
    "head",
    "falls back to config.get().right when opts.right is absent"
  )

  child.stop()
  repo:destroy()
end

-- 3. toggle_viewed persistence -----------------------------------------------------------

T["toggle_viewed(): persists across M.new with the same key, not across a different branch pair"] = function()
  local repo, paths = helpers.fixture_branch_repo()

  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")

  eq(new_session(child, {}).ok, true)
  eq(is_viewed(child, paths.modified), false)
  eq(toggle_viewed(child, paths.modified), true)
  eq(is_viewed(child, paths.modified), true)

  -- Same repo, same branch pair ("main" base, "feature" head): a fresh M.new() loads the
  -- same state file and sees the mark.
  eq(new_session(child, {}).ok, true)
  eq(is_viewed(child, paths.modified), true)

  -- Switch to a different head branch (different review key, even with the same base and
  -- a change to the very same path): the mark must not carry over.
  repo:git({ "switch", "-q", "-c", "other", "main" })
  repo:write(paths.modified, { "changed on other branch" })
  repo:commit("feat: unrelated change on other branch")

  eq(new_session(child, {}).ok, true)
  eq(session_field(child, "spec.review_key.head"), "other")
  eq(is_viewed(child, paths.modified), false)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

-- 4. next_unviewed / progress ------------------------------------------------------------

T["next_unviewed()/progress(): skip viewed files, wrap around, nil once everything is viewed"] = function()
  local repo, paths = helpers.fixture_branch_repo()

  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  -- tree.file_order() over the fixture's single "src/" directory sorts alphabetically:
  -- gone.lua, mod.lua, new.lua, renamed.lua.
  local order = { paths.deleted, paths.modified, paths.new, paths.renamed_to }
  eq(entry_paths(child), order)

  eq(progress(child), { viewed = 0, total = 4 })
  eq(next_unviewed(child, nil), order[1])

  install_notify_counter(child)
  eq(toggle_viewed(child, order[1]), true)
  eq(toggle_viewed(child, order[2]), true)
  eq(notify_count(child), 2, "toggle_viewed() notifies subscribers")
  eq(progress(child), { viewed = 2, total = 4 })
  eq(next_unviewed(child, nil), order[3], "skips the two already-viewed files")

  eq(toggle_viewed(child, order[4]), true)
  eq(
    next_unviewed(child, order[4]),
    order[3],
    "wraps past the end back to the only remaining un-viewed file"
  )

  eq(toggle_viewed(child, order[3]), true)
  eq(progress(child), { viewed = 4, total = 4 })
  eq(next_unviewed(child, nil), nil)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

-- 4b. next_file()/prev_file() -------------------------------------------------------------

T["next_file()/prev_file(): cycle through ALL files (including viewed), wrap in both directions, nil-from-start/end"] = function()
  local repo, paths = helpers.fixture_branch_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  -- Same tree.file_order() source as next_unviewed: gone.lua, mod.lua, new.lua, renamed.lua.
  local order = { paths.deleted, paths.modified, paths.new, paths.renamed_to }
  eq(entry_paths(child), order)

  -- nil means "from the start"/"from the end".
  eq(next_file(child, nil), order[1])
  eq(prev_file(child, nil), order[4])

  -- Ordinary forward/backward steps.
  eq(next_file(child, order[1]), order[2])
  eq(next_file(child, order[2]), order[3])
  eq(prev_file(child, order[3]), order[2])
  eq(prev_file(child, order[2]), order[1])

  -- Wraps around at both ends.
  eq(next_file(child, order[4]), order[1], "wraps from the last file back to the first")
  eq(prev_file(child, order[1]), order[4], "wraps from the first file back to the last")

  -- Marking a file viewed must not remove it from next_file/prev_file's traversal --
  -- unlike next_unviewed, plain navigation always includes viewed files.
  eq(toggle_viewed(child, order[1]), true)
  eq(next_file(child, order[4]), order[1], "next_file still visits a viewed file")
  eq(prev_file(child, order[2]), order[1], "prev_file still visits a viewed file")

  child.stop()
  repo:destroy()
end

T["next_file()/prev_file(): nil when there are no files"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature") -- no further commits: the diff against main has zero entries

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  eq(entry_paths(child), {})

  eq(next_file(child, nil), nil)
  eq(prev_file(child, nil), nil)

  child.stop()
  repo:destroy()
end

-- 5. refresh() -----------------------------------------------------------------------------

T["refresh(): picks up a new commit and notifies subscribers"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature")
  repo:write("src/one.lua", "one\n")
  repo:commit("feat: add one")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  eq(entry_paths(child), { "src/one.lua" })

  repo:write("src/two.lua", "two\n")
  repo:commit("feat: add two")

  install_notify_counter(child)
  refresh(child)
  eq(notify_count(child), 1)
  eq(entry_paths(child), { "src/one.lua", "src/two.lua" })

  child.stop()
  repo:destroy()
end

-- 6. open_file() / set_mode() -------------------------------------------------------------

T["set_mode(): opens the new view via view_factory and reopens current_path BEFORE closing the old one"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature")
  repo:write("src/one.lua", "one\n")
  repo:commit("feat: add one")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  -- Constructing the session already built the initial (sidebyside) view.
  eq(factory_modes(child), { "sidebyside" })
  eq(session_field(child, "mode"), "sidebyside")

  open_file(child, "src/one.lua")
  eq(view_log(child), { { event = "open", mode = "sidebyside", path = "src/one.lua" } })
  eq(session_field(child, "current_path"), "src/one.lua")

  -- The counter is installed AFTER open_file() above, so its own notify (current_path
  -- changed nil -> "src/one.lua"; see the dedicated open_file() notify test) already fired
  -- and isn't part of this count -- set_mode() is the only source counted below.
  install_notify_counter(child)
  set_mode(child, "unified")

  eq(session_field(child, "mode"), "unified")
  eq(factory_modes(child), { "sidebyside", "unified" })
  eq(notify_count(child), 1)
  eq(view_log(child), {
    { event = "open", mode = "sidebyside", path = "src/one.lua" },
    { event = "open", mode = "unified", path = "src/one.lua" },
    { event = "close", mode = "sidebyside" },
  }, "view-ownership contract: the new view opens current_path before the old view closes")

  child.stop()
  repo:destroy()
end

T["set_mode(): with no current_path, only closes+recreates the view (no reopen)"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature")
  repo:write("src/one.lua", "one\n")
  repo:commit("feat: add one")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  set_mode(child, "unified")

  eq(view_log(child), { { event = "close", mode = "sidebyside" } })
  eq(session_field(child, "current_path"), nil)

  child.stop()
  repo:destroy()
end

-- 6b. open_file() notify-on-change (the panel's current-file row highlight relies on this:
-- ui/panel.lua's Panel:render highlights whichever row matches session.current_path, and
-- only re-renders on a subscriber notification) ------------------------------------------

T["open_file(): notifies subscribers when current_path changes, not when reopening the same path"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature")
  repo:write("src/one.lua", "one\n")
  repo:write("src/two.lua", "two\n")
  repo:commit("feat: add one and two")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  install_notify_counter(child)

  open_file(child, "src/one.lua")
  eq(notify_count(child), 1, "current_path changed from nil to src/one.lua")

  open_file(child, "src/one.lua")
  eq(notify_count(child), 1, "reopening the SAME path must not notify again")

  open_file(child, "src/two.lua")
  eq(notify_count(child), 2, "switching to a different file notifies once more")

  child.stop()
  repo:destroy()
end

-- 7. close() -------------------------------------------------------------------------------

T["close(): closes the view and saves state, even with no prior toggle"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature")
  repo:write("src/one.lua", "one\n")
  repo:commit("feat: add one")

  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  close_session(child)

  eq(view_log(child), { { event = "close", mode = "sidebyside" } })
  local saved = child.lua_get(
    [[vim.uv.fs_stat(require('diffly.state').file_path(_G.__session.spec.review_key)) ~= nil]]
  )
  eq(saved, true)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

-- 8. gh-missing one-time notice (finding 8) -----------------------------------------------

T["M.new(): notifies once per Neovim session when gh is unavailable and the branch-pair fallback is taken"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  install_notify_capture(child)
  set_pr_result(child, nil, "no pr")
  set_gh_available(child, false)

  eq(new_session(child, {}).ok, true)
  eq(new_session(child, {}).ok, true) -- a second session in the same Neovim process

  local notes = notifications(child)
  eq(#notes, 1, "the notice must fire exactly once across both M.new() calls")
  eq(notes[1].msg, "diffly: gh not found; viewed state is keyed by branch pair")
  eq(notes[1].level, vim.log.levels.INFO)

  child.stop()
  repo:destroy()
end

T["M.new(): does not notify when gh is available but simply has no PR for this branch"] = function()
  local repo = helpers.new_repo()
  repo:write("a.txt", "1\n")
  repo:commit("chore: base")
  repo:branch("feature")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  install_notify_capture(child)
  set_pr_result(child, nil, "no pull requests found")
  set_gh_available(child, true)

  eq(new_session(child, {}).ok, true)

  eq(#notifications(child), 0, "gh working with no PR is a normal, silent fallback")

  child.stop()
  repo:destroy()
end

-- 9. resolve_ref() falls back to a non-origin remote (finding 11) -------------------------

T["M.new(): resolves the base ref via a non-origin remote when only that remote has it"] = function()
  -- An "upstream"-only clone: the review key's base branch ("trunk") exists on a
  -- secondary remote but not locally and not under "origin" (there is no "origin"
  -- remote at all here) -- resolve_ref must still find "upstream/trunk".
  --
  -- The clone must share history with the bare source (so `merge_base` finds a real
  -- fork point), and `git clone --origin upstream` also checks out a *local* "trunk"
  -- branch tracking it -- which would resolve on its own and defeat the point of this
  -- test -- so it's deleted once "feature" is checked out instead.
  local upstream_src = helpers.new_repo()
  upstream_src:write("a.txt", "1\n")
  upstream_src:commit("chore: base")
  upstream_src:git({ "branch", "-m", "trunk" })

  local bare_dir = vim.fn.tempname()
  eq(vim.system({ "git", "clone", "-q", "--bare", upstream_src.dir, bare_dir }):wait().code, 0)

  local dir = vim.fn.tempname()
  eq(vim.system({ "git", "clone", "-q", "--origin", "upstream", bare_dir, dir }):wait().code, 0)
  eq(vim.system({ "git", "-C", dir, "config", "user.name", "diffly test" }):wait().code, 0)
  eq(
    vim.system({ "git", "-C", dir, "config", "user.email", "diffly-test@example.com" }):wait().code,
    0
  )
  eq(vim.system({ "git", "-C", dir, "config", "commit.gpgsign", "false" }):wait().code, 0)
  vim.fn.writefile({ "2" }, dir .. "/b.txt")
  eq(vim.system({ "git", "-C", dir, "add", "-A" }):wait().code, 0)
  eq(vim.system({ "git", "-C", dir, "commit", "-q", "-m", "chore: local work" }):wait().code, 0)
  eq(vim.system({ "git", "-C", dir, "switch", "-q", "-c", "feature" }):wait().code, 0)
  eq(vim.system({ "git", "-C", dir, "branch", "-D", "trunk" }):wait().code, 0)

  local child = helpers.new_child(dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")

  local res = new_session(child, { base = "trunk" })
  eq(res.ok, true)
  eq(session_field(child, "spec.base_ref"), "upstream/trunk")

  child.stop()
  vim.fn.delete(dir, "rf")
  upstream_src:destroy()
  vim.fn.delete(bare_dir, "rf")
end

-- 10. sweep_patterns() / toggle_viewed_batch() ---------------------------------------------

--- Purpose-built repo (not `fixture_branch_repo`, whose files don't exercise both glob
--- forms cleanly): two "*.lock" files at different depths plus one unrelated file, so a
--- basename pattern, a full-path pattern, and a "**" pattern each pick out a different
--- subset. Entries sort by path: "a/b/c.lock", "other.txt", "x/c.lock".
---@return diffly.test.Repo
local function lock_pattern_repo()
  local repo = helpers.new_repo()
  repo:write("base.txt", "base\n")
  repo:commit("chore: base")
  repo:branch("feature")
  repo:write("a/b/c.lock", "1\n")
  repo:write("x/c.lock", "2\n")
  repo:write("other.txt", "3\n")
  repo:commit("feat: add files")
  return repo
end

T["sweep_patterns(): a pattern with no '/' matches the entry's basename anywhere in the tree"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  set_viewed_patterns(child, { "*.lock" })
  eq(sweep_patterns(child), { marked = 2, unmarked = 0, matched = 2 })
  eq(is_viewed(child, "a/b/c.lock"), true)
  eq(is_viewed(child, "x/c.lock"), true)
  eq(is_viewed(child, "other.txt"), false, "the pattern must not match an unrelated file")

  child.stop()
  repo:destroy()
end

T["sweep_patterns(): a pattern containing '/' matches only the full toplevel-relative path"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  set_viewed_patterns(child, { "x/*.lock" })
  eq(sweep_patterns(child), { marked = 1, unmarked = 0, matched = 1 })
  eq(is_viewed(child, "x/c.lock"), true)
  eq(is_viewed(child, "a/b/c.lock"), false, "a single '*' must not cross a '/' boundary")

  child.stop()
  repo:destroy()
end

T["sweep_patterns(): '**' crosses directory boundaries (LSP glob semantics)"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  set_viewed_patterns(child, { "**/c.lock" })
  eq(sweep_patterns(child), { marked = 2, unmarked = 0, matched = 2 })
  eq(is_viewed(child, "a/b/c.lock"), true)
  eq(is_viewed(child, "x/c.lock"), true)

  child.stop()
  repo:destroy()
end

T["sweep_patterns(): tri-state -- marks every un-viewed match, then unmarks once all match"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, { "*.lock" })

  eq(sweep_patterns(child), { marked = 2, unmarked = 0, matched = 2 })
  eq(sweep_patterns(child), { marked = 0, unmarked = 2, matched = 2 }, "all matched -> unmark all")
  eq(sweep_patterns(child), { marked = 2, unmarked = 0, matched = 2 }, "toggles cleanly again")

  child.stop()
  repo:destroy()
end

T["sweep_patterns()/toggle_viewed_batch(): exactly ONE state.save and ONE subscriber notify per batch"] = function()
  local repo = lock_pattern_repo()

  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, { "*.lock" })

  install_save_spy(child)
  install_notify_counter(child)

  eq(sweep_patterns(child), { marked = 2, unmarked = 0, matched = 2 })
  eq(save_count(child), 1, "sweep_patterns() must save exactly once, not once per file")
  eq(notify_count(child), 1, "sweep_patterns() must notify subscribers exactly once")

  eq(toggle_viewed_batch(child, { "a/b/c.lock", "x/c.lock", "other.txt" }), {
    marked = 1,
    unmarked = 0,
    matched = 3,
  })
  eq(save_count(child), 2)
  eq(notify_count(child), 2)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["toggle_viewed_batch(): tri-state over an explicit path list, with correct marked/unmarked/matched counts"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  -- Pre-mark one of the three files individually, so the batch below mixes
  -- already-viewed and un-viewed entries -- exactly the case the tri-state rule exists for.
  eq(toggle_viewed(child, "a/b/c.lock"), true)

  local paths = { "a/b/c.lock", "x/c.lock", "other.txt" }
  eq(toggle_viewed_batch(child, paths), { marked = 2, unmarked = 0, matched = 3 })
  eq(is_viewed(child, "a/b/c.lock"), true)
  eq(is_viewed(child, "x/c.lock"), true)
  eq(is_viewed(child, "other.txt"), true)

  eq(
    toggle_viewed_batch(child, paths),
    { marked = 0, unmarked = 3, matched = 3 },
    "all viewed -> unmark all"
  )
  eq(is_viewed(child, "a/b/c.lock"), false)
  eq(is_viewed(child, "x/c.lock"), false)
  eq(is_viewed(child, "other.txt"), false)

  child.stop()
  repo:destroy()
end

T["sweep_patterns(): empty viewed_patterns (the default) returns all-zero counts and never saves"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  install_save_spy(child)
  install_notify_counter(child)

  eq(sweep_patterns(child), { marked = 0, unmarked = 0, matched = 0 })
  eq(save_count(child), 0, "an empty batch must not touch disk")
  eq(notify_count(child), 0, "an empty batch must not notify subscribers")

  child.stop()
  repo:destroy()
end

T["sweep_patterns(): a pattern matching nothing in the current diff returns all-zero counts"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, { "*.does-not-exist" })

  eq(sweep_patterns(child), { marked = 0, unmarked = 0, matched = 0 })

  child.stop()
  repo:destroy()
end

T["sweep_patterns(): an invalid pattern is skipped and warned about exactly once across repeated sweeps"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  install_notify_capture(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, { "[invalid" })

  eq(sweep_patterns(child), { marked = 0, unmarked = 0, matched = 0 })
  eq(sweep_patterns(child), { marked = 0, unmarked = 0, matched = 0 })

  local notes = notifications(child)
  eq(#notes, 1, "the same bad pattern must only warn once, however many sweeps run")
  eq(notes[1].level, vim.log.levels.WARN)
  eq(notes[1].msg:find("[invalid", 1, true) ~= nil, true)

  child.stop()
  repo:destroy()
end

T["sweep_patterns(): a valid pattern alongside an invalid one still matches, after warning once"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  install_notify_capture(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, { "[invalid", "*.lock" })

  eq(sweep_patterns(child), { marked = 2, unmarked = 0, matched = 2 })
  eq(#notifications(child), 1, "only the invalid pattern warns; the valid one just works")

  child.stop()
  repo:destroy()
end

T["toggle_viewed_batch(): paths absent from entries are silently ignored"] = function()
  local repo = lock_pattern_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  install_save_spy(child)

  eq(
    toggle_viewed_batch(child, { "does/not/exist.txt" }),
    { marked = 0, unmarked = 0, matched = 0 }
  )
  eq(save_count(child), 0)

  child.stop()
  repo:destroy()
end

-- 11. pattern_groups() / sweep_patterns(group_name) -- named pattern GROUPS ------------

--- Purpose-built repo for group-level tests: two lockfiles (both matched by a "lock
--- files" group's "*.lock"), one file under generated/ (matched by a "generated" group's
--- "generated/**"), and one file matched by neither -- entries sort by path: "a.lock",
--- "generated/out.txt", "other.txt", "z.lock".
---@return diffly.test.Repo
local function group_repo()
  local repo = helpers.new_repo()
  repo:write("base.txt", "base\n")
  repo:commit("chore: base")
  repo:branch("feature")
  repo:write("a.lock", "1\n")
  repo:write("z.lock", "2\n")
  repo:write("generated/out.txt", "3\n")
  repo:write("other.txt", "4\n")
  repo:commit("feat: add files")
  return repo
end

T["pattern_groups(): resolves config.viewed_patterns' groups against entries, with per-group matched paths and unviewed counts"] = function()
  local repo = group_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, {
    { name = "lock files", patterns = { "*.lock" } },
    { name = "generated", patterns = { "generated/**" } },
  })

  local groups = pattern_groups(child)
  eq(#groups, 2)
  eq(groups[1].name, "lock files")
  eq(groups[1].patterns, { "*.lock" })
  eq(groups[1].matched, { "a.lock", "z.lock" })
  eq(groups[1].unviewed, 2)
  eq(groups[2].name, "generated")
  eq(groups[2].matched, { "generated/out.txt" })
  eq(groups[2].unviewed, 1)

  toggle_viewed(child, "a.lock")
  eq(pattern_groups(child)[1].unviewed, 1, "marking one matched file drops that group's count")
  eq(pattern_groups(child)[2].unviewed, 1, "an unrelated group's count is unaffected")

  child.stop()
  repo:destroy()
end

T["pattern_groups(): flat string viewed_patterns (backward compat) resolve to a single 'default' group"] = function()
  local repo = group_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, { "*.lock" })

  local groups = pattern_groups(child)
  eq(#groups, 1)
  eq(groups[1].name, "default")
  eq(groups[1].matched, { "a.lock", "z.lock" })

  child.stop()
  repo:destroy()
end

T["pattern_groups(): no viewed_patterns configured yields no groups"] = function()
  local repo = group_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  eq(pattern_groups(child), {})

  child.stop()
  repo:destroy()
end

T["sweep_patterns(name): sweeps only the named group, resolving its own name as the scope"] = function()
  local repo = group_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, {
    { name = "lock files", patterns = { "*.lock" } },
    { name = "generated", patterns = { "generated/**" } },
  })

  local swept = sweep_with_scope(child, "lock files")
  eq(swept.result, { marked = 2, unmarked = 0, matched = 2 })
  eq(swept.scope, "lock files")
  eq(is_viewed(child, "a.lock"), true)
  eq(is_viewed(child, "z.lock"), true)
  eq(is_viewed(child, "generated/out.txt"), false, "sweeping one group must not touch another")

  child.stop()
  repo:destroy()
end

T["sweep_patterns(name): tri-state toggles cleanly within just that group, across repeated sweeps"] = function()
  local repo = group_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, { { name = "lock files", patterns = { "*.lock" } } })

  eq(sweep_patterns(child, "lock files"), { marked = 2, unmarked = 0, matched = 2 })
  eq(sweep_patterns(child, "lock files"), { marked = 0, unmarked = 2, matched = 2 })
  eq(sweep_patterns(child, "lock files"), { marked = 2, unmarked = 0, matched = 2 })

  child.stop()
  repo:destroy()
end

T["sweep_patterns(unknown name): returns nil plus an error, without touching any state"] = function()
  local repo = group_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, { { name = "lock files", patterns = { "*.lock" } } })

  install_save_spy(child)

  local swept = sweep_with_scope(child, "does-not-exist")
  eq(swept.result, nil)
  eq(type(swept.scope), "string")
  eq(swept.scope:find("does%-not%-exist") ~= nil, true)
  eq(save_count(child), 0, "an unknown group must never touch disk")
  eq(is_viewed(child, "a.lock"), false)

  child.stop()
  repo:destroy()
end

-- 12. comments: CRUD + re-anchoring ------------------------------------------------------

--- Purpose-built repo for comment tests: one file modified on the feature branch (both
--- base and head content exist) and one file added there (no base side -- the reject
--- case). src/one.lua's worktree content is what comments anchor against.
---@return diffly.test.Repo
local function comment_repo()
  local repo = helpers.new_repo()
  repo:write("src/one.lua", { "line one", "line two", "line three", "line four", "line five" })
  repo:commit("chore: base")
  repo:branch("feature")
  repo:write(
    "src/one.lua",
    { "line one", "line two", "line three CHANGED", "line four", "line five" }
  )
  repo:write("src/added.lua", { "new file line" })
  repo:commit("feat: change one, add added")
  return repo
end

---@param child table
---@param path string
---@param opts {side: string, start_line: integer, end_line: integer, body: string, snapshot: string[]}
---@return {ok: boolean, id: string?, err: string?}
local function add_comment(child, path, opts)
  return child.lua(
    [[
      local path, opts = ...
      local thread, err = _G.__session:add_comment(path, opts)
      return { ok = thread ~= nil, id = thread and thread.id or nil, err = err }
    ]],
    { path, opts }
  )
end

--- The review's state as re-read from DISK (not the in-memory table), for asserting that
--- comment mutations/re-anchors actually persisted.
---@param child table
---@param expr string @expression relative to the reloaded state, e.g. ".comments['p'][1]"
local function reloaded_state_field(child, expr)
  return denil(child.lua_get("require('diffly.state').load(_G.__session.spec.review_key)" .. expr))
end

T["add_comment(): persists, saves and notifies exactly once, and records the side's sha"] = function()
  local repo = comment_repo()
  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  install_save_spy(child)
  install_notify_counter(child)

  local res = add_comment(child, "src/one.lua", {
    side = "head",
    start_line = 3,
    end_line = 3,
    body = "why did this change?",
    snapshot = { "line three CHANGED" },
  })
  eq(res.ok, true)
  eq(res.id, "c1")
  eq(save_count(child), 1)
  eq(notify_count(child), 1)
  eq(view_log(child), { { event = "refresh_comments", mode = "sidebyside" } })

  -- The anchor sha is filled in by the session from the entry's head side.
  eq(
    session_field(child, "state.comments['src/one.lua'][1].anchor.sha"),
    session_field(child, "_entries_by_path['src/one.lua'].head_sha")
  )

  -- And it all reached disk, not just the in-memory table.
  eq(
    reloaded_state_field(child, ".comments['src/one.lua'][1].messages[1].body"),
    "why did this change?"
  )
  eq(reloaded_state_field(child, ".comment_seq"), 1)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["add_comment(): passes the author through to the stored message"] = function()
  local repo = comment_repo()
  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  local res = add_comment(child, "src/one.lua", {
    side = "head",
    start_line = 3,
    end_line = 3,
    body = "consider a guard clause",
    snapshot = { "line three CHANGED" },
    author = "agent",
  })
  eq(res.ok, true)
  eq(reloaded_state_field(child, ".comments['src/one.lua'][1].messages[1].author"), "agent")

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["reply_comment(): appends the reply, saves and notifies exactly once"] = function()
  local repo = comment_repo()
  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  local res = add_comment(child, "src/one.lua", {
    side = "head",
    start_line = 3,
    end_line = 3,
    body = "why did this change?",
    snapshot = { "line three CHANGED" },
  })
  eq(res.ok, true)

  child.lua("_G.__log = {}")
  install_save_spy(child)
  install_notify_counter(child)

  local replied = child.lua(
    [[return _G.__session:reply_comment((...), "c1", "fixed downstream", { author = "agent" }) ~= nil]],
    { "src/one.lua" }
  )
  eq(replied, true)
  eq(save_count(child), 1)
  eq(notify_count(child), 1)
  eq(view_log(child), { { event = "refresh_comments", mode = "sidebyside" } })

  eq(
    reloaded_state_field(child, ".comments['src/one.lua'][1].messages[2].body"),
    "fixed downstream"
  )
  eq(reloaded_state_field(child, ".comments['src/one.lua'][1].messages[2].author"), "agent")

  -- Unknown id: nil, and neither save nor notify fired again.
  local unknown = child.lua(
    [[return _G.__session:reply_comment((...), "c99", "x") == nil]],
    { "src/one.lua" }
  )
  eq(unknown, true)
  eq(save_count(child), 1)
  eq(notify_count(child), 1)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["add_comment(): rejects a side without content and an unknown path, touching nothing"] = function()
  local repo = comment_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  install_save_spy(child)
  install_notify_counter(child)

  -- src/added.lua only exists on the head side; its base side has nothing to anchor to.
  local res = add_comment(child, "src/added.lua", {
    side = "base",
    start_line = 1,
    end_line = 1,
    body = "x",
    snapshot = { "y" },
  })
  eq(res.ok, false)
  eq(type(res.err), "string")

  res = add_comment(child, "does/not/exist.lua", {
    side = "head",
    start_line = 1,
    end_line = 1,
    body = "x",
    snapshot = { "y" },
  })
  eq(res.ok, false)
  eq(type(res.err), "string")

  eq(save_count(child), 0)
  eq(notify_count(child), 0)

  child.stop()
  repo:destroy()
end

T["update_comment()/delete_comment(): persist and notify once each; comment_count tracks"] = function()
  local repo = comment_repo()
  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  local res = add_comment(child, "src/one.lua", {
    side = "head",
    start_line = 3,
    end_line = 3,
    body = "first draft",
    snapshot = { "line three CHANGED" },
  })
  eq(res.ok, true)
  eq(child.lua_get("_G.__session:comment_count('src/one.lua')"), 1)

  install_save_spy(child)
  install_notify_counter(child)

  eq(
    child.lua("return _G.__session:update_comment('src/one.lua', 'c1', 'second draft') ~= nil"),
    true
  )
  eq(save_count(child), 1)
  eq(notify_count(child), 1)
  eq(reloaded_state_field(child, ".comments['src/one.lua'][1].messages[1].body"), "second draft")

  eq(child.lua("return _G.__session:delete_comment('src/one.lua', 'c1')"), true)
  eq(save_count(child), 2)
  eq(notify_count(child), 2)
  eq(child.lua_get("_G.__session:comment_count('src/one.lua')"), 0)
  eq(reloaded_state_field(child, ".comments['src/one.lua']"), nil)

  -- Unknown ids are a no-op: no save, no notify.
  eq(child.lua("return _G.__session:delete_comment('src/one.lua', 'c9')"), false)
  eq(child.lua("return _G.__session:update_comment('src/one.lua', 'c9', 'x') ~= nil"), false)
  eq(save_count(child), 2)
  eq(notify_count(child), 2)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["toggle_comments_collapsed(): flips the session flag, notifies, and repaints via the view"] = function()
  local repo = comment_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  install_notify_counter(child)
  eq(session_field(child, "comments_collapsed"), false)

  child.lua("_G.__session:toggle_comments_collapsed()")
  eq(session_field(child, "comments_collapsed"), true)
  eq(notify_count(child), 1)
  eq(view_log(child), { { event = "refresh_comments", mode = "sidebyside" } })

  child.lua("_G.__session:toggle_comments_collapsed()")
  eq(session_field(child, "comments_collapsed"), false)

  child.stop()
  repo:destroy()
end

T["refresh(): re-anchors comments after worktree edits, persisting only when something moved"] = function()
  local repo = comment_repo()
  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  eq(
    add_comment(child, "src/one.lua", {
      side = "head",
      start_line = 3,
      end_line = 3,
      body = "why did this change?",
      snapshot = { "line three CHANGED" },
    }).ok,
    true
  )

  install_save_spy(child)

  -- Nothing changed: the steady-state fast path must not touch disk at all.
  refresh(child)
  eq(save_count(child), 0)
  eq(session_field(child, "state.comments['src/one.lua'][1].anchor.start_line"), 3)

  -- Two lines land above the commented one (an external edit, exactly what an AI agent
  -- rewriting the file looks like): the anchor must follow and the move must persist.
  repo:write("src/one.lua", {
    "pad a",
    "pad b",
    "line one",
    "line two",
    "line three CHANGED",
    "line four",
    "line five",
  })
  refresh(child)
  eq(save_count(child), 1)
  eq(session_field(child, "state.comments['src/one.lua'][1].anchor.start_line"), 5)
  eq(session_field(child, "state.comments['src/one.lua'][1].anchor.outdated"), nil)
  eq(reloaded_state_field(child, ".comments['src/one.lua'][1].anchor.start_line"), 5)

  -- The commented line itself disappears: outdated, once, persisted.
  repo:write("src/one.lua", { "pad a", "pad b", "line one", "line two", "line four", "line five" })
  refresh(child)
  eq(save_count(child), 2)
  eq(session_field(child, "state.comments['src/one.lua'][1].anchor.outdated"), true)
  eq(reloaded_state_field(child, ".comments['src/one.lua'][1].anchor.outdated"), true)

  -- Unchanged content after the miss: the advanced sha short-circuits, no rescan-rewrite.
  refresh(child)
  eq(save_count(child), 2)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["refresh(): comments for a path that left the diff are kept untouched"] = function()
  local repo = comment_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  eq(
    add_comment(child, "src/one.lua", {
      side = "head",
      start_line = 3,
      end_line = 3,
      body = "note to self",
      snapshot = { "line three CHANGED" },
    }).ok,
    true
  )

  install_save_spy(child)

  -- Revert the worktree to the merge-base content: src/one.lua drops out of the diff
  -- entirely, so there is no content to verify the comment against -- it must survive
  -- unmodified (and un-saved) rather than being invalidated or dropped.
  repo:write("src/one.lua", { "line one", "line two", "line three", "line four", "line five" })
  refresh(child)

  eq(entry_paths(child), { "src/added.lua" })
  eq(save_count(child), 0)
  eq(session_field(child, "state.comments['src/one.lua'][1].anchor.start_line"), 3)
  eq(session_field(child, "state.comments['src/one.lua'][1].anchor.outdated"), nil)

  child.stop()
  repo:destroy()
end

T["M.new(): re-anchors persisted comments that drifted since the last session"] = function()
  local repo = comment_repo()
  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  eq(
    add_comment(child, "src/one.lua", {
      side = "head",
      start_line = 3,
      end_line = 3,
      body = "why did this change?",
      snapshot = { "line three CHANGED" },
    }).ok,
    true
  )

  -- The file changes while NO session is watching (edit between sessions).
  repo:write("src/one.lua", {
    "pad a",
    "line one",
    "line two",
    "line three CHANGED",
    "line four",
    "line five",
  })

  eq(new_session(child, {}).ok, true)
  eq(session_field(child, "state.comments['src/one.lua'][1].anchor.start_line"), 4)
  eq(reloaded_state_field(child, ".comments['src/one.lua'][1].anchor.start_line"), 4)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

-- 13. remote thread layer (read-only overlay) --------------------------------------------

--- A minimal diffly.RemoteThread-shaped table for driving the session-side layer.
---@param path string
---@param opts {id: string?, side: string?, line: integer, resolved: boolean?, outdated: boolean?, body: string?}
local function remote_thread(path, opts)
  return {
    id = opts.id or "T1",
    path = path,
    remote = true,
    resolved = opts.resolved == true,
    anchor = {
      side = opts.side or "head",
      start_line = opts.line,
      end_line = opts.line,
      outdated = opts.outdated,
    },
    messages = { { author = "alice", body = opts.body or "remote note" } },
  }
end

T["M.new(): stores the detected PR on session.pr"] = function()
  local repo = comment_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, { number = 999, base_ref = "main", head_oid = "abc123" }, nil)

  eq(new_session(child, {}).ok, true)
  eq(session_field(child, "pr.number"), 999)
  eq(session_field(child, "pr.head_oid"), "abc123")

  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  eq(session_field(child, "pr"), nil)

  child.stop()
  repo:destroy()
end

T["set_remote_threads()/threads_for_render(): merge order, resolved behind the toggle, repaint+notify"] = function()
  local repo = comment_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, { number = 999, base_ref = "main" }, nil)
  eq(new_session(child, {}).ok, true)

  eq(
    add_comment(child, "src/one.lua", {
      side = "head",
      start_line = 3,
      end_line = 3,
      body = "local draft",
      snapshot = { "line three CHANGED" },
    }).ok,
    true
  )

  install_notify_counter(child)
  child.lua([[_G.__session:set_remote_threads(...)]], {
    {
      ["src/one.lua"] = {
        remote_thread("src/one.lua", { id = "T1", line = 4, body = "open thread" }),
        remote_thread("src/one.lua", { id = "T2", line = 5, resolved = true }),
      },
    },
  })
  eq(notify_count(child), 1, "set_remote_threads notifies once (panel counts)")
  eq(
    view_log(child)[#view_log(child)].event,
    "refresh_comments",
    "set_remote_threads repaints the comment layer"
  )

  local rendered = child.lua_get([[_G.__session:threads_for_render("src/one.lua")]])
  eq(#rendered, 2, "local draft + unresolved remote; resolved hidden by default")
  eq(rendered[1].messages[1].body, "local draft", "local drafts come first")
  eq(rendered[2].id, "T1")

  child.lua("_G.__session:toggle_remote_resolved()")
  eq(session_field(child, "show_resolved_remote"), true)
  eq(notify_count(child), 2)
  rendered = child.lua_get([[_G.__session:threads_for_render("src/one.lua")]])
  eq(#rendered, 3, "the toggle reveals resolved threads")

  child.lua("_G.__session:toggle_remote_resolved()")
  eq(#child.lua_get([[_G.__session:threads_for_render("src/one.lua")]]), 2)

  child.stop()
  repo:destroy()
end

T["comment_count() adds unresolved remote threads, independent of the resolved toggle"] = function()
  local repo = comment_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, { number = 999, base_ref = "main" }, nil)
  eq(new_session(child, {}).ok, true)

  eq(
    add_comment(child, "src/one.lua", {
      side = "head",
      start_line = 3,
      end_line = 3,
      body = "local draft",
      snapshot = { "line three CHANGED" },
    }).ok,
    true
  )
  child.lua([[_G.__session:set_remote_threads(...)]], {
    {
      ["src/one.lua"] = {
        remote_thread("src/one.lua", { id = "T1", line = 4 }),
        remote_thread("src/one.lua", { id = "T2", line = 5, resolved = true }),
        remote_thread("src/one.lua", { id = "T3", line = 9, outdated = true }),
      },
    },
  })

  eq(
    child.lua_get([[_G.__session:comment_count("src/one.lua")]]),
    3,
    "1 local + 2 unresolved remote"
  )
  child.lua("_G.__session:toggle_remote_resolved()")
  eq(
    child.lua_get([[_G.__session:comment_count("src/one.lua")]]),
    3,
    "the panel number must not jump when peeking at resolved threads"
  )

  child.stop()
  repo:destroy()
end

T["remote_thread_list(): flat (path, start_line) order, outdated included, toggle-sensitive"] = function()
  local repo = comment_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, { number = 999, base_ref = "main" }, nil)
  eq(new_session(child, {}).ok, true)

  child.lua([[_G.__session:set_remote_threads(...)]], {
    {
      ["src/one.lua"] = {
        remote_thread("src/one.lua", { id = "T2", line = 9, outdated = true }),
        remote_thread("src/one.lua", { id = "T1", line = 2 }),
        remote_thread("src/one.lua", { id = "T3", line = 5, resolved = true }),
      },
      ["src/added.lua"] = {
        remote_thread("src/added.lua", { id = "T4", line = 1 }),
      },
    },
  })

  local list = child.lua_get([[_G.__session:remote_thread_list()]])
  eq(#list, 3, "resolved hidden by default; outdated included")
  eq(list[1].id, "T4")
  eq(list[2].id, "T1")
  eq(list[3].id, "T2")

  child.lua("_G.__session:toggle_remote_resolved()")
  eq(#child.lua_get([[_G.__session:remote_thread_list()]]), 4)

  child.stop()
  repo:destroy()
end

-- 14. submission prep + draft adoption ----------------------------------------------------

T["prepare_submission(): guards -- no PR / unknown head oid / local HEAD not the PR head"] = function()
  local repo = comment_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)

  -- No PR at all.
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  local result = child.lua([[
    local plan, err = _G.__session:prepare_submission()
    return { ok = plan ~= nil, err = err }
  ]])
  eq(result.ok, false)
  eq(type(result.err), "string")

  -- A PR whose head oid is unknown (older gh output).
  set_pr_result(child, { number = 9, base_ref = "main" }, nil)
  eq(new_session(child, {}).ok, true)
  result = child.lua([[
    local plan, err = _G.__session:prepare_submission()
    return { ok = plan ~= nil, err = err }
  ]])
  eq(result.ok, false)

  -- A PR head oid that is NOT the local HEAD: reviewing stale state must abort.
  set_pr_result(child, { number = 9, base_ref = "main", head_oid = ("0"):rep(40) }, nil)
  eq(new_session(child, {}).ok, true)
  result = child.lua([[
    local plan, err = _G.__session:prepare_submission()
    return { ok = plan ~= nil, err = err }
  ]])
  eq(result.ok, false)
  eq(result.err:find("PR head") ~= nil, true)

  child.stop()
  repo:destroy()
end

T["prepare_submission(): plans committed drafts and reports uncommitted-only ones as skipped"] = function()
  local repo = comment_repo()
  -- The fixture's feature commit IS the PR head; its worktree matches HEAD.
  local head_oid = vim.trim(repo:git({ "rev-parse", "HEAD" }))

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, { number = 9, base_ref = "main", head_oid = head_oid }, nil)
  eq(new_session(child, {}).ok, true)

  -- A clean head-side draft on the committed change in src/one.lua (line 3)...
  eq(
    add_comment(child, "src/one.lua", {
      side = "head",
      start_line = 3,
      end_line = 3,
      body = "why did this change?",
      snapshot = { "line three CHANGED" },
    }).ok,
    true
  )
  -- ...and one that can't go: with a 5-line file, -U3 context covers every line, so the
  -- reliable out-of-diff case here is a PATH absent from the PR diff -- an untracked
  -- file that only exists in the worktree (in the session's entries, not in the PR's).
  child.lua([[vim.fn.writefile({ "wip" }, _G.__session.spec.repo.toplevel .. "/scratch.txt")]])
  child.lua([[_G.__session:refresh()]])
  eq(
    add_comment(child, "scratch.txt", {
      side = "head",
      start_line = 1,
      end_line = 1,
      body = "untracked musing",
      snapshot = { "wip" },
    }).ok,
    true
  )

  local plan = child.lua([[return (_G.__session:prepare_submission())]])
  eq(#plan.items, 1)
  eq(plan.items[1].payload, {
    path = "src/one.lua",
    side = "head",
    line = 3,
    body = "why did this change?",
  })
  eq(#plan.skipped, 1)
  eq(plan.skipped[1].reason:find("not in the PR diff") ~= nil, true)

  child.stop()
  repo:destroy()
end

T["remove_submitted(): deletes the submitted threads with one save and one notify"] = function()
  local repo = comment_repo()
  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)

  local a = add_comment(child, "src/one.lua", {
    side = "head",
    start_line = 3,
    end_line = 3,
    body = "goes to the PR",
    snapshot = { "line three CHANGED" },
  })
  eq(
    add_comment(child, "src/one.lua", {
      side = "head",
      start_line = 4,
      end_line = 4,
      body = "stays local",
      snapshot = { "line four" },
    }).ok,
    true
  )

  install_save_spy(child)
  install_notify_counter(child)

  child.lua(
    [[
      local id = ...
      local threads = _G.__session:comments_for("src/one.lua")
      local items = {}
      for _, thread in ipairs(threads) do
        if thread.id == id then
          table.insert(items, { thread = thread, payload = {} })
        end
      end
      _G.__session:remove_submitted(items)
    ]],
    { a.id }
  )

  eq(save_count(child), 1)
  eq(notify_count(child), 1)
  local remaining = child.lua_get([[_G.__session:comments_for("src/one.lua")]])
  eq(#remaining, 1)
  eq(remaining[1].messages[1].body, "stays local")
  eq(
    child.lua_get(
      [[#(require("diffly.state").load(_G.__session.spec.review_key).comments["src/one.lua"])]]
    ),
    1,
    "the deletion persisted"
  )

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["M.new(): adopts branch-keyed drafts into a PR-keyed session, once, keeping viewed marks behind"] = function()
  local repo = comment_repo()
  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  install_notify_capture(child)
  point_state_dir(child, tmp_state)

  -- Session 1: branch-keyed (no PR yet); leave a draft and a viewed mark behind.
  set_pr_result(child, nil, "no pr yet")
  eq(new_session(child, {}).ok, true)
  eq(
    add_comment(child, "src/one.lua", {
      side = "head",
      start_line = 3,
      end_line = 3,
      body = "pre-PR draft",
      snapshot = { "line three CHANGED" },
    }).ok,
    true
  )
  toggle_viewed(child, "src/added.lua")
  child.lua("_G.__session:close()")
  child.lua([[_G.__branch_key = _G.__session.spec.review_key]])

  -- Session 2: the PR now exists -- the draft must follow into the PR-keyed store.
  set_pr_result(child, { number = 9, base_ref = "main" }, nil)
  eq(new_session(child, {}).ok, true)
  eq(session_field(child, "spec.review_key.kind"), "pr")

  local adopted = child.lua_get([[_G.__session:comments_for("src/one.lua")]])
  eq(#adopted, 1)
  eq(adopted[1].messages[1].body, "pre-PR draft")

  local notes = notifications(child)
  local adoption_notes = 0
  for _, note in ipairs(notes) do
    if note.msg:find("adopted", 1, true) then
      adoption_notes = adoption_notes + 1
    end
  end
  eq(adoption_notes, 1)

  -- The branch store keeps its viewed marks but no longer holds the draft; both stores
  -- are re-read from DISK.
  local branch_state = child.lua_get([[require("diffly.state").load(_G.__branch_key)]])
  eq(next(branch_state.comments) == nil, true)
  eq(branch_state.viewed["src/added.lua"] ~= nil, true)
  local pr_state = child.lua_get([[require("diffly.state").load(_G.__session.spec.review_key)]])
  eq(#pr_state.comments["src/one.lua"], 1)

  -- Session 3: nothing left to adopt, no second notice.
  eq(new_session(child, {}).ok, true)
  adoption_notes = 0
  for _, note in ipairs(notifications(child)) do
    if note.msg:find("adopted", 1, true) then
      adoption_notes = adoption_notes + 1
    end
  end
  eq(adoption_notes, 1)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["remote threads never reach the persisted ReviewState"] = function()
  local repo = comment_repo()
  local tmp_state = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  point_state_dir(child, tmp_state)
  set_pr_result(child, { number = 999, base_ref = "main" }, nil)
  eq(new_session(child, {}).ok, true)

  child.lua(
    [[_G.__session:set_remote_threads(...)]],
    { { ["src/one.lua"] = { remote_thread("src/one.lua", { id = "T1", line = 4 }) } } }
  )
  -- Force a save through a normal mutation, then inspect the file from disk.
  eq(
    add_comment(child, "src/one.lua", {
      side = "head",
      start_line = 3,
      end_line = 3,
      body = "local draft",
      snapshot = { "line three CHANGED" },
    }).ok,
    true
  )

  local reloaded = child.lua_get([[require("diffly.state").load(_G.__session.spec.review_key)]])
  eq(#reloaded.comments["src/one.lua"], 1)
  eq(reloaded.comments["src/one.lua"][1].messages[1].body, "local draft")
  eq(reloaded.remote_threads, nil, "no remote field may ever be persisted")

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

T["sweep_patterns(nil): sweeps the UNION of every group, de-duplicating a path matched by more than one group"] = function()
  local repo = group_repo()

  local child = helpers.new_child(repo.dir)
  install_fakes(child)
  set_pr_result(child, nil, "no pr")
  eq(new_session(child, {}).ok, true)
  set_viewed_patterns(child, {
    -- Both groups match "a.lock" -- the union must still only toggle it once.
    { name = "lock files", patterns = { "*.lock" } },
    { name = "also lock files", patterns = { "a.lock" } },
    { name = "generated", patterns = { "generated/**" } },
  })

  local swept = sweep_with_scope(child, nil)
  eq(swept.result, { marked = 3, unmarked = 0, matched = 3 }, "a.lock counted once, not twice")
  eq(swept.scope, "all groups")
  eq(is_viewed(child, "a.lock"), true)
  eq(is_viewed(child, "z.lock"), true)
  eq(is_viewed(child, "generated/out.txt"), true)
  eq(is_viewed(child, "other.txt"), false)

  child.stop()
  repo:destroy()
end

return T
