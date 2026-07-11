-- `gh` CLI wrapper (WP-D). PR mode is an optional enhancement over the branch-pair
-- fallback (see docs/design.md), so nothing here may ever raise: every failure path
-- (missing `gh`, non-zero exit, malformed JSON) degrades to `nil, err` instead.

local M = {}

---@return boolean
function M.available()
  return vim.fn.executable("gh") == 1
end

---@class difit.PrInfo
---@field number integer
---@field base_ref string    -- baseRefName, e.g. "main"

--- Detect the PR (if any) associated with the current branch via `gh pr view`.
---
--- Never raises: `gh` missing, a non-zero exit (no PR for this branch / not logged in),
--- or output that doesn't parse as the expected JSON shape all yield `nil, err`.
---@param repo difit.RepoIdentity
---@return difit.PrInfo|nil, string|nil err
function M.detect_pr(repo)
  if not M.available() then
    return nil, "gh executable not found on PATH"
  end

  -- vim.system() itself raises synchronously if the command can't be spawned at all;
  -- guard against that racing with the availability check above.
  local spawn_ok, res_or_err = pcall(function()
    return vim
      .system(
        { "gh", "pr", "view", "--json", "number,baseRefName" },
        { text = true, cwd = repo.toplevel, timeout = 10000 }
      )
      :wait()
  end)
  if not spawn_ok then
    return nil, tostring(res_or_err)
  end

  local res = res_or_err
  if res.code ~= 0 then
    local err = res.stderr and vim.trim(res.stderr) or ""
    if err == "" then
      err = string.format("gh pr view exited with code %d", res.code)
    end
    return nil, err
  end

  local decode_ok, data = pcall(vim.json.decode, res.stdout or "")
  if not decode_ok or type(data) ~= "table" then
    return nil, "failed to parse `gh pr view` output as JSON"
  end

  if type(data.number) ~= "number" or type(data.baseRefName) ~= "string" then
    return nil, "`gh pr view` output missing expected fields"
  end

  ---@type difit.PrInfo
  local info = {
    number = data.number,
    base_ref = data.baseRefName,
  }
  return info, nil
end

return M
