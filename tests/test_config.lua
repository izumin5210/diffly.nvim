-- Tests for lua/diffly/config.lua's `M.normalize_pattern_groups` (the pure shape-
-- interpretation of `viewed_patterns` -- see its own doc comment for why it lives here
-- rather than session.lua). No child Neovim needed: MiniTest itself already runs inside a
-- real Neovim process capable of calling `vim.notify`/`require` (mirrors
-- tests/test_scratch.lua's/tests/test_tree.lua's own "no child" rationale) -- there is no
-- git repo or `diffly.Session` involved anywhere in this module.

local config = require("diffly.config")

local eq = MiniTest.expect.equality

--- Replace `vim.notify` for the duration of one test case, recording every call. Mirrors
--- tests/test_session.lua's/tests/test_panel.lua's own `install_notify_capture` helpers,
--- but restores the original afterwards -- this file runs every case in the SAME process
--- (no child to throw away), so leaking the stub across cases would break every later
--- test's own use of `vim.notify`.
---@return table[] notifications
---@return fun() restore
local function capture_notify()
  local notifications = {}
  local original = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end
  return notifications, function()
    vim.notify = original
  end
end

local T = MiniTest.new_set()

T["normalize_pattern_groups(): plain strings collect into one 'default' group"] = function()
  local groups = config.normalize_pattern_groups({ "*.lock", "*.snap" })

  eq(#groups, 1)
  eq(groups[1].name, "default")
  eq(groups[1].patterns, { "*.lock", "*.snap" })
end

T["normalize_pattern_groups(): empty input yields no groups"] = function()
  eq(config.normalize_pattern_groups({}), {})
end

T["normalize_pattern_groups(): a named table is its own group, patterns preserved in order"] = function()
  local groups = config.normalize_pattern_groups({
    { name = "lock files", patterns = { "*.lock", "*.sum" } },
  })

  eq(#groups, 1)
  eq(groups[1].name, "lock files")
  eq(groups[1].patterns, { "*.lock", "*.sum" })
end

T["normalize_pattern_groups(): mixed strings/tables -- the implicit 'default' group is positioned at the FIRST string, later strings still fold into it"] = function()
  local groups = config.normalize_pattern_groups({
    "*.foo", -- default group starts here (position 1)
    { name = "a", patterns = { "*.bar" } }, -- position 2
    "*.baz", -- folds into the default group, NOT a new position-3 group
    { name = "b", patterns = { "*.qux" } }, -- position 3
  })

  eq(#groups, 3)
  eq(groups[1], { name = "default", patterns = { "*.foo", "*.baz" } })
  eq(groups[2], { name = "a", patterns = { "*.bar" } })
  eq(groups[3], { name = "b", patterns = { "*.qux" } })
end

T["normalize_pattern_groups(): a named table positioned before any plain string still lets the default group form later, at its own first string"] = function()
  local groups = config.normalize_pattern_groups({
    { name = "a", patterns = { "*.bar" } },
    "*.foo",
  })

  eq(#groups, 2)
  eq(groups[1].name, "a")
  eq(groups[2], { name = "default", patterns = { "*.foo" } })
end

T["normalize_pattern_groups(): two explicit groups sharing a name merge into the first occurrence and warn exactly once"] = function()
  local notifications, restore = capture_notify()

  local groups = config.normalize_pattern_groups({
    { name = "dup-group-a", patterns = { "*.one" } },
    { name = "unrelated", patterns = { "*.mid" } },
    { name = "dup-group-a", patterns = { "*.two" } },
  })

  restore()

  eq(#groups, 2, "the second 'dup-group-a' merges rather than becoming its own group")
  eq(groups[1], { name = "dup-group-a", patterns = { "*.one", "*.two" } })
  eq(groups[2], { name = "unrelated", patterns = { "*.mid" } })

  eq(#notifications, 1)
  eq(notifications[1].level, vim.log.levels.WARN)
  eq(notifications[1].msg:find("dup-group-a", 1, true) ~= nil, true)

  -- Calling it again (a second sweep/menu render in the same Neovim session) must not
  -- re-warn about the same offending name.
  local notifications2, restore2 = capture_notify()
  config.normalize_pattern_groups({
    { name = "dup-group-a", patterns = { "*.three" } },
    { name = "dup-group-a", patterns = { "*.four" } },
  })
  restore2()
  eq(#notifications2, 0, "the same duplicate name must only ever warn once per Neovim session")
end

T["normalize_pattern_groups(): a plain string colliding with an explicit 'default'-named table also merges and warns"] = function()
  local notifications, restore = capture_notify()

  local groups = config.normalize_pattern_groups({
    "*.foo", -- implicit default group forms here
    { name = "default", patterns = { "*.explicit-default" } }, -- collides with it
  })

  restore()

  eq(#groups, 1)
  eq(groups[1], { name = "default", patterns = { "*.foo", "*.explicit-default" } })
  eq(#notifications, 1)
  eq(notifications[1].msg:find("default", 1, true) ~= nil, true)
end

return T
