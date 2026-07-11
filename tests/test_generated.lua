-- Tests for lua/diffly/generated.lua: the pure classifier ported from github-linguist's
-- `lib/linguist/generated.rb`. No child Neovim, no git, no repo -- `M.generated(path,
-- lines)` is pure, so every case here is table-driven path/content fixtures straight
-- against the module. Table-driven per rule (positive + negative pairs where cheap),
-- mirroring the ported rule's own doc comment in generated.lua.

local generated = require("diffly.generated")

local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

---@param cases { path: string, lines: string[]?, want: boolean, label: string }[]
local function run_cases(cases)
  for _, c in ipairs(cases) do
    eq(generated.generated(c.path, c.lines or {}), c.want, c.label)
  end
end

-- 1. Path-only rules (a representative dozen+, positive and negative where cheap) -------

T["path rules: Xcode / IDE / dependency-tree directories"] = function()
  run_cases({
    { path = "Foo.xcworkspacedata", want = true, label = "xcode xcworkspacedata" },
    { path = "Foo.nib", want = true, label = "xcode nib" },
    { path = "Foo.xcuserstate", want = true, label = "xcode xcuserstate" },
    { path = "Foo.plist", want = false, label = "xcode negative: unrelated extension" },
    { path = ".idea/workspace.xml", want = true, label = "intellij at root" },
    { path = "sub/.idea/misc.xml", want = true, label = "intellij nested" },
    {
      path = "sub/.idea2/misc.xml",
      want = false,
      label = "intellij negative: not a real .idea/ segment",
    },
    { path = "Pods/Alamofire/Alamofire.swift", want = true, label = "cocoapods at root" },
    { path = "app/Pods/Foo/Foo.swift", want = true, label = "cocoapods nested" },
    { path = "app/NotPods/Foo.swift", want = false, label = "cocoapods negative" },
    { path = "Carthage/Build/iOS/Foo.framework", want = true, label = "carthage build" },
    { path = "app/__generated__/schema.js", want = true, label = "graphql relay __generated__" },
  })
end

T["path rules: lockfiles across ecosystems"] = function()
  run_cases({
    { path = "composer.lock", want = true, label = "composer" },
    { path = "Cargo.lock", want = true, label = "cargo" },
    { path = "Cargo.toml.orig", want = true, label = "cargo orig" },
    { path = "Cargo.toml", want = false, label = "cargo.toml itself is not a lockfile" },
    { path = "deno.lock", want = true, label = "deno" },
    { path = "flake.lock", want = true, label = "nix flake" },
    { path = "Gopkg.lock", want = true, label = "go Gopkg" },
    { path = "glide.lock", want = true, label = "go glide" },
    { path = "Package.resolved", want = true, label = "swift package resolved" },
    { path = "poetry.lock", want = true, label = "poetry" },
    { path = "pdm.lock", want = true, label = "pdm" },
    { path = "uv.lock", want = true, label = "uv" },
    { path = "pixi.lock", want = true, label = "pixi" },
    { path = "esy.lock", want = true, label = "esy bare" },
    { path = "myproject.esy.lock", want = true, label = "esy prefixed" },
    { path = "npm-shrinkwrap.json", want = true, label = "npm shrinkwrap" },
    { path = "package-lock.json", want = true, label = "npm package-lock" },
    { path = "pnpm-lock.yaml", want = true, label = "pnpm" },
    { path = "bun.lock", want = true, label = "bun lock" },
    { path = "bun.lockb", want = true, label = "bun lockb" },
    { path = ".terraform.lock.hcl", want = true, label = "terraform" },
    { path = "Pipfile.lock", want = true, label = "pipenv" },
    { path = "MODULE.bazel.lock", want = true, label = "bazel bzlmod" },
    { path = "MODULE.bazel", want = false, label = "bazel module file itself is not a lock" },
    { path = "mise.lock", want = true, label = "mise bare" },
    { path = "mise.python.lock", want = true, label = "mise named" },
    -- Deliberate omissions (documented in generated.lua/README): linguist does NOT treat
    -- these as generated, so diffly doesn't either.
    { path = "yarn.lock", want = false, label = "yarn.lock is deliberately NOT generated" },
    { path = "Gemfile.lock", want = false, label = "Gemfile.lock is deliberately NOT generated" },
    { path = "go.sum", want = false, label = "go.sum is deliberately NOT generated" },
  })
