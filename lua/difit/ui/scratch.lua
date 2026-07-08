-- Shared `difit://` scratch-buffer helper (docs/refactor-v1.md R4). Replaces the
-- find-or-create/configure logic that used to be triplicated across ui/panel.lua,
-- ui/sidebyside.lua (`owned_buffer`) and ui/unified.lua (`get_or_create_buf`).
--
-- Two responsibilities live here:
--
-- 1. Naming: every owned buffer name is `difit://<kind>/<session_id>/<rest>` (or, when
--    there is no further path, `difit://<kind>/<session_id>`). `session_id` is a
--    per-session discriminator the caller supplies -- e.g. `ctx.anchor` (the panel
--    window id, stable and unique for a session's whole lifetime) for the diff views, or
--    a buffer's own number for the panel. Without it, two concurrent reviews whose
--    entries happen to share a blob sha (or, for the panel, if buffer numbers were ever
--    reused) would collide on the exact same buffer name -- `nvim_buf_set_name` on the
--    second session would then silently repoint the FIRST session's buffer, and that
--    view's own `close()` would tear down windows the other session still owns. Putting
--    `kind` before `session_id` (rather than the other way around, as the design doc's
--    example shows) means the well-known "difit://panel/" and "difit://unified/" name
--    prefixes existing code already keys off of keep working unchanged.
--
-- 2. LSP-safe syntax highlighting: `difit://` buffers must never get `'filetype'` set.
--    Setting it fires `FileType` autocmds, which is how LSP clients typically attach and
--    send `didOpen` -- on a URI a server was never meant to see, some servers crash
--    outright (a codediff.nvim finding this project inherited by not knowing about it
--    yet). Resolving a language and asking `vim.treesitter.start` to highlight with it
--    directly, or falling back to the legacy `'syntax'` option, gets the same visual
--    result without ever going through `'filetype'`/`FileType` at all.

local M = {}

---@class difit.ui.scratch.Opts
---@field lines string[]?     -- content to write; applied ONLY when this call creates a
-- fresh buffer, never re-applied when an existing one with
-- the same name is reused (callers whose name embeds
-- content identity, e.g. a blob sha, rely on this to make
-- reuse content-safe; callers whose name does NOT embed
-- content identity, e.g. unified's per-path patch buffer,
-- instead re-fill content themselves on every call)
---@field modifiable boolean? -- when `lines` is absent, explicitly set the initial
-- `modifiable` state (used by callers, like the panel, that
-- manage their own content/modifiable toggling directly)
---@field filename string?    -- resolve a highlight language via `vim.filetype.match`
---@field lang string?        -- explicit highlight language; wins over `filename`

--- Build a `difit://` buffer name embedding `session_id` as a collision-proof
--- discriminator (see the module doc above).
---@param kind string             -- e.g. "panel", "unified", "empty", "deleted", "binary", or a blob sha
---@param session_id integer|string
---@param rest string?            -- further path, e.g. the reviewed file's relative path
---@return string
function M.name(kind, session_id, rest)
  if rest then
    return string.format("difit://%s/%s/%s", kind, tostring(session_id), rest)
  end
  return string.format("difit://%s/%s", kind, tostring(session_id))
end

--- Apply LSP-safe highlighting to `buf`: treesitter when a parser is available for the
--- resolved language, else the legacy `'syntax'` option -- `'filetype'` itself is never
--- touched. A no-op when neither `opts.lang` nor a resolvable `opts.filename` yields a
--- language (e.g. the panel's plain-text tree buffer, which draws its own extmarks and
--- needs neither).
---@param buf integer
---@param opts { lang: string?, filename: string? }?
function M.highlight(buf, opts)
  opts = opts or {}
  local lang = opts.lang or (opts.filename and vim.filetype.match({ filename = opts.filename }))
  if not lang or lang == "" then
    return
  end
  -- `vim.treesitter.start` raises when no parser is installed for `lang`; the `pcall`
  -- IS the "is a parser available" check the fallback branch depends on.
  if not pcall(vim.treesitter.start, buf, lang) then
    vim.bo[buf].syntax = lang
  end
end

--- Configure an already-created scratch buffer in place: `buftype=nofile`,
--- `bufhidden=hide`, `swapfile=false`, optional content fill (see `Opts.lines`), and
--- LSP-safe highlighting. Split out from `find_or_create` so callers that must create
--- their own buffer up front (the panel names itself after its own, not-yet-known-until-
--- created bufnr) can still share the option-setting logic.
---@param buf integer
---@param opts difit.ui.scratch.Opts?
function M.configure(buf, opts)
  opts = opts or {}
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false

  if opts.lines then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
    vim.bo[buf].modifiable = false
  elseif opts.modifiable ~= nil then
    vim.bo[buf].modifiable = opts.modifiable
  end

  M.highlight(buf, opts)
end

--- Get-or-create a difit-owned scratch buffer named `name`. Reuses an existing buffer
--- with the exact same name instead of recreating it -- `opts.lines`/highlighting are
--- only ever applied on the creating call, per `Opts.lines`'s doc above.
---@param name string
---@param opts difit.ui.scratch.Opts?
---@return integer bufnr
---@return boolean created  -- true iff this call just created (rather than reused) the buffer
function M.find_or_create(name, opts)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return existing, false
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  M.configure(buf, opts)
  return buf, true
end

return M
