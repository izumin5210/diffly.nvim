-- Builds a directory/file tree out of a flat list of difit.FileEntry (see
-- lua/difit/types.lua) and turns it into flat rows for panel rendering. Pure data
-- structure: no vim UI dependency, so it is unit-testable without a child Neovim process.

local M = {}

--- Split "a/b/c" into {"a", "b", "c"} without depending on any vim API.
---@param path string
---@return string[]
local function split_path(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

--- Collapse a chain of single-child directories into one node ("a/b/c"), stopping as
--- soon as a directory has more than one child, or its only child is a file: a directory
--- with exactly one file child stays a real directory row, it must not vanish into the
--- file.
---@param node difit.TreeNode
local function collapse_chains(node)
  while #node.children == 1 and node.children[1].type == "dir" do
    local child = node.children[1]
    node.name = node.name == "" and child.name or (node.name .. "/" .. child.name)
    node.path = child.path
    node.children = child.children
  end
  for _, child in ipairs(node.children) do
    if child.type == "dir" then
      collapse_chains(child)
    end
  end
end

--- Directories first, then files, each group alphabetical by (possibly compressed) name.
--- Run after collapsing so compressed names are what gets compared.
---@param node difit.TreeNode
local function sort_children(node)
  if node.type ~= "dir" then
    return
  end
  table.sort(node.children, function(a, b)
    if a.type ~= b.type then
      return a.type == "dir"
    end
    return a.name < b.name
  end)
  for _, child in ipairs(node.children) do
    sort_children(child)
  end
end

--- Build the tree. Chains of single-child directories are collapsed into one node; a
--- directory with a single *file* child is left alone.
---@param entries difit.FileEntry[]
---@return difit.TreeNode root @root node (type="dir", path="", name="")
function M.build(entries)
  local root = { type = "dir", name = "", path = "", children = {} }
  -- Directory path -> node, so repeated prefixes across entries reuse the same node
  -- instead of creating duplicate intermediate directories.
  local dirs = { [""] = root }

  for _, entry in ipairs(entries) do
    local parts = split_path(entry.path)
    local parent = root
    local prefix = ""
    for i = 1, #parts - 1 do
      prefix = prefix == "" and parts[i] or (prefix .. "/" .. parts[i])
      local dir = dirs[prefix]
      if not dir then
        dir = { type = "dir", name = parts[i], path = prefix, children = {} }
        dirs[prefix] = dir
        table.insert(parent.children, dir)
      end
      parent = dir
    end

    table.insert(parent.children, {
      type = "file",
      name = parts[#parts],
      path = entry.path,
      entry = entry,
    })
  end

  for _, child in ipairs(root.children) do
    if child.type == "dir" then
      collapse_chains(child)
    end
  end
  sort_children(root)

  return root
end

--- Flatten the tree into rows in pre-order. A folded directory still emits its own row
--- but none of its descendants.
---@param root difit.TreeNode
---@param folded table<string, boolean> @dir path -> folded?
---@return difit.TreeRow[]
function M.flatten(root, folded)
  folded = folded or {}
  local rows = {}

  local function walk(node, depth)
    table.insert(rows, { node = node, depth = depth })
    if node.type == "dir" and not folded[node.path] then
      for _, child in ipairs(node.children) do
        walk(child, depth + 1)
      end
    end
  end

  for _, child in ipairs(root.children) do
    walk(child, 0)
  end

  return rows
end

--- Paths of all file nodes in flatten order, ignoring folds (always walks the full tree).
---@param root difit.TreeNode
---@return string[]
function M.file_order(root)
  local paths = {}

  local function walk(node)
    if node.type == "file" then
      table.insert(paths, node.path)
    else
      for _, child in ipairs(node.children) do
        walk(child)
      end
    end
  end

  for _, child in ipairs(root.children) do
    walk(child)
  end

  return paths
end

return M