end

T["path rules: node_modules/, Go vendor/, Godeps/"] = function()
  run_cases({
    { path = "node_modules/left-pad/index.js", want = true, label = "node_modules at root" },
    { path = "app/node_modules/foo/index.js", want = true, label = "node_modules nested" },
    {
      path = "vendor/golang.org/x/net/http2/hpack/hpack.go",
      want = true,
      label = "go vendor .org",
    },
    { path = "vendor/k8s.io/klog/klog.go", want = true, label = "go vendor .io" },
    { path = "vendor/gopkg.in/yaml.v2/yaml.go", want = true, label = "go vendor .in" },
    { path = "vendor/github.com/pkg/errors/errors.go", want = true, label = "go vendor .com" },
    { path = "vendor/README.md", want = false, label = "go vendor negative: no recognized TLD" },
    {
      path = "vendor/mylocallib/foo.go",
      want = false,
      label = "go vendor negative: no dotted domain",
    },
    { path = "Godeps/Godeps.json", want = true, label = "godeps" },
  })
end

T["path rules: wrappers, manifests, misc extensions"] = function()
  run_cases({
    { path = "gradlew", want = true, label = "gradle wrapper" },
    { path = "GRADLEW", want = true, label = "gradle wrapper case-insensitive" },
    { path = "gradlew.bat", want = true, label = "gradle wrapper bat" },
    { path = "mvnw", want = true, label = "maven wrapper" },
    { path = "mvnw.cmd", want = true, label = "maven wrapper cmd" },
    { path = "Manifest.toml", want = true, label = "julia manifest" },
    { path = "JuliaManifest.toml", want = true, label = "julia manifest prefixed" },
    { path = "Manifest-v1.10.toml", want = true, label = "julia manifest versioned" },
    { path = "MyManifest.toml", want = false, label = "julia manifest negative: wrong prefix" },
    { path = "Widget.designer.cs", want = true, label = ".net designer cs" },
    { path = "Widget.Designer.VB", want = true, label = ".net designer vb case-insensitive" },
    { path = "Login.feature.cs", want = true, label = "specflow feature.cs" },
    { path = "Foo_TLB.pas", want = true, label = "delphi tlb (case-insensitive)" },
    { path = "src/foo.zep.c", want = true, label = "zephir generated c" },
    { path = "src/foo.zep.php", want = true, label = "zephir generated php" },
    { path = "htmlcov/index.html", want = true, label = "coverage.py htmlcov" },
    {
      path = ".sqlx/query-" .. string.rep("a", 64) .. ".json",
      want = true,
      label = "sqlx query (64 hex chars)",
    },
    {
      path = ".sqlx/query-" .. string.rep("a", 10) .. ".json",
      want = false,
      label = "sqlx query negative: hash too short",
    },
    { path = ".pnp.cjs", want = true, label = "yarn plug'n'play" },
  })
end

-- 2. Content rules (every one, positive + negative) --------------------------------------

T["content rule: generated_go (first 40 lines, no DO-NOT-EDIT suffix required)"] = function()
  eq(
    generated.generated("main.go", { "package main", "// Code generated by mockgen. DO NOT EDIT." }),
    true
  )
  eq(
    generated.generated("main.go", { "package main", "// Code generated by mockgen." }),
    true,
    "no suffix required"
  )
  eq(generated.generated("main.go", { "package main", "// hand-written" }), false)
end

