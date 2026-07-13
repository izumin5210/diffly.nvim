-- bin/diffly's brain: argument parsing, live-instance discovery, and transport selection.
-- ALL review logic lives in lua/diffly/agent.lua (shared with the RPC side) -- this
-- module only decides WHERE an op runs and shapes the process boundary (JSON on stdout,
-- errors on stderr, exit codes). Runs under `nvim -l`, where print() goes to STDERR --
-- machine-readable output must use io.stdout, which conveniently keeps vim.notify noise
-- from the plugin off the JSON stream.

local git = require("diffly.git")

local M = {}

local USAGE = [[
Usage: diffly [--server <addr>] [--headless] <command>

Commands:
  info                             Review metadata (key, base, files) as JSON
  comments list [--remote]         List draft (and, with --remote, PR) threads
  comments add --file <path> --line <n> [--end-line <m>] [--side base|head]
               --body <text>|- [--author <name>]
  comments rm <id>                 Delete a draft thread
  comments reply <id> --body <text>|- [--author <name>]
  navigate --file <path> [--line <n>]
                                   Focus the live Neovim session on a location
  skill install [--dir <path>]     Install the diffly-review agent skill
                                   (default: ~/.claude/skills)

Options:
  --server <addr>  Target one Neovim instance (socket path) instead of discovering
  --headless       Skip discovery; operate on the persisted state directly
  --json           Accepted for compatibility; output is always JSON
]]

--- Exit code for `navigate` without any live session -- distinct from generic failure
--- (1) so agents can tell "open Neovim first" apart from a real error.
local EXIT_NO_LIVE = 2

-- Flags that take no value; everything else `--key value`.
local BOOL_FLAGS = { remote = true, json = true, headless = true }

---@class diffly.cli.Command
---@field op string      -- diffly.agent op name
---@field args table     -- agent args (tab is filled in by the transport)
---@field server string?
---@field headless boolean

