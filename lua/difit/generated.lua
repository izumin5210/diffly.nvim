-- Pure classifier ported from github-linguist's `lib/linguist/generated.rb` (read
-- verbatim from a local clone while writing this -- no rule here was invented). Detects
-- files GitHub itself collapses in PR diffs ("Generated files are not rendered by
-- default"): vendored dependency trees, lockfiles, and compiler/codegen output.
--
-- `M.generated(path, lines)` is the ENTIRE public surface, deliberately -- everything else
-- in this file is a private, 1:1 port of one `generated.rb` predicate method. Callers
-- decide WHICH content to pass as `lines` (`ui/guard.lua`'s `M.is_generated`); this module
-- never touches git or the filesystem itself, which is what makes it exhaustively
-- table-driven-testable without a real repo (tests/test_generated.lua).
--
-- Deliberate omissions (present in some other tools, absent from upstream linguist, so
-- absent here too -- see the module's own doc comment on why `generated?` doesn't chain
-- them): no generic `@generated` marker rule, no generic "DO NOT EDIT" rule, and
-- `yarn.lock`/`Gemfile.lock`/`go.sum` are NOT treated as generated (linguist doesn't
-- either). Users get GitHub's own extension point instead: `.gitattributes`
-- `linguist-generated` (see `ui/guard.lua`), not a difit-specific pattern list.
--
-- Ruby/Lua semantic gap this file works around once, centrally, rather than per rule:
-- Ruby's `data.split("\n", -1)` (what `generated.rb`'s own `lines` method computes) keeps
-- a trailing empty string when `data` ends in "\n" -- the overwhelmingly common case for a
-- real source file. Our `lines` argument arrives already stripped of exactly one trailing
-- newline (`git.lua`'s `split_lines`/`vim.fn.readfile` shape), so it has ONE FEWER element
-- than Ruby's `lines` would for the same content. `ruby_lines()` below re-adds that
-- trailing "" unconditionally, so every ported rule's index arithmetic (`lines[0]`,
-- `lines[-2]`, `lines.first(3)`, ...) is copy-translatable straight from generated.rb
-- without re-deriving an off-by-one per rule. The one case this doesn't reproduce exactly
-- is a blob with NO trailing newline at all (Ruby wouldn't add the phantom "" there
-- either) -- accepted noise; every ported rule only ever reads a fixed head/tail window,
-- and a source file missing its final newline entirely is rare enough not to be worth
-- threading "did this end with \n" through `M.generated`'s signature.

local M = {}

-- ---------------------------------------------------------------------------------------
-- Ruby `lines`-array emulation (see module doc above).
-- ---------------------------------------------------------------------------------------

---@param lines string[]
---@return string[] rb  -- `lines` + one trailing "" (mirrors Ruby's `data.split("\n", -1)`)
local function ruby_lines(lines)
  local rb = {}
  for i, l in ipairs(lines) do
    rb[i] = l
  end
  rb[#rb + 1] = ""
  return rb
end

--- Ruby-style element access: 0-based positive index, or negative to count from the end
--- (`at(rb, 0)` == `lines[0]`, `at(rb, -2)` == `lines[-2]`). nil when out of range, same as
--- Ruby returning nil for an out-of-bounds index.
---@param rb string[]
---@param i integer
---@return string?
local function at(rb, i)
  if i < 0 then
    return rb[#rb + 1 + i]
  end
  return rb[i + 1]
end

--- `rb[0...n]` / Ruby's `lines.first(n)`.
---@param rb string[]
---@param n integer
---@return string[]
local function first(rb, n)
  local out = {}
  for i = 1, math.min(n, #rb) do
    out[i] = rb[i]
  end
  return out
end

--- Ruby's `lines.last(n)`.
---@param rb string[]
---@param n integer
---@return string[]
local function last(rb, n)
  local out = {}
  local start = math.max(1, #rb - n + 1)
  for i = start, #rb do
    out[#out + 1] = rb[i]
  end
  return out
end

--- Ruby's `File.extname`: substring from the LAST "." in the basename to the end, or ""
--- when there is no such "." or it's the basename's very first character (dotfiles like
--- ".gitignore" have no extension in Ruby's model). Case is preserved -- callers that need
--- a case-insensitive compare (several rules use `extname.downcase`) call `:lower()`
--- themselves, mirroring which rules do and don't in generated.rb.
---@param path string
---@return string
local function extname(path)
  local base = path:match("([^/]+)$") or path
  local dot = nil
  for i = #base, 1, -1 do
    if base:sub(i, i) == "." then
      dot = i
      break
    end
  end
  if not dot or dot == 1 then
    return ""
  end
  return base:sub(dot)
end

-- ---------------------------------------------------------------------------------------
-- Path-only rules (`generated.rb` methods that only ever look at `name`/`extname`).
-- ---------------------------------------------------------------------------------------

local XCODE_EXTS = { [".nib"] = true, [".xcworkspacedata"] = true, [".xcuserstate"] = true }

--- `vendor\/((?!-)[-0-9A-Za-z]+(?<!-)\.)+(com|edu|gov|in|me|net|org|fm|io)` -- hand-rolled
--- rather than translated to `vim.regex`: the character class `[-0-9A-Za-z]` excludes ".",
--- so `+` can only ever have ONE maximal extent at any starting position (it always stops
--- right before the next "." or non-matching char) -- there is no backtracking case this
--- greedy scan could get wrong, which is what makes a hand port exact here rather than an
--- approximation. Matches a TLD as a PREFIX of what follows the last "label.", same as the
--- source regex (no trailing boundary/anchor) -- e.g. "vendor/x.commercial/y" is flagged
--- too, same as upstream.
---@param path string
---@return boolean
local function go_vendor(path)
  local search_from = 1
  while true do
    local vstart = path:find("vendor/", search_from, true)
    if not vstart then
      return false
    end
    local pos = vstart + 7 -- #"vendor/"
    local matched_dot = false
    while true do
      local label_start = pos
      local i = pos
      while i <= #path and path:sub(i, i):match("[%-%d%a]") do
        i = i + 1
      end
      if i == label_start or path:sub(i, i) ~= "." then
        break
      end
      local label = path:sub(label_start, i - 1)
      if label:sub(1, 1) == "-" or label:sub(-1) == "-" then
        break
      end
      matched_dot = true
      pos = i + 1
    end
    if matched_dot then
      local rest = path:sub(pos)
      for _, tld in ipairs({ "com", "edu", "gov", "in", "me", "net", "org", "fm", "io" }) do
        if rest:sub(1, #tld) == tld then
          return true
        end
      end
    end
    search_from = vstart + 1
  end
end

--- One entry per `generated.rb` path-only predicate, in the source's declaration order.
--- `M.generated` short-circuits the first match -- no content ever needs loading for a
--- path-rule hit.
---@type fun(path: string): boolean[]
local PATH_RULES = {
  -- xcode_file?
  function(path)
    return XCODE_EXTS[extname(path)] == true
  end,
  -- intellij_file?  (?:^|/)\.idea/
  function(path)
    return path:match("^%.idea/") ~= nil or path:match("/%.idea/") ~= nil
  end,
  -- cocoapods?  (^Pods|/Pods)/
  function(path)
    return path:match("^Pods/") ~= nil or path:match("/Pods/") ~= nil
  end,
  -- carthage_build?  (^|/)Carthage/Build/
  function(path)
    return path:match("^Carthage/Build/") ~= nil or path:match("/Carthage/Build/") ~= nil
  end,
  -- generated_graphql_relay?  __generated__/
  function(path)
    return path:find("__generated__/", 1, true) ~= nil
  end,
  -- generated_net_designer_file?  \.designer\.(cs|vb)$/i
  function(path)
    local p = path:lower()
    return p:match("%.designer%.cs$") ~= nil or p:match("%.designer%.vb$") ~= nil
  end,
  -- generated_net_specflow_feature_file?  \.feature\.cs$/i
  function(path)
    return path:lower():match("%.feature%.cs$") ~= nil
  end,
  -- composer_lock?
  function(path)
    return path:find("composer.lock", 1, true) ~= nil
  end,
  -- cargo_lock?
  function(path)
    return path:find("Cargo.lock", 1, true) ~= nil
  end,
  -- cargo_orig?
  function(path)
    return path:find("Cargo.toml.orig", 1, true) ~= nil
  end,
  -- deno_lock?
  function(path)
    return path:find("deno.lock", 1, true) ~= nil
  end,
  -- flake_lock?  (^|/)flake\.lock$
  function(path)
    return path:match("^flake%.lock$") ~= nil or path:match("/flake%.lock$") ~= nil
  end,
  -- bazel_lock?  (^|/)MODULE\.bazel\.lock$
  function(path)
    return path:match("^MODULE%.bazel%.lock$") ~= nil or path:match("/MODULE%.bazel%.lock$") ~= nil
  end,
  -- node_modules?
  function(path)
    return path:find("node_modules/", 1, true) ~= nil
  end,
  -- go_vendor?
  go_vendor,
  -- go_lock?  (Gopkg|glide)\.lock
  function(path)
    return path:find("Gopkg.lock", 1, true) ~= nil or path:find("glide.lock", 1, true) ~= nil
  end,
  -- package_resolved?
  function(path)
    return path:find("Package.resolved", 1, true) ~= nil
  end,
  -- poetry_lock?
  function(path)
    return path:find("poetry.lock", 1, true) ~= nil
  end,
  -- pdm_lock?
  function(path)
    return path:find("pdm.lock", 1, true) ~= nil
  end,
  -- uv_lock?
  function(path)
    return path:find("uv.lock", 1, true) ~= nil
  end,
  -- pixi_lock?
  function(path)
    return path:find("pixi.lock", 1, true) ~= nil
  end,
  -- esy_lock?  (^|/)(\w+\.)?esy.lock$  ("esy.lock"'s middle "." is unescaped in the
  -- source -- deliberately "any char", not just literal "." -- ported as-is)
  function(path)
    return path:match("^esy.lock$") ~= nil
      or path:match("/esy.lock$") ~= nil
      or path:match("^[%w_]+%.esy.lock$") ~= nil
      or path:match("/[%w_]+%.esy.lock$") ~= nil
  end,
  -- npm_shrinkwrap_or_package_lock?
  function(path)
    return path:find("npm-shrinkwrap.json", 1, true) ~= nil
      or path:find("package-lock.json", 1, true) ~= nil
  end,
  -- pnpm_lock?
  function(path)
    return path:find("pnpm-lock.yaml", 1, true) ~= nil
  end,
  -- bun_lock?  (?:^|/)bun\.lockb?$
  function(path)
    return path:match("^bun%.lockb?$") ~= nil or path:match("/bun%.lockb?$") ~= nil
  end,
  -- terraform_lock?  (?:^|/)\.terraform\.lock\.hcl$
  function(path)
    return path:match("^%.terraform%.lock%.hcl$") ~= nil
      or path:match("/%.terraform%.lock%.hcl$") ~= nil
  end,
  -- generated_yarn_plugnplay?  (^|/)\.pnp\..*$  (the trailing ".*$" is trivially
  -- satisfiable -- zero or more of any char to end of string -- so only the literal
  -- ".pnp." prefix at a segment boundary actually constrains anything)
  function(path)
    return path:find("^%.pnp%.") ~= nil or path:find("/%.pnp%.") ~= nil
  end,
  -- godeps?
  function(path)
    return path:find("Godeps/", 1, true) ~= nil
  end,
  -- generated_by_zephir?  .\.zep\.(?:c|h|php)$  (leading "." is "any one char", so a bare
  -- ".zep.c" with nothing before it is a minor accepted divergence -- vanishingly rare)
  function(path)
    return path:match("%.zep%.c$") ~= nil
      or path:match("%.zep%.h$") ~= nil
      or path:match("%.zep%.php$") ~= nil
  end,
  -- gradle_wrapper?  (?:^|/)gradlew(?:\.bat)?$/i
  function(path)
    local p = path:lower()
    return p:match("^gradlew$") ~= nil
      or p:match("/gradlew$") ~= nil
      or p:match("^gradlew%.bat$") ~= nil
      or p:match("/gradlew%.bat$") ~= nil
  end,
  -- maven_wrapper?  (?:^|/)mvnw(?:\.cmd)?$/i
  function(path)
    local p = path:lower()
    return p:match("^mvnw$") ~= nil
      or p:match("/mvnw$") ~= nil
      or p:match("^mvnw%.cmd$") ~= nil
      or p:match("/mvnw%.cmd$") ~= nil
  end,
  -- mise_lock?  (?:^|/)mise(?:\.[^/]+)?\.lock$
  function(path)
    return path:match("^mise%.lock$") ~= nil
      or path:match("/mise%.lock$") ~= nil
      or path:match("^mise%.[^/]+%.lock$") ~= nil
      or path:match("/mise%.[^/]+%.lock$") ~= nil
  end,
  -- julia_manifest?  (?:^|/)(Julia)?Manifest(-v\d+\.\d+)?\.toml$
  function(path)
    for _, anchor in ipairs({ "^", "/" }) do
      if
        path:match(anchor .. "Manifest%.toml$")
        or path:match(anchor .. "JuliaManifest%.toml$")
        or path:match(anchor .. "Manifest%-v%d+%.%d+%.toml$")
        or path:match(anchor .. "JuliaManifest%-v%d+%.%d+%.toml$")
      then
        return true
      end
    end
    return false
  end,
  -- pipenv_lock?
  function(path)
    return path:find("Pipfile.lock", 1, true) ~= nil
  end,
  -- generated_pascal_tlb?  _tlb\.pas$/i
  function(path)
    return path:lower():match("_tlb%.pas$") ~= nil
  end,
  -- htmlcov?  (?:^|/)htmlcov/
  function(path)
    return path:match("^htmlcov/") ~= nil or path:match("/htmlcov/") ~= nil
  end,
  -- generated_sqlx_query?  (?:^|/)\.sqlx/query-[a-f\d]{64}\.json$
  function(path)
    local hex64 = ("[a-f%d]"):rep(64)
    return path:match("^%.sqlx/query%-" .. hex64 .. "%.json$") ~= nil
      or path:match("/%.sqlx/query%-" .. hex64 .. "%.json$") ~= nil
  end,
}

-- ---------------------------------------------------------------------------------------
-- Content rules (`generated.rb` methods that read `lines`/`extname` together). Each entry
-- is `fn(path, ext, rb) -> boolean`, `ext` = `extname(path)`, `rb` = `ruby_lines(lines)`.
-- ---------------------------------------------------------------------------------------

local function maybe_minified(ext)
  local e = ext:lower()
  return e == ".js" or e == ".css"
end

--- `has_source_map?`'s per-line regex:
--- `^\/[*\/][\#@] source(?:Mapping)?URL|sourceURL=` -- top-level `|` means TWO independent
--- alternatives (an anchored "//# sourceURL"/"/*# sourceMappingURL"-shaped prefix, OR the
--- substring "sourceURL=" anywhere), not one alternation nested inside the anchor.
---@param l string
---@return boolean
local function source_map_ref_line(l)
  return l:match("^//[#@] sourceURL") ~= nil
    or l:match("^//[#@] sourceMappingURL") ~= nil
    or l:match("^/%*[#@] sourceURL") ~= nil
    or l:match("^/%*[#@] sourceMappingURL") ~= nil
    or l:find("sourceURL=", 1, true) ~= nil
end

local SCORE_A = { "_fn", "_i", "_len", "_ref", "_results" }
local SCORE_B = { "__bind", "__extends", "__hasProp", "__indexOf", "__slice" }

--- Count of (possibly overlapping-in-position-but-not-token) occurrences of every token in
--- `tokens` within `line` -- backs `compiled_coffeescript?`'s
--- `line.gsub(/(_fn|_i|_len|_ref|_results)/).count`-style scoring. A reasonable,
--- documented approximation of Ruby's single-pass alternation scan (which commits to the
--- first alternative matching at each position and advances past it): counting each
--- token's own non-overlapping occurrences independently can overcount on adversarial
--- input where two tokens' matches would overlap the same characters, which none of these
--- specific tokens realistically do in real CoffeeScript output.
---@param line string
---@param tokens string[]
---@return integer
local function count_tokens(line, tokens)
  local total = 0
  for _, tok in ipairs(tokens) do
    local init = 1
    while true do
      local s = line:find(tok, init, true)
      if not s then
        break
      end
      total = total + 1
      init = s + #tok
    end
  end
  return total
end

--- `generated_html?`'s simplified `<meta name="generator" content="...">` scan: quoted
--- attribute values only (Ruby's own regex also accepts an unquoted `[^\s"']+` form, and
--- its attribute scan uses a lookbehind-guarded token scan rather than fixed key=value
--- pairs) -- deliberate simplification, documented divergence from generated.rb, but
--- covers the overwhelmingly common `<meta name="generator" content="...">` shape every
--- generator listed below actually emits.
---@param tag_body string
---@return table<string,string>
local function extract_meta_attrs(tag_body)
  local attrs = {}
  for key, val in tag_body:gmatch('(%a+)%s*=%s*"([^"]*)"') do
    attrs[key:lower()] = val
  end
  for key, val in tag_body:gmatch("(%a+)%s*=%s*'([^']*)'") do
    if not attrs[key:lower()] then
      attrs[key:lower()] = val
    end
  end
  return attrs
end

local HTML_GENERATOR_PATTERNS = {
  "^org%s+mode",
  "^j?latex2html",
  "^groff",
  "^makeinfo",
  "^texi2html",
  "^ronn",
}

--- `generated_postscript?`'s "%%Creator: " line, searched over the first 10 lines only.
---@param rb string[]
---@return string?
local function find_ps_creator(rb)
  for _, l in ipairs(first(rb, 10)) do
    if l:match("^%%%%Creator: ") then
      return l
    end
  end
  return nil
end

--- One entry per `generated.rb` content predicate, source declaration order.
---@type fun(path: string, ext: string, rb: string[]): boolean[]
local CONTENT_RULES = {
  -- minified_files?  (integer division, matching Ruby's Integer#/ on two Integers)
  function(_, ext, rb)
    if not maybe_minified(ext) or #rb == 0 then
      return false
    end
    local total = 0
    for _, l in ipairs(rb) do
      total = total + #l
    end
    return math.floor(total / #rb) > 110
  end,
  -- has_source_map?
  function(_, ext, rb)
    if not maybe_minified(ext) then
      return false
    end
    for _, l in ipairs(last(rb, 2)) do
      if source_map_ref_line(l) then
        return true
      end
    end
    return false
  end,
  -- source_map?
  function(path, ext, rb)
    if ext:lower() ~= ".map" then
      return false
    end
    local lower_path = path:lower()
    if lower_path:match("%.css%.map$") or lower_path:match("%.js%.map$") then
      return true
    end
    local l0 = at(rb, 0) or ""
    if l0:match('^{"version":%d+,') then
      return true
    end
    if l0:match("^/%*%* Begin line maps%. %*%*/{") then
      return true
    end
    return false
  end,
  -- compiled_coffeescript?
  function(_, ext, rb)
    if ext ~= ".js" then
      return false
    end
    local l0 = at(rb, 0) or ""
    if l0:match("^// Generated by ") then
      return true
    end
    if at(rb, 0) == "(function() {" and at(rb, -2) == "}).call(this);" and at(rb, -1) == "" then
      local score = 0
      for _, line in ipairs(rb) do
        if line:find("var ", 1, true) then
          score = score + 1 * count_tokens(line, SCORE_A)
          score = score + 3 * count_tokens(line, SCORE_B)
        end
      end
      return score >= 3
    end
    return false
  end,
  -- generated_parser?  (PEG.js) -- simplified: does not verify the "Generated by PEG.js"
  -- marker sits inside the SAME unclosed block comment the "/*" opens, just that a "/*"
  -- precedes it somewhere within the first 5 lines joined. Documented divergence;
  -- PEG.js's own output always puts the marker in the file's very first comment block, so
  -- this only differs from generated.rb on adversarial/hand-crafted input.
  function(_, ext, rb)
    if ext ~= ".js" then
      return false
    end
    local joined = table.concat(first(rb, 5), "")
    local open_pos = joined:find("/*", 1, true)
    if not open_pos then
      return false
    end
    return joined:find("Generated by PEG.js", open_pos, true) ~= nil
  end,
  -- generated_net_docfile?
  function(_, ext, rb)
    if ext:lower() ~= ".xml" then
      return false
    end
    if #rb <= 3 then
      return false
    end
    local l1, l2, lm2 = at(rb, 1), at(rb, 2), at(rb, -2)
    return l1 ~= nil
      and l1:find("<doc>", 1, true) ~= nil
      and l2 ~= nil
      and l2:find("<assembly>", 1, true) ~= nil
      and lm2 ~= nil
      and lm2:find("</doc>", 1, true) ~= nil
  end,
  -- generated_postscript?
  function(_, ext, rb)
    if not (ext == ".ps" or ext == ".eps" or ext == ".pfa") then
      return false
    end

    for _, l in ipairs(rb) do
      if l:match("^%s*currentfile eexec%s") or l:match("^%s*/sfnts%s+%[%s*<") then
        return true
      end
    end

    local creator = find_ps_creator(rb)
    if not creator then
      return false
    end

    if
      creator:find("%d")
      or creator:find("draw", 1, true)
      or creator:find("mpage", 1, true)
      or creator:find("ImageMagick", 1, true)
      or creator:find("inkscape", 1, true)
      or creator:find("MATLAB", 1, true)
    then
      return true
    end
    if
      creator:find("PCBNEW", 1, true)
      or creator:find("pnmtops", 1, true)
      or creator:find("(Unknown)", 1, true)
      or creator:find("Serif Affinity", 1, true)
      or creator:find("Filterimage -tops", 1, true)
    then
      return true
    end

    if creator:find("EAGLE", 1, true) then
      for _, l in ipairs(first(rb, 5)) do
        if l:match("^%%%%Title: EAGLE Drawing ") then
          return true
        end
      end
    end
    return false
  end,
  -- compiled_cython_file?
  function(_, ext, rb)
    if not (ext == ".c" or ext == ".cpp") then
      return false
    end
    if #rb <= 1 then
      return false
    end
    local l0 = at(rb, 0) or ""
    return l0:find("Generated by Cython", 1, true) ~= nil
  end,
  -- generated_go?
  function(_, ext, rb)
    if ext ~= ".go" then
      return false
    end
    if #rb <= 1 then
      return false
    end
    for _, l in ipairs(first(rb, 40)) do
      if l:find("^// Code generated ") then
        return true
      end
    end
    return false
  end,
  -- generated_protocol_buffer_from_go?
  function(_, ext, rb)
    if ext ~= ".proto" then
      return false
    end
    if #rb <= 1 then
      return false
    end
    for _, l in ipairs(first(rb, 20)) do
      if l:find("This file was autogenerated by go-to-protobuf", 1, true) then
        return true
      end
    end
    return false
  end,
  -- generated_protocol_buffer?
  function(_, ext, rb)
    local PROTOBUF_EXTS = {
      [".py"] = true,
      [".java"] = true,
      [".h"] = true,
      [".cc"] = true,
      [".cpp"] = true,
      [".m"] = true,
      [".rb"] = true,
      [".php"] = true,
    }
    if not PROTOBUF_EXTS[ext] then
      return false
    end
    if #rb <= 1 then
      return false
    end
    for _, l in ipairs(first(rb, 3)) do
      if l:find("Generated by the protocol buffer compiler.  DO NOT EDIT!", 1, true) then
        return true
      end
    end
    return false
  end,
  -- generated_javascript_protocol_buffer?
  function(_, ext, rb)
    if ext ~= ".js" then
      return false
    end
    if #rb <= 6 then
      return false
    end
    local l5 = at(rb, 5)
    return l5 ~= nil and l5:find("GENERATED CODE -- DO NOT EDIT!", 1, true) ~= nil
  end,
  -- generated_typescript_protocol_buffer?
  function(_, ext, rb)
    if ext ~= ".ts" then
      return false
    end
    if #rb <= 4 then
      return false
    end
    local l0 = at(rb, 0)
    return l0 ~= nil
      and l0:find("Code generated by protoc-gen-ts_proto. DO NOT EDIT.", 1, true) ~= nil
  end,
  -- generated_apache_thrift?  (no lines.count guard in the source)
  function(_, ext, rb)
    local THRIFT_EXTS = {
      [".rb"] = true,
      [".py"] = true,
      [".go"] = true,
      [".js"] = true,
      [".m"] = true,
      [".java"] = true,
      [".h"] = true,
      [".cc"] = true,
      [".cpp"] = true,
      [".php"] = true,
    }
    if not THRIFT_EXTS[ext] then
      return false
    end
    for _, l in ipairs(first(rb, 6)) do
      if l:find("Autogenerated by Thrift Compiler", 1, true) then
        return true
      end
    end
    return false
  end,
  -- generated_jni_header?
  function(_, ext, rb)
    if ext ~= ".h" then
      return false
    end
    if #rb <= 2 then
      return false
    end
    local l0, l1 = at(rb, 0), at(rb, 1)
    return l0 ~= nil
      and l0:find("/* DO NOT EDIT THIS FILE - it is machine generated */", 1, true) ~= nil
      and l1 ~= nil
      and l1:find("#include <jni.h>", 1, true) ~= nil
  end,
  -- vcr_cassette?
  function(_, ext, rb)
    if ext ~= ".yml" then
      return false
    end
    if #rb <= 2 then
      return false
    end
    local lm2 = at(rb, -2)
    return lm2 ~= nil and lm2:find("recorded_with: VCR", 1, true) ~= nil
  end,
  -- generated_antlr?
  function(_, ext, rb)
    if ext ~= ".g" then
      return false
    end
    if #rb <= 2 then
      return false
    end
    local l1 = at(rb, 1)
    return l1 ~= nil and l1:find("generated by Xtest", 1, true) ~= nil
  end,
  -- generated_module?  (KiCAD / GFortran .mod)
  function(_, ext, rb)
    if ext ~= ".mod" then
      return false
    end
    if #rb <= 1 then
      return false
    end
    local l0 = at(rb, 0) or ""
    return l0:find("PCBNEW-LibModule-V", 1, true) ~= nil
      or l0:find("GFORTRAN module version '", 1, true) ~= nil
  end,
  -- generated_unity3d_meta?
  function(_, ext, rb)
    if ext ~= ".meta" then
      return false
    end
    if #rb <= 1 then
      return false
    end
    local l0 = at(rb, 0)
    return l0 ~= nil and l0:find("fileFormatVersion: ", 1, true) ~= nil
  end,
  -- generated_racc?
  function(_, ext, rb)
    if ext ~= ".rb" then
      return false
    end
    if #rb <= 2 then
      return false
    end
    local l2 = at(rb, 2)
    return l2 ~= nil and vim.startswith(l2, "# This file is automatically generated by Racc")
  end,
  -- generated_jflex?
  function(_, ext, rb)
    if ext ~= ".java" then
      return false
    end
    if #rb <= 1 then
      return false
    end
    local l0 = at(rb, 0)
    return l0 ~= nil and vim.startswith(l0, "/* The following code was generated by JFlex ")
  end,
  -- generated_grammarkit?
  function(_, ext, rb)
    if ext ~= ".java" then
      return false
    end
    if #rb <= 1 then
      return false
    end
    local l0 = at(rb, 0)
    return l0 ~= nil
      and vim.startswith(l0, "// This is a generated file. Not intended for manual editing.")
  end,
  -- generated_roxygen2?
  function(_, ext, rb)
    if ext ~= ".Rd" then
      return false
    end
    if #rb <= 1 then
      return false
    end
    local l0 = at(rb, 0)
    return l0 ~= nil and l0:find("% Generated by roxygen2: do not edit by hand", 1, true) ~= nil
  end,
  -- generated_jison?
  function(_, ext, rb)
    if ext ~= ".js" then
      return false
    end
    if #rb <= 1 then
      return false
    end
    local l0 = at(rb, 0)
    return l0 ~= nil
      and (
        vim.startswith(l0, "/* parser generated by jison ")
        or vim.startswith(l0, "/* generated by jison-lex ")
      )
  end,
  -- generated_grpc_cpp?
  function(_, ext, rb)
    local GRPC_CPP_EXTS = { [".cpp"] = true, [".hpp"] = true, [".h"] = true, [".cc"] = true }
    if not GRPC_CPP_EXTS[ext] then
      return false
    end
    if #rb <= 1 then
      return false
    end
    local l0 = at(rb, 0)
    return l0 ~= nil and vim.startswith(l0, "// Generated by the gRPC")
  end,
  -- generated_dart?  ("generated code\W{2,3}do not modify", case-insensitive via
  -- downcase; {2,3} ported as two explicit fixed-width alternatives since Lua patterns
  -- have no bounded-repetition quantifier)
  function(_, ext, rb)
    if ext ~= ".dart" then
      return false
    end
    if #rb <= 1 then
      return false
    end
    for _, l in ipairs(first(rb, 3)) do
      local lower = l:lower()
      if
        lower:match("generated code%W%Wdo not modify")
        or lower:match("generated code%W%W%Wdo not modify")
      then
        return true
      end
    end
    return false
  end,
  -- generated_perl_ppport_header?
  function(path, _, rb)
    if not path:match("ppport%.h$") then
      return false
    end
    if #rb <= 10 then
      return false
    end
    local l8 = at(rb, 8)
    return l8 ~= nil and l8:find("Automatically created by Devel::PPPort", 1, true) ~= nil
  end,
  -- generated_gamemakerstudio?
  function(_, ext, rb)
    if not (ext == ".yy" or ext == ".yyp") then
      return false
    end
    if #rb <= 3 then
      return false
    end
    local joined = table.concat(first(rb, 3), "")
    if joined:match("^%s*[%{%[]") then
      return true
    end
    local l0 = at(rb, 0) or ""
    return l0:match("^%d%.%d%.%d.+|%{") ~= nil
  end,
  -- generated_gimp?
  function(_, ext, rb)
    if not (ext == ".c" or ext == ".h") then
      return false
    end
    if #rb <= 0 then
      return false
    end
    local l0 = at(rb, 0) or ""
    if l0:match("^/%* GIMP [%a%d%- ]+ C%-Source image dump %(.-%.c%) %*/") then
      return true
    end
    if l0:match("^/%*  GIMP header image file format %([%a%d%- ]+%): .-%.h  %*/") then
      return true
    end
    return false
  end,
  -- generated_visualstudio6?
  function(_, ext, rb)
    if ext:lower() ~= ".dsp" then
      return false
    end
    for _, l in ipairs(first(rb, 3)) do
      if l:find("# Microsoft Developer Studio Generated Build File", 1, true) then
        return true
      end
    end
    return false
  end,
  -- generated_haxe?
  function(_, ext, rb)
    local HAXE_EXTS = {
      [".js"] = true,
      [".py"] = true,
      [".lua"] = true,
      [".cpp"] = true,
      [".h"] = true,
      [".java"] = true,
      [".cs"] = true,
      [".php"] = true,
    }
    if not HAXE_EXTS[ext] then
      return false
    end
    for _, l in ipairs(first(rb, 3)) do
      if l:find("Generated by Haxe", 1, true) then
        return true
      end
    end
    return false
  end,
  -- generated_html?  (pkgdown/mandoc/doxygen ported verbatim; the generic
  -- <meta name="generator"> scan is simplified -- see `extract_meta_attrs`'s doc comment)
  function(path, _, rb)
    local ext = extname(path):lower()
    if not (ext == ".html" or ext == ".htm" or ext == ".xhtml") then
      return false
    end
    if #rb <= 1 then
      return false
    end

    for _, l in ipairs(first(rb, 2)) do
      if l:find("<!-- Generated by pkgdown: do not edit by hand -->", 1, true) then
        return true
      end
    end

    if #rb > 2 then
      local l2 = at(rb, 2)
      if l2 and vim.startswith(l2, "<!-- This is an automatically generated file.") then
        return true
      end
    end

    for _, l in ipairs(first(rb, 31)) do
      if l:lower():match("<!%-%-%s+generated by doxygen%s+[%.%d]+%s*%-%->") then
        return true
      end
    end

    local joined = table.concat(first(rb, 31), " ")
    for tag_body in joined:gmatch("<meta%s+([^>]-)>") do
      local attrs = extract_meta_attrs(tag_body)
      if attrs.name and attrs.name:lower() == "generator" then
        local content = (attrs.content or attrs.value or ""):lower()
        for _, pat in ipairs(HTML_GENERATOR_PATTERNS) do
          if content:match(pat) then
            return true
          end
        end
      end
    end

    return false
  end,
  -- generated_jooq?
  function(_, ext, rb)
    if ext:lower() ~= ".java" then
      return false
    end
    for _, l in ipairs(first(rb, 2)) do
      if l:find("This file is generated by jOOQ.", 1, true) then
        return true
      end
    end
    return false
  end,
  -- generated_sorbet_rbi?
  function(_, ext, rb)
    if ext:lower() ~= ".rbi" then
      return false
    end
    if #rb < 5 then
      return false
    end
    local l0, l2, l4 = at(rb, 0), at(rb, 2), at(rb, 4)
    return l0 ~= nil
      and l0:match("^# typed:") ~= nil
      and l2 ~= nil
      and l2:find("DO NOT EDIT MANUALLY", 1, true) ~= nil
      and l4 ~= nil
      and (
        l4:match("^# Please run `bin/tapioca") ~= nil
        or l4:match("^# Please instead update this file by running `bin/tapioca") ~= nil
      )
  end,
  -- generated_mysql_view_definition_format?
  function(_, ext, rb)
    if ext:lower() ~= ".frm" then
      return false
    end
    local l0 = at(rb, 0)
    return l0 ~= nil and l0:find("TYPE=VIEW", 1, true) ~= nil
  end,
}

--- Is `path` (with `lines` -- the content the caller is about to render, already split,
--- no trailing newline) a generated file per linguist's own heuristics? Path rules run
--- first (cheap, no content needed); content rules only run if every path rule missed.
---@param path string
---@param lines string[]
---@return boolean
function M.generated(path, lines)
  for _, rule in ipairs(PATH_RULES) do
    if rule(path) then
      return true
    end
  end

  local ext = extname(path)
  local rb = ruby_lines(lines)
  for _, rule in ipairs(CONTENT_RULES) do
    if rule(path, ext, rb) then
      return true
    end
  end

  return false
end

-- Exposed for the report/tests only -- not part of the module's real contract.
M._path_rule_count = #PATH_RULES
M._content_rule_count = #CONTENT_RULES

return M
