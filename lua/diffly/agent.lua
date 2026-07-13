-- Agent bridge (docs/design.md "Agent bridge"): the ONE module behind bin/diffly, shared
-- by both transports -- RPC dispatch into a live instance and the headless fallback --
-- so the CLI stays transport + argument parsing and no plugin logic is ever duplicated.
-- Everything returned here crosses msgpack (RPC) or vim.json (CLI stdout): plain tables
-- only, in the persisted-schema vocabulary (types.lua), never functions or handles.

local comments = require("diffly.comments")
local git = require("diffly.git")

local M = {}

---@class diffly.agent.SessionInfo
---@field tab integer
---@field repo_id string
---@field toplevel string
---@field review_key diffly.ReviewKey

---@class diffly.agent.Result
---@field ok boolean
---@field data table?
---@field error string?

--- Live diffly sessions in this instance, as msgpack-safe data -- the RPC probe.
--- Deliberately reads `package.loaded` instead of require("diffly"): probing an instance
--- that never used diffly must stay side-effect-free (no init.lua load, no autocmds),
--- and an instance without diffly simply reports none.
---@return diffly.agent.SessionInfo[]
function M.sessions()
  local diffly = package.loaded["diffly"]
  if type(diffly) ~= "table" or type(diffly._entries) ~= "table" then
    return {}
  end

  local result = {}
  for tab, entry in pairs(diffly._entries) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      local spec = entry.session.spec
      table.insert(result, {
        tab = tab,
        repo_id = spec.repo.id,
        toplevel = spec.repo.toplevel,
        review_key = spec.review_key,
      })
    end
  end
  table.sort(result, function(a, b)
    return a.tab < b.tab
  end)
  return result
end

---@param anchor diffly.CommentAnchor|diffly.RemoteAnchor
---@return table
local function export_anchor(anchor)
  -- sha/snapshot stay internal (re-anchoring machinery, not review data); outdated is
  -- normalized to a real boolean for JSON consumers.
  return {
    side = anchor.side,
    start_line = anchor.start_line,
    end_line = anchor.end_line,
    outdated = anchor.outdated == true,
  }
end

---@param thread diffly.CommentThread
---@return table
local function export_thread(thread)
  local messages = {}
  for _, message in ipairs(thread.messages) do
    table.insert(messages, {
      body = message.body,
      created_at = message.created_at,
      updated_at = message.updated_at,
      author = message.author,
    })
  end
  return {
    id = thread.id,
    path = thread.path,
    anchor = export_anchor(thread.anchor),
    messages = messages,
  }
end

---@param thread diffly.RemoteThread
---@return table
local function export_remote(thread)
  local messages = {}
  for _, message in ipairs(thread.messages) do
    table.insert(messages, { author = message.author, body = message.body })
  end
  return {
    id = thread.id,
    path = thread.path,
    resolved = thread.resolved,
    anchor = export_anchor(thread.anchor),
    messages = messages,
  }
end

---@param session diffly.Session
---@param path string
---@return diffly.FileEntry|nil
local function find_entry(session, path)
  for _, entry in ipairs(session.entries) do
    if entry.path == path then
      return entry
    end
  end
  return nil
end

--- Resolve a thread's path from its id alone -- the CLI addresses threads by id (unique
--- per review by construction), never by (path, id) pairs.
---@param session diffly.Session
---@param id string
---@return string|nil
local function find_thread_path(session, id)
  for _, thread in ipairs(comments.list_all(session.state)) do
    if thread.id == id then
      return thread.path
    end
  end
  return nil
end

---@alias diffly.agent.Ctx { session: diffly.Session, tab: integer?, entry: table? }

---@type table<string, fun(ctx: diffly.agent.Ctx, args: table): diffly.agent.Result>
local ops = {}

function ops.info(ctx, _args)
  local session = ctx.session
  local spec = session.spec

  local files = {}
  for _, entry in ipairs(session.entries) do
    table.insert(files, {
      path = entry.path,
      old_path = entry.old_path,
      status = entry.status,
      additions = entry.additions,
      deletions = entry.deletions,
      binary = entry.binary,
      viewed = session:is_viewed(entry.path),
      comments = session:comment_count(entry.path),
    })
  end

  return {
    ok = true,
    data = {
      repo = { id = spec.repo.id, toplevel = spec.repo.toplevel },
      review_key = spec.review_key,
      base_ref = spec.base_ref,
      merge_base = spec.merge_base,
      right = spec.right,
      pr = session.pr and { number = session.pr.number, url = session.pr.url } or nil,
      current_path = session.current_path,
      files = files,
    },
  }