T["content rule: protocol buffer compiler header (first 3 lines, double space)"] = function()
  eq(
    generated.generated(
      "foo.pb.h",
      { "// Generated by the protocol buffer compiler.  DO NOT EDIT!", "x", "y" }
    ),
    true
  )
  eq(
    generated.generated(
      "foo.pb.h",
      { "// Generated by the protocol buffer compiler. DO NOT EDIT!", "x", "y" }
    ),
    false,
    "single space does not match -- double space is load-bearing"
  )
  eq(generated.generated("foo.h", { "hand written", "x", "y" }), false)
end

T["content rule: JS protobuf marker on the 6th line"] = function()
  local lines = { "1", "2", "3", "4", "5", "// GENERATED CODE -- DO NOT EDIT!", "7" }
  eq(generated.generated("foo_pb.js", lines), true)
  local wrong_line = { "// GENERATED CODE -- DO NOT EDIT!", "2", "3", "4", "5", "6" }
  eq(generated.generated("foo_pb.js", wrong_line), false, "marker on line 1, not line 6")
end

T["content rule: ts-proto marker on the 1st line"] = function()
  local lines = {
    "// Code generated by protoc-gen-ts_proto. DO NOT EDIT.",
    "// versions:",
    "x",
    "y",
    "z",
  }
  eq(generated.generated("foo.ts", lines), true)
  eq(
    generated.generated(
      "foo.ts",
      { "x", "// Code generated by protoc-gen-ts_proto. DO NOT EDIT.", "y", "z", "w" }
    ),
    false
  )
end

T["content rule: gRPC C++ marker on the 1st line"] = function()
  eq(generated.generated("foo.grpc.pb.cc", { "// Generated by the gRPC C++ plugin.", "x" }), true)
  eq(generated.generated("foo.grpc.pb.cc", { "hand written", "x" }), false)
end

T["content rule: Apache Thrift (first 6 lines, no line-count guard)"] = function()
  local lines = { "1", "2", "3", "4", "5", "Autogenerated by Thrift Compiler (0.9.2)" }
  eq(generated.generated("foo.rb", lines), true)
  eq(
    generated.generated("foo.rb", { "Autogenerated by Thrift Compiler" }),
    true,
    "short file still matches (no count guard)"
  )
  eq(generated.generated("foo.rb", { "hand written" }), false)
end

T["content rule: JNI header (lines 1-2 pair)"] = function()
  local lines = { "/* DO NOT EDIT THIS FILE - it is machine generated */", "#include <jni.h>", "x" }
  eq(generated.generated("foo_jni.h", lines), true)
  eq(
    generated.generated(
      "foo_jni.h",
      { "/* DO NOT EDIT THIS FILE - it is machine generated */", "x", "y" }
    ),
    false,
    "second line must also match"
  )
end

T["content rule: minified JS/CSS (average line length > 110 over the whole content)"] = function()
  -- generated.rb's own `lines` includes a trailing phantom "" (see the module's own doc
  -- comment on `ruby_lines`), so a SINGLE long content line divides by 2, not 1.
  eq(
    generated.generated("bundle.js", { string.rep("x", 100) }),
    false,
    "single 100-char line averages under 110 with the phantom trailing line"
  )
  eq(generated.generated("bundle.js", { string.rep("x", 300) }), true)
  eq(generated.generated("bundle.css", { string.rep("x", 300) }), true, "css counted too")
  eq(
    generated.generated("bundle.ts", { string.rep("x", 300) }),
    false,
    "extension not in the minified set"
  )
  eq(generated.generated("bundle.js", { "short", "lines", "here" }), false)
end

