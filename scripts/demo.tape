# README demo recording. Regenerate with: make demo (needs vhs from aqua.yaml plus ttyd
# and ffmpeg via brew). Records the USER'S real Neovim config (no --clean) with the local
# difit checkout injected on top (scripts/demo_attach.lua), against a throwaway Go repo
# (scripts/demo_repo.sh) so gopls attaches and LSP hover works inside the diff views.
# NOTE: assumes mapleader = <Space> (this machine's config); adjust the leader keys below
# if yours differs.
Output assets/demo.gif

# A Nerd Font installed on this machine -- vhs's bundled JetBrains Mono has no nerd
# glyphs, so file icons render as tofu without this.
Set FontFamily "HackGen35 Console NF"
Set FontSize 14
Set Width 1400
Set Height 820
Set Padding 10
Set TypingSpeed 55ms

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
Type ":Difit"
Sleep 500ms
Enter
Sleep 3s

# Walk to parser.go with the universal ]f navigation.
Type "]f"
Sleep 2s

# Switch to the unified inline-overlay view (<leader>s): added lines highlighted in
# place, deleted lines as virtual lines -- and still the real buffer, so gopls is
# attached: park the cursor on strings.Fields and show the LSP hover card.
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
Type " v"
Sleep 1.5s
Type " v"
Sleep 1.5s

# Sweep the generated-files pattern group, then close from the panel.
Type ":Difit sweep generated"
Sleep 500ms
Enter
Sleep 2s
Type " e"
Sleep 1.5s
Type "q"
Sleep 1s
