# README demo recording. Regenerate with: make demo (needs vhs from aqua.yaml plus ttyd
# and ffmpeg via brew). Records the USER'S real Neovim config (no --clean) with the local
# diffly checkout injected on top (scripts/demo_attach.lua), against a throwaway Go repo
# (scripts/demo_repo.sh) so gopls attaches and LSP hover works inside the diff views.
# Narration: each scene is introduced by typing an Ex comment (`" ...`) into the cmdline
# (rendered centered by this machine's config), held briefly, then cancelled with Escape
# -- never executed, and even an accidental Enter would be a no-op.
# NOTE: assumes mapleader = <Space> (this machine's config); adjust the leader keys below
# if yours differs. The sweep feature has its own recording: scripts/demo_sweep.tape.
Output assets/demo.gif

Set Theme "Catppuccin Frappe"
# A Nerd Font installed on this machine -- vhs's bundled JetBrains Mono has no nerd
# glyphs, so file icons render as tofu without this.
Set FontFamily "HackGen35 Console NF"
Set FontSize 14
Set Width 1400
Set Height 820
Set Padding 32
Set LineHeight 1.3
Set TypingSpeed 55ms
Set Margin 24
Set MarginFill "#babbf1"
Set BorderRadius 10

# Build the throwaway demo repo off-screen; keep the plugin root reachable.
Hide
Type `export ROOT="$PWD" && cd "$(scripts/demo_repo.sh)" && clear`
Enter
Sleep 1s
Type `nvim "+lua dofile('$ROOT/scripts/demo_attach.lua')"`
Enter
Sleep 4s
Show

# Open the viewer: tree panel + side-by-side diff of feature/tokenizer vs main.
Type ":"
Sleep 300ms
Type@30ms `" :Diffly -- review the current branch: file tree + side-by-side diff`
Sleep 2.2s
Escape
Sleep 400ms
Type ":Diffly"
Sleep 500ms
Enter
Sleep 3s

# Walk to parser.go with the universal ]f navigation.
Type ":"
Sleep 300ms
Type@30ms `" ]f / [f -- hop between changed files from any diffly window`
Sleep 2.2s
Escape
Sleep 400ms
Type "]f"
Sleep 2s

# Switch to the unified inline-overlay view (<leader>s): added lines highlighted in
# place, deleted lines as virtual lines -- and still the real buffer, so gopls is
# attached: park the cursor on strings.Fields and show the LSP hover card.
Type ":"
Sleep 300ms
Type@30ms `" <leader>s -- unified view; still the real buffer, so LSP hover works`
Sleep 2.2s
Escape
Sleep 400ms
Type " s"
Sleep 3.5s
Type "/Fields("
Sleep 500ms
Enter
Sleep 1s
Type "K"
Sleep 3.5s

Screenshot assets/screenshot.png

# Dismiss the hover, then mark files viewed (<leader>v) -- auto-advance carries the
# review forward and the panel progress follows.
Type "j"
Sleep 1s
Type ":"
Sleep 300ms
Type@30ms `" <leader>v -- mark viewed; auto-advance jumps to the next unviewed file`
Sleep 2.2s
Escape
Sleep 400ms
Type " v"
Sleep 1.5s
Type " v"
Sleep 1.5s

# Close from the panel.
Type " e"
Sleep 1s
Type "q"
Sleep 1.5s