---@param argv table  -- _G.arg: [0] = script path, [1..n] = arguments
---@return diffly.cli.Command|nil, string|nil err
local function parse(argv)
  local pos, flags = {}, {}
  local i = 1
  while argv[i] ~= nil do
    local a = argv[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
      if BOOL_FLAGS[key] then
        flags[key] = true
      else
        i = i + 1
        if argv[i] == nil then
          return nil, string.format("missing value for --%s", key)
        end
        flags[key] = argv[i]
      end
    else
      table.insert(pos, a)
    end
    i = i + 1
  end

  ---@param body string?
  ---@return string?
  local function read_body(body)
    if body ~= "-" then
      return body
    end
    -- `--body -`: the whole of stdin, minus the trailing newline shells append.
    local text = io.read("*a") or ""
    return (text:gsub("\n$", ""))
  end

  local op, args
  if pos[1] == "info" and pos[2] == nil then
    op, args = "info", {}
  elseif pos[1] == "comments" and pos[2] == "list" and pos[3] == nil then
    op, args = "list", { remote = flags.remote }
  elseif pos[1] == "comments" and pos[2] == "add" and pos[3] == nil then
    op, args =
      "add", {
        path = flags.file,
        side = flags.side,
        start_line = flags.line,
        end_line = flags["end-line"],
        body = read_body(flags.body),
        author = flags.author,
      }
  elseif pos[1] == "comments" and pos[2] == "rm" and pos[3] ~= nil and pos[4] == nil then
    op, args = "rm", { id = pos[3] }
  elseif pos[1] == "comments" and pos[2] == "reply" and pos[3] ~= nil and pos[4] == nil then
    op, args = "reply", { id = pos[3], body = read_body(flags.body), author = flags.author }
  elseif pos[1] == "navigate" and pos[2] == nil then
    op, args = "navigate", { path = flags.file, line = flags.line }
  elseif pos[1] == "skill" and pos[2] == "install" and pos[3] == nil then
    op, args = "skill_install", { dir = flags.dir }
  else
    return nil, "unknown command: " .. table.concat(pos, " ")
  end

  return { op = op, args = args, server = flags.server, headless = flags.headless == true }
end

-- Must not load diffly into an instance that never used it (side-effect-free probe), and
-- must not error against an instance without diffly on its runtimepath.
local PROBE = [[
local ok, agent = pcall(require, "diffly.agent")
if not ok then return {} end
return agent.sessions()
]]

--- Find a live Neovim instance holding a diffly session for `repo`. Candidate order:
--- an explicit --server, then $NVIM (the instance hosting this terminal, if any), then
--- every peer socket `serverlist({peer = true})` can see (not supported on Windows) --
--- $NVIM is only a fast-path hint, not a stop: the agent may run inside one instance
--- while the human reviews in another. Every probe is pcall'd (stale sockets abound);
--- note vim.rpcrequest has no timeout, so an instance wedged in a blocking prompt can
--- stall discovery until it is dismissed.
---@param repo diffly.RepoIdentity
---@param server string?
---@return integer? chan, integer? tab, string? addr
local function discover(repo, server)
  local candidates, seen = {}, {}
  local function add(addr)
    if addr and addr ~= "" and addr ~= vim.v.servername and not seen[addr] then
      seen[addr] = true
      table.insert(candidates, addr)
    end
  end

  if server then
    add(server)
  else
    add(vim.env.NVIM)
    local ok, peers = pcall(vim.fn.serverlist, { peer = true })
    if ok and type(peers) == "table" then
      for _, addr in ipairs(peers) do
        add(addr)
      end
    end
  end

  for _, addr in ipairs(candidates) do
    -- Unix sockets are paths; anything without a "/" is treated as host:port.
    local mode = addr:find("/", 1, true) and "pipe" or "tcp"
    local ok_conn, chan = pcall(vim.fn.sockconnect, mode, addr, { rpc = true })
    if ok_conn and chan ~= 0 then
      local ok_probe, sessions = pcall(vim.rpcrequest, chan, "nvim_exec_lua", PROBE, {})
      local best
      if ok_probe and type(sessions) == "table" then
        for _, s in ipairs(sessions) do
          if s.repo_id == repo.id then
            if s.toplevel == repo.toplevel then
              best = s
              break
            end
            best = best or s
          end
        end
      end
      if best then
        return chan, best.tab, addr
      end
      pcall(vim.fn.chanclose, chan)
    end
  end
  return nil
end

--- Copy the in-repo skill template to the target, baking THIS executable's absolute
--- path in -- an installed skill keeps working regardless of the user's PATH or plugin
--- manager layout. CLI-local: no agent op, no discovery, no repository required.
--- Reinstall overwrites: the installed file is a generated artifact, refreshing it is
--- the point.
---@param argv table  -- _G.arg (argv[0] locates the bin, and thus the template)
---@param args { dir: string? }
---@return integer exit_code
local function skill_install(argv, args)
  local bin = assert(vim.uv.fs_realpath(argv[0]))
  local root = vim.fs.dirname(vim.fs.dirname(bin))
  local template_path = vim.fs.joinpath(root, "skills", "diffly-review", "SKILL.md")
  if vim.fn.filereadable(template_path) == 0 then
    io.stderr:write("diffly: skill template not found at " .. template_path .. "\n")
    return 1
  end
  local template = table.concat(vim.fn.readfile(template_path), "\n")
  -- Function replacement: the bin path is inserted literally, never as a pattern.
  local rendered = template:gsub("{{DIFFLY_BIN}}", function()
    return bin
  end)

  local base_dir = args.dir or vim.fs.joinpath(assert(vim.uv.os_homedir()), ".claude", "skills")
  local target_dir = vim.fs.joinpath(base_dir, "diffly-review")
  vim.fn.mkdir(target_dir, "p")
  local dest = vim.fs.joinpath(target_dir, "SKILL.md")
  if vim.fn.writefile(vim.split(rendered, "\n", { plain = true }), dest) ~= 0 then
    io.stderr:write("diffly: could not write " .. dest .. "\n")
    return 1
  end

  io.stdout:write(vim.json.encode({ installed = dest }) .. "\n")
  io.stdout:flush()
  return 0
end

---@param argv table  -- _G.arg
---@return integer exit_code
function M.main(argv)
  local cmd, parse_err = parse(argv)
  if not cmd then
    io.stderr:write("diffly: " .. parse_err .. "\n\n" .. USAGE)
    return 1
  end

  if cmd.op == "skill_install" then
    return skill_install(argv, cmd.args)
  end

  local repo, repo_err = git.repo_identity(vim.fn.getcwd())
  if not repo then
    io.stderr:write((repo_err or "diffly: not inside a git repository") .. "\n")
    return 1
  end

  local chan, tab, addr
  if not cmd.headless then
    chan, tab, addr = discover(repo, cmd.server)
  end

  ---@type diffly.agent.Result
  local result
  if chan then
    cmd.args.tab = tab
    local ok, res = pcall(
      vim.rpcrequest,
      chan,
      "nvim_exec_lua",
      "return require('diffly.agent').dispatch(...)",
      { cmd.op, cmd.args }
    )
    result = ok and res or { ok = false, error = "diffly: RPC failed: " .. tostring(res) }
    pcall(vim.fn.chanclose, chan)
  elseif cmd.server then
    -- An explicitly targeted instance without this repo's session: writing headlessly
    -- anyway could race a live session the user believes is in charge -- refuse.
    result = { ok = false, error = "diffly: no diffly session for this repo at " .. cmd.server }
  else
    result = require("diffly.agent").run_headless(cmd.op, cmd.args)
  end

  if cmd.op == "info" and result.ok and type(result.data) == "table" then
    result.data.live = chan ~= nil
    result.data.server = addr
  end

  if not result.ok then
    io.stderr:write((result.error or "diffly: unknown error") .. "\n")
    if cmd.op == "navigate" and not chan then
      return EXIT_NO_LIVE
    end
    return 1
  end

  io.stdout:write(vim.json.encode(result.data or vim.empty_dict()) .. "\n")
  io.stdout:flush()
  return 0
end

return M