T["content rule: source-map reference in the last 2 lines (js/css only)"] = function()
  eq(generated.generated("bundle.js", { "code();", "//# sourceMappingURL=bundle.js.map" }), true)
  eq(
    generated.generated("bundle.js", { "//# sourceMappingURL=bundle.js.map", "code();", "x" }),
    false,
    "reference must be in the LAST 2 lines"
  )
  eq(generated.generated("bundle.js", { "code();", "nothing here" }), false)
  eq(
    generated.generated("bundle.txt", { "//# sourceMappingURL=bundle.js.map" }),
    false,
    "only js/css are checked"
  )
end

T["content rule: .map files (name convention or content)"] = function()
  eq(generated.generated("bundle.js.map", {}), true, "name convention: .js.map")
  eq(generated.generated("bundle.css.map", {}), true, "name convention: .css.map")
  eq(
    generated.generated("bundle.foo.map", { '{"version":3,"sources":[]}' }),
    true,
    "content: version header"
  )
  eq(
    generated.generated("bundle.foo.map", { "/** Begin line maps. **/{" }),
    true,
    "content: revision-1 magic comment"
  )
  eq(generated.generated("bundle.foo.map", { "not a source map" }), false)
  eq(
    generated.generated("bundle.txt", { '{"version":3,"sources":[]}' }),
    false,
    "only .map files are checked"
  )
end

T["content rule: compiled CoffeeScript"] = function()
  eq(
    generated.generated("foo.js", { "// Generated by CoffeeScript 1.9.2" }),
    true,
    "compiler comment on line 1"
  )
  -- `M.generated`'s own `lines` arrives WITHOUT the trailing phantom "" Ruby's
  -- `data.split("\n", -1)` adds for a normally-terminated file (see generated.lua's own
  -- doc comment on `ruby_lines`) -- omitting a trailing blank element here is what makes
  -- "}).call(this);" line up with Ruby's `lines[-2]` once that phantom is re-added.
  local module_closure = {
    "(function() {",
    "  var __bind = 1, __extends = 2, __hasProp = 3;",
    "}).call(this);",
  }
  eq(generated.generated("foo.js", module_closure), true, "module-closure heuristic scores >= 3")
  eq(
    generated.generated("foo.js", { "(function() {", "  var x = 1;", "}).call(this);", "" }),
    false,
    "score too low"
  )
  eq(generated.generated("foo.js", { "plain code" }), false)
end

T["content rule: PEG.js parser marker"] = function()
  eq(
    generated.generated("parser.js", { "/*", " * Generated by PEG.js 0.10.0.", " */", "code" }),
    true
  )
  eq(generated.generated("parser.js", { "hand written" }), false)
end

T["content rule: .NET docfile"] = function()
  local lines = { '<?xml version="1.0"?>', "<doc>", "<assembly>", "x", "</doc>" }
  eq(generated.generated("foo.xml", lines), true)
  eq(
    generated.generated("foo.xml", { "<?xml?>", "<doc>", "x", "</doc>" }),
    false,
    "missing <assembly>"
  )
end

T["content rule: PostScript (eexec/sfnts stream, or a Creator comment)"] = function()
  eq(generated.generated("font.pfa", { "currentfile eexec  garbage" }), true, "eexec stream marker")
  eq(
    generated.generated("font.eps", { "%%Creator: Adobe Illustrator(R) 23.0" }),
    true,
    "creator with a digit"
  )
  eq(
    generated.generated("font.eps", { "%%Creator: inkscape 0.92" }),
    true,
    "creator matches inkscape"
  )
  eq(
    generated.generated("font.eps", { "%%Creator: A Human Person" }),
    false,
    "creator has no recognized marker"
  )
  eq(generated.generated("font.eps", { "no creator comment at all" }), false)
end

T["content rule: compiled Cython"] = function()
  eq(generated.generated("foo.c", { "/* Generated by Cython 0.29.21 */", "x" }), true)
  eq(generated.generated("foo.cpp", { "/* Generated by Cython 0.29.21 */", "x" }), true)
  eq(generated.generated("foo.c", { "hand written", "x" }), false)
end

