# README demo recording for the agent bridge (bin/diffly). Regenerate with: make demo
# (needs vhs from aqua.yaml plus ttyd and ffmpeg via brew). Same setup as demo.tape: the
# USER'S real Neovim config (no --clean) with the local diffly checkout injected on top
# (scripts/demo_attach.lua), against the same throwaway Go repo (scripts/demo_repo.sh).
# Narration inside Neovim: typed Ex comments (`" ...`), held, then Escaped -- never run.
# Narration at the shell: plain `# ...` comment lines.
#
# Why Ctrl-Z works mid-scene: on Neovim 0.11+ the core runs as a separate `nvim --embed`
# server process -- Ctrl-Z stops only the TUI client, while the server (which owns the
# diffly session AND its RPC socket) keeps running. bin/diffly therefore answers
# synchronously against a suspended editor, and `fg` redraws with the comments already
# in place.
Output assets/demo_agent.gif

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

# Open the review and land on parser.go's diff.
Type ":"
Sleep 300ms
Type@30ms `" :Diffly -- reviewing a branch; now let an agent look at it too`
Sleep 2.2s
Escape
Sleep 400ms
Type ":Diffly"
Sleep 500ms
Enter
Sleep 2.5s
Type "]f"
Sleep 2s

# Suspend the editor; the review session keeps serving in the background.
Type ":"
Sleep 300ms
Type@30ms `" <C-z> -- suspend Neovim; the review session keeps running`
Sleep 2.2s
Escape
Sleep 400ms
Ctrl+Z
Sleep 1.5s

# The agent's turn: bin/diffly discovers the suspended editor's session over RPC and
# writes straight into it -- the JSON responses are the agent's view of the review.
Type `# an agent comments through bin/diffly -- no GitHub, no copy-paste`
Enter
Sleep 1.8s
Type `"$ROOT"/bin/diffly comments add --file parser.go --line 7 --body 'preallocate: make([]Token, 0, n)'`
Enter
Sleep 2.5s
Type `"$ROOT"/bin/diffly comments add --file token.go --line 11 --end-line 15 --body 'unicode digits slip through classify -- unicode.IsDigit?'`
Enter
Sleep 2.5s

# Wake the editor: the agent's notes are already in place, attributed @agent.
Type "fg"
Enter
Sleep 3.5s

# Both notes, listed: :Diffly comments tags agent entries [@agent].
Type ":"
Sleep 300ms
Type@30ms `" :Diffly comments -- every note in one list, agent entries tagged [@agent]`
Sleep 2.2s
Escape
Sleep 400ms
Type ":Diffly comments"
Sleep 500ms
Enter
Sleep 3s

# Close: quickfix, then the review from the panel.
Type ":cclose"
Enter
Sleep 1s
Type " e"
Sleep 1s
Type "q"
Sleep 1.5s
