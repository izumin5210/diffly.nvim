-- tree.lua is pure data (no vim UI dependency), so these run directly in the top-level
-- test process -- no child Neovim needed.

local tree = require("difit.tree")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

--- Minimal difit.FileEntry-shaped table. Only `.path` matters for tree building; the
--- rest is kept shape-correct but otherwise arbitrary.
---@param path string
---@return difit.FileEntry
local function entry(path)
  return {
    path = path,
    old_path = nil,
    status = "M",
    untracked = false,
    binary = false,
    additions = 1,
    deletions = 0,
    base_sha = "base",
    head_sha = "head",
  }
end

T["build() with a single root-level file"] = function()
  local root = tree.build({ entry("a.lua") })

  eq(root.type, "dir")
  eq(root.path, "")
  eq(root.name, "")
  eq(#root.children, 1)

  local file = root.children[1]
  eq(file.type, "file")
  eq(file.name, "a.lua")
  eq(file.path, "a.lua")
  eq(file.entry.path, "a.lua")
end

T["build() with no entries returns a root with no children"] = function()
  local root = tree.build({})

  eq(root.type, "dir")
  eq(root.path, "")
  eq(root.name, "")
  eq(root.children, {})
end

T["build() orders directories before files, each alphabetical"] = function()
  local root = tree.build({
    entry("b.lua"),
    entry("a.lua"),
    entry("zzz/inner.lua"),
    entry("aaa/inner.lua"),
  })

  local names = {}
  for _, child in ipairs(root.children) do
    table.insert(names, child.name)
  end
  -- dirs ("aaa", "zzz") come first, alphabetical, then files ("a.lua", "b.lua").
  eq(names, { "aaa", "zzz", "a.lua", "b.lua" })
  eq(root.children[1].type, "dir")
  eq(root.children[2].type, "dir")
  eq(root.children[3].type, "file")
  eq(root.children[4].type, "file")
end

T["build() collapses a chain of single-child directories"] = function()
  local root = tree.build({ entry("src/ui/widgets/button.lua") })

  eq(#root.children, 1)
  local dir = root.children[1]
  eq(dir.type, "dir")
  eq(dir.name, "src/ui/widgets")
  eq(dir.path, "src/ui/widgets")
  eq(#dir.children, 1)
  eq(dir.children[1].type, "file")
  eq(dir.children[1].name, "button.lua")
  eq(dir.children[1].path, "src/ui/widgets/button.lua")
end

T["build() does not collapse a directory with a single file child"] = function()
  local root = tree.build({ entry("src/only.lua") })

  eq(#root.children, 1)
  local dir = root.children[1]
  eq(dir.type, "dir")
  eq(dir.name, "src")
  eq(dir.path, "src")
  eq(#dir.children, 1)
  eq(dir.children[1].type, "file")
  eq(dir.children[1].name, "only.lua")
end

T["build() does not collapse a directory with two children"] = function()
  local root = tree.build({ entry("src/a.lua"), entry("src/sub/b.lua") })

  eq(#root.children, 1)
  local src = root.children[1]
  eq(src.name, "src")
  eq(src.path, "src")
  eq(#src.children, 2)
  -- dirs first: "sub" dir, then the "a.lua" file.
  eq(src.children[1].type, "dir")
  eq(src.children[1].name, "sub")
  eq(src.children[1].path, "src/sub")
  eq(src.children[2].type, "file")
  eq(src.children[2].name, "a.lua")
end

T["build() collapses a chain, then stops where it branches"] = function()
  local root = tree.build({
    entry("src/ui/widgets/button.lua"),
    entry("src/ui/widgets/icon.lua"),
  })

  eq(#root.children, 1)
  local dir = root.children[1]
  eq(dir.name, "src/ui/widgets")
  eq(dir.path, "src/ui/widgets")
  eq(#dir.children, 2)
  eq(dir.children[1].name, "button.lua")
  eq(dir.children[2].name, "icon.lua")
end

T["flatten() lists root children at depth 0 and nests pre-order"] = function()
  local root = tree.build({
    entry("src/a.lua"),
    entry("src/b.lua"),
    entry("top.lua"),
  })

  local rows = tree.flatten(root, {})
  local shape = {}
  for _, row in ipairs(rows) do
    table.insert(shape, { row.node.path, row.depth })
  end

  eq(shape, {
    { "src", 0 },
    { "src/a.lua", 1 },
    { "src/b.lua", 1 },
    { "top.lua", 0 },
  })
end

T["flatten() hides descendants of a folded directory but keeps its own row"] = function()
  local root = tree.build({
    entry("src/a.lua"),
    entry("src/b.lua"),
    entry("top.lua"),
  })

  local rows = tree.flatten(root, { ["src"] = true })
  local paths = {}
  for _, row in ipairs(rows) do
    table.insert(paths, row.node.path)
  end

  eq(paths, { "src", "top.lua" })
end

T["file_order() matches flatten order when nothing is folded"] = function()
  local root = tree.build({
    entry("src/b.lua"),
    entry("src/a.lua"),
    entry("top.lua"),
  })

  local rows = tree.flatten(root, {})
  local flattened_files = {}
  for _, row in ipairs(rows) do
    if row.node.type == "file" then
      table.insert(flattened_files, row.node.path)
    end
  end

  eq(tree.file_order(root), flattened_files)
  eq(tree.file_order(root), { "src/a.lua", "src/b.lua", "top.lua" })
end

T["file_order() ignores folds, unlike flatten()"] = function()
  local root = tree.build({
    entry("src/a.lua"),
    entry("src/b.lua"),
  })

  local rows = tree.flatten(root, { ["src"] = true })
  local flattened_files = {}
  for _, row in ipairs(rows) do
    if row.node.type == "file" then
      table.insert(flattened_files, row.node.path)
    end
  end
  eq(flattened_files, {})

  eq(tree.file_order(root), { "src/a.lua", "src/b.lua" })
end

return T