T["content rule: VCR cassette (recorded_with: VCR on the second-to-last line)"] = function()
  eq(generated.generated("cassette.yml", { "a", "b", "recorded_with: VCR" }), true)
  eq(
    generated.generated("cassette.yml", { "recorded_with: VCR", "a", "b" }),
    false,
    "must be second-to-last"
  )
end

T["content rule: ANTLR (Xtest marker on the 2nd line)"] = function()
  eq(generated.generated("Foo.g", { "grammar Foo;", "// generated by Xtest", "x" }), true)
  eq(generated.generated("Foo.g", { "// generated by Xtest", "grammar Foo;", "x" }), false)
end

T["content rule: KiCAD / GFortran .mod"] = function()
  eq(generated.generated("foo.mod", { "PCBNEW-LibModule-V1  2020-01-01", "x" }), true)
  eq(
    generated.generated("foo.mod", { "GFORTRAN module version '14' created from foo.f90", "x" }),
    true
  )
  eq(generated.generated("foo.mod", { "hand written", "x" }), false)
end

T["content rule: Unity3D .meta"] = function()
  eq(generated.generated("foo.meta", { "fileFormatVersion: 2", "guid: abc" }), true)
  eq(generated.generated("foo.meta", { "hand written", "guid: abc" }), false)
end

T["content rule: Racc (marker on the 3rd line)"] = function()
  eq(
    generated.generated(
      "parser.rb",
      { "a", "b", "# This file is automatically generated by Racc 1.5.2" }
    ),
    true
  )
  eq(
    generated.generated(
      "parser.rb",
      { "# This file is automatically generated by Racc 1.5.2", "a", "b" }
    ),
    false
  )
end

T["content rule: JFlex (marker on the 1st line)"] = function()
  eq(
    generated.generated(
      "Lexer.java",
      { "/* The following code was generated by JFlex 1.7.0 on 1/1/20 */", "x" }
    ),
    true
  )
  eq(generated.generated("Lexer.java", { "hand written", "x" }), false)
end

T["content rule: GrammarKit (marker on the 1st line)"] = function()
  eq(
    generated.generated(
      "Parser.java",
      { "// This is a generated file. Not intended for manual editing.", "x" }
    ),
    true
  )
  eq(generated.generated("Parser.java", { "hand written", "x" }), false)
end

T["content rule: roxygen2 (.Rd, marker on the 1st line)"] = function()
  eq(generated.generated("foo.Rd", { "% Generated by roxygen2: do not edit by hand", "x" }), true)
  eq(generated.generated("foo.Rd", { "hand written", "x" }), false)
end

T["content rule: Jison (parser or lexer marker on the 1st line)"] = function()
  eq(generated.generated("parser.js", { "/* parser generated by jison 0.4.18 */", "x" }), true)
  eq(generated.generated("lexer.js", { "/* generated by jison-lex 0.3.4 */", "x" }), true)
  eq(generated.generated("parser.js", { "hand written", "x" }), false)
end

T["content rule: Dart codegen (case-insensitive, first 3 lines)"] = function()
  eq(
    generated.generated("foo.dart", { "// Generated code. Do not modify.", "x" }),
    true,
    "protoc-plugin style, period"
  )
  eq(
    generated.generated("foo.dart", { "// GENERATED CODE - DO NOT MODIFY", "x" }),
    true,
    "source_gen style, dash"
  )
  eq(generated.generated("foo.dart", { "hand written", "x" }), false)
end

T["content rule: Perl ppport.h (marker on line 9, needs > 10 lines)"] = function()
  local lines = {}
  for i = 1, 8 do
    lines[i] = "line " .. i
  end
  lines[9] = "Automatically created by Devel::PPPort 3.36"
  for i = 10, 11 do
    lines[i] = "line " .. i
  end
  eq(generated.generated("ppport.h", lines), true)
  eq(generated.generated("other.h", lines), false, "filename must end in ppport.h")
end

