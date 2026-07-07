-- Tests for lua/difit/session.lua: the orchestration core (base resolution, review-key
-- derivation, viewed-state persistence, next-unviewed navigation, view lifecycle). Git is
-- never mocked -- every case drives a real repository via tests/helpers.lua. Only the
-- view (`opts.view_factory`) and `gh` (`opts.github`) seams are faked, exactly as
-- `difit.SessionOpts` intends: both are injected values, not shimmed subprocesses.
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
--   _G.__pr_result       {info=difit.PrInfo?, err=string?} returned by the next detect_pr
--   _G.__github_calls    number of times detect_pr was invoked
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
    }
  end

  _G.__view_factory = function(mode)
    table.insert(_G.__factory_modes, mode)
    return make_view(mode)
  end

  _G.__pr_result = { info = nil, err = "no fake pr configured" }
  _G.__github_calls = 0
  _G.__fake_github = {
    detect_pr = function(_repo)
      _G.__github_calls = _G.__github_calls + 1
      local r = _G.__pr_result
      return r.info, r.err
    end,
  }
]]

---@param child table
local function install_fakes(child)
  child.lua(INSTALL_FAKES)
end

--- Configure what the fake `github.detect_pr` returns on its next call(s).
---@param child table
---@param info difit.PrInfo?
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

--- Point the child's `difit.state` module at a fresh directory (the documented `_dir`
--- test seam), so runs never touch the real `stdpath('data')` location.
---@param child table
---@param dir string
local function point_state_dir(child, dir)
  child.lua("require('difit.state')._dir = ...", { dir })
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
      local session, err = require("difit.session").new(opts)
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
  set_pr_result(child, { number = 999, base_ref = "pr-base", owner_repo = "acme/widgets" }, nil)

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
  child.lua([[require("difit.config").options.base = "arg-base"]])
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
    local session, err = require("difit.session").new({})
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

  child.lua([[require("difit.config").options.right = "head"]])
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

T["set_mode(): closes the current view, opens the new one via view_factory, reopens current_path"] = function()
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

  install_notify_counter(child)
  set_mode(child, "unified")

  eq(session_field(child, "mode"), "unified")
  eq(factory_modes(child), { "sidebyside", "unified" })
  eq(notify_count(child), 1)
  eq(view_log(child), {
    { event = "open", mode = "sidebyside", path = "src/one.lua" },
    { event = "close", mode = "sidebyside" },
    { event = "open", mode = "unified", path = "src/one.lua" },
  }, "reopens current_path through the freshly-created view")

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
    [[vim.uv.fs_stat(require('difit.state').file_path(_G.__session.spec.review_key)) ~= nil]]
  )
  eq(saved, true)

  vim.fn.delete(tmp_state, "rf")
  child.stop()
  repo:destroy()
end

return T