end

function ops.list(ctx, args)
  local session = ctx.session

  local out = { comments = {} }
  for _, thread in ipairs(session:all_comments()) do
    table.insert(out.comments, export_thread(thread))
  end

  if args.remote then
    -- The raw overlay, NOT remote_thread_list(): that filters by the human's
    -- show_resolved toggle, while the agent should see everything with flags intact.
    local remote = {}
    for _, threads in pairs(session.remote_threads) do
      for _, thread in ipairs(threads) do
        table.insert(remote, export_remote(thread))
      end
    end
    table.sort(remote, function(a, b)
      if a.path ~= b.path then
        return a.path < b.path
      end
      return a.anchor.start_line < b.anchor.start_line
    end)
    out.remote = remote
  end

  return { ok = true, data = out }
end

function ops.add(ctx, args)
  local session = ctx.session
  local path = tostring(args.path or "")
  local side = args.side or "head"
  if side ~= "base" and side ~= "head" then
    return {
      ok = false,
      error = string.format("diffly: side must be 'base' or 'head', got %q", tostring(args.side)),
    }
  end
  local start_line = tonumber(args.start_line)
  if not start_line then
    return { ok = false, error = "diffly: a start line is required" }
  end
  local end_line = tonumber(args.end_line) or start_line
  if end_line < start_line then
    return {
      ok = false,
      error = string.format("diffly: end line %d is before start line %d", end_line, start_line),
    }
  end
  local body = tostring(args.body or "")
  if vim.trim(body) == "" then
    return { ok = false, error = "diffly: a non-empty comment body is required" }
  end

  local entry = find_entry(session, path)
  if not entry then
    return { ok = false, error = string.format("diffly: %s is not part of this review", path) }
  end
  -- NOT the and-or idiom: a nil base_sha (added file) must stay nil (session.lua's rule).
  local sha
  if side == "base" then
    sha = entry.base_sha
  else
    sha = entry.head_sha
  end
  if not sha then
    return {
      ok = false,
      error = string.format("diffly: %s has no %s-side content to comment on", path, side),
    }
  end

  -- Same content source as session.lua's re-anchor pass: immutable git objects for the
  -- base and head-mode sides, the on-disk file for the worktree right side. These lines
  -- both validate the range and become the anchor snapshot -- they must be identical.
  local locator
  if side == "base" or session.spec.right == "head" then
    locator = { sha = sha }
  else
    locator = { path = path }
  end
  local lines = git.file_content(session.spec.repo, locator)
  if not lines then
    return { ok = false, error = string.format("diffly: could not load %s's %s side", path, side) }
  end
  if start_line < 1 or end_line > #lines then
    return {
      ok = false,
      error = string.format(
        "diffly: lines %d..%d are out of range (%s's %s side has %d lines)",
        start_line,
        end_line,
        path,
        side,
        #lines
      ),
    }
  end

  local snapshot = {}
  for i = start_line, end_line do
    table.insert(snapshot, lines[i])
  end

  local thread, err = session:add_comment(path, {
    side = side,
    start_line = start_line,
    end_line = end_line,
    body = body,
    snapshot = snapshot,
    author = args.author or "agent",
  })
  if not thread then
    return { ok = false, error = err }
  end
  return { ok = true, data = export_thread(thread) }
end

function ops.rm(ctx, args)
  local id = tostring(args.id or "")
  local path = find_thread_path(ctx.session, id)
  if not path then
    return { ok = false, error = string.format("diffly: no comment thread %q in this review", id) }
  end
  ctx.session:delete_comment(path, id)
  return { ok = true, data = { deleted = id } }
end

function ops.reply(ctx, args)
  local id = tostring(args.id or "")
  local body = tostring(args.body or "")
  if vim.trim(body) == "" then
    return { ok = false, error = "diffly: a non-empty reply body is required" }
  end
  local path = find_thread_path(ctx.session, id)
  if not path then
    return { ok = false, error = string.format("diffly: no comment thread %q in this review", id) }
  end

  ctx.session:reply_comment(path, id, body, { author = args.author or "agent" })

  -- Return the whole thread: the agent gets its reply in context, not just an ack.
  for _, thread in ipairs(ctx.session:comments_for(path)) do
    if thread.id == id then
      return { ok = true, data = export_thread(thread) }
    end
  end
  return { ok = false, error = string.format("diffly: no comment thread %q in this review", id) }
end

function ops.navigate(ctx, args)
  if not ctx.tab then
    return {
      ok = false,
      error = "diffly: navigate needs a live session -- open :Diffly in Neovim first",
    }
  end
  local session = ctx.session
  local path = tostring(args.path or "")
  if not find_entry(session, path) then
    return { ok = false, error = string.format("diffly: %s is not part of this review", path) }
  end

  vim.api.nvim_set_current_tabpage(ctx.tab)
  session:open_file(path)
  if ctx.entry and ctx.entry.panel then
    ctx.entry.panel:set_cursor(path)
  end
  local line = tonumber(args.line)
  if line then
    session:focus_line(line)
  end
  return { ok = true, data = { path = path, line = line } }
end

--- Run `op` against the live entry on `args.tab` -- the RPC transport. nvim_exec_lua
--- runs this on the target instance's main loop, so every mutation takes the exact same
--- path as a keypress; that single-writer property is what makes external writes safe
--- alongside a live UI (no state-file clobbering, no comment_seq collisions).
---@param op string
---@param args table?
---@return diffly.agent.Result
function M.dispatch(op, args)
  args = args or {}
  local handler = ops[op]
  if not handler then
    return { ok = false, error = string.format("diffly: unknown operation %q", tostring(op)) }
  end

  local diffly = package.loaded["diffly"]
  local entry = type(diffly) == "table"
      and type(diffly._entries) == "table"
      and diffly._entries[args.tab]
    or nil
  if not entry or not vim.api.nvim_tabpage_is_valid(args.tab) then
    return { ok = false, error = "diffly: that session is gone (its tab was closed?)" }
  end

  local ok, result = pcall(handler, { session = entry.session, tab = args.tab, entry = entry }, args)
  if not ok then
    return { ok = false, error = tostring(result) }
  end
  return result
end

--- Run `op` against a fresh data-only session (noop view, same shape as init.lua's
--- `:Diffly clean` probe) -- the fallback when no live instance holds this repo's
--- review. Mutations still flow through Session's save funnel; the single-writer
--- property holds because the CLI only lands here after probing for live sessions.
---@param op string
---@param args table?
---@return diffly.agent.Result
function M.run_headless(op, args)
  args = args or {}
  local handler = ops[op]
  if not handler then
    return { ok = false, error = string.format("diffly: unknown operation %q", tostring(op)) }
  end

  local noop_view = { open = function() end, close = function() end }
  local session, err = require("diffly.session").new({
    view_factory = function()
      return noop_view
    end,
    base = args.base,
  })
  if not session then
    return { ok = false, error = err }
  end

  if args.remote then
    if session.pr then
      -- One-shot process: waiting out fetch_threads here adds no new async seam to the
      -- plugin -- vim.wait pumps the vim.schedule'd completion.
      local github = require("diffly.github")
      local done, threads, fetch_err = false, nil, nil
      local handle, start_err = github.fetch_threads(session.spec.repo, session.pr, function(t, e)
        threads, fetch_err, done = t, e, true
      end)
      if not handle then
        vim.notify(
          "diffly: could not fetch review threads: " .. (start_err or "?"),
          vim.log.levels.WARN
        )
      else
        vim.wait(30000, function()
          return done
        end, 10)
        if threads then
          session:set_remote_threads(threads)
        else
          vim.notify(
            "diffly: could not fetch review threads: " .. (fetch_err or "timed out"),
            vim.log.levels.WARN
          )
        end
      end
    else
      vim.notify("diffly: no PR detected; remote threads unavailable", vim.log.levels.INFO)
    end
  end

  local ok, result = pcall(handler, { session = session }, args)
  if not ok then
    return { ok = false, error = tostring(result) }
  end
  return result
end

return M