T["content rule: GameMaker Studio .yy/.yyp"] = function()
  eq(
    generated.generated("room.yy", { "{", '"foo": 1,', "}", "x" }),
    true,
    "starts with brace after joining first 3 lines"
  )
  eq(
    generated.generated("room.yyp", { "1.0.0.400|{", "x", "y", "z" }),
    true,
    "version-prefixed form"
  )
  eq(generated.generated("room.yy", { "not json", "at all", "here", "x" }), false)
end

T["content rule: GIMP C/H source dump"] = function()
  eq(generated.generated("image.c", { "/* GIMP RGB C-Source image dump (image.c) */" }), true)
  eq(
    generated.generated("image.h", { "/*  GIMP header image file format (RGB): image.h  */" }),
    true
  )
  eq(generated.generated("image.c", { "hand written" }), false)
end

T["content rule: Visual Studio 6 .dsp"] = function()
  eq(generated.generated("foo.dsp", { "# Microsoft Developer Studio Generated Build File" }), true)
  eq(generated.generated("foo.dsp", { "hand written" }), false)
end

T["content rule: Haxe (first 3 lines)"] = function()
  eq(generated.generated("foo.cs", { "x", "// Generated by Haxe 4.0.0", "y" }), true)
  eq(generated.generated("foo.cs", { "hand written" }), false)
end

T["content rule: HTML meta-generator (pkgdown, mandoc, doxygen, generic <meta generator>)"] = function()
  eq(
    generated.generated("index.html", { "<!-- Generated by pkgdown: do not edit by hand -->", "x" }),
    true,
    "pkgdown"
  )
  eq(
    generated.generated(
      "manual.html",
      { "a", "b", "<!-- This is an automatically generated file.", "x" }
    ),
    true,
    "mandoc"
  )
  local doxygen_lines = {}
  for i = 1, 5 do
    doxygen_lines[i] = "x"
  end
  doxygen_lines[6] = "<!-- Generated by Doxygen 1.9.1 -->"
  eq(generated.generated("index.html", doxygen_lines), true, "doxygen")
  eq(
    generated.generated("index.html", { '<meta name="generator" content="org mode">', "x" }),
    true,
    "generic meta generator (org mode)"
  )
  eq(
    generated.generated("index.html", { '<meta name="description" content="hi">', "x" }),
    false,
    "unrelated meta tag"
  )
  eq(generated.generated("index.html", { "hand written", "x" }), false)
end

T["content rule: jOOQ (.java, first 2 lines)"] = function()
  eq(generated.generated("Tables.java", { "x", "This file is generated by jOOQ." }), true)
  eq(generated.generated("Tables.java", { "hand written" }), false)
end

T["content rule: Sorbet RBI (typed sigil + DO NOT EDIT MANUALLY + tapioca instructions)"] = function()
  local lines = {
    "# typed: true",
    "",
    "# DO NOT EDIT MANUALLY",
    "",
    "# Please run `bin/tapioca gem`",
  }
  eq(generated.generated("foo.rbi", lines), true)
  local alt = {
    "# typed: true",
    "",
    "# DO NOT EDIT MANUALLY",
    "",
    "# Please instead update this file by running `bin/tapioca dsl`",
  }
  eq(generated.generated("foo.rbi", alt), true, "alternate tapioca instruction wording")
  eq(generated.generated("foo.rbi", { "# typed: true", "", "hand written", "", "x" }), false)
end

T["content rule: MySQL view definition format (.frm)"] = function()
  eq(generated.generated("view.frm", { "TYPE=VIEW", "x" }), true)
  eq(generated.generated("view.frm", { "hand written" }), false)
end

-- 3. .gitattributes overrides are NOT this module's job ----------------------------------
-- (git.check_attrs / ui/guard.lua's M.is_generated own that layer -- see
-- tests/test_git.lua and tests/test_sidebyside.lua/tests/test_unified.lua.)

return T
