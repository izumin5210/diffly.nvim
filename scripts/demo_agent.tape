# README demo recording for the agent bridge (bin/diffly + the diffly-review skill).
# Regenerate with: make demo (needs vhs from aqua.yaml plus ttyd and ffmpeg via brew,
# AND a logged-in `claude` CLI -- this recording runs a real Claude Code session on
# --model sonnet --effort low). Same setup as demo.tape otherwise: the USER'S real
# Neovim config with the local diffly checkout injected on top (scripts/demo_attach.lua)
# against the throwaway Go repo (scripts/demo_repo.sh).
# Narration inside Neovim: typed Ex comments (`" ...`), held, then Escaped -- never run.
# Narration at the shell: plain `# ...` comment lines.
#
# Why Ctrl-Z works mid-scene: on Neovim 0.11+ the core runs as a separate `nvim --embed`
# server process -- Ctrl-Z stops only the TUI client, while the server (which owns the
# diffly session AND its RPC socket) keeps running. Claude Code's bin/diffly calls land
# in the suspended editor's session, and `fg` redraws with the comments already there.
#
# Recording-stability notes: the demo repo is a fresh temp dir, so Claude Code shows its
# folder-trust dialog -- the tape answers it with a blind Enter (a no-op if the dialog
# doesn't appear). The agent's working time is nondeterministic: the tape shows the
# session start, Hides through the long middle, and Shows the finished state -- the
# hidden Sleep is sized generously; if a recording captures a still-running session,
# extend it and re-record. Claude Code runs with IS_DEMO=1 (exported in the hidden
# setup) to keep account details out of the frame, and only Bash/Read/Grep/Glob are
# pre-allowed via the repo's settings.local.json so no permission prompt can stall the
# recording.
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

# Build the throwaway demo repo off-screen; keep the plugin root reachable, pre-allow
# Claude Code's read-only tools + Bash, and keep account details out of the frame.
Hide
Type `export ROOT="$PWD" && cd "$(scripts/demo_repo.sh)" && export IS_DEMO=1 && clear`
Enter
Sleep 1s
Type `mkdir -p .claude && printf '%s' '{"permissions":{"allow":["Bash","Read","Grep","Glob"]}}' > .claude/settings.local.json && clear`
Enter
Sleep 500ms
Type `nvim "+lua dofile('$ROOT/scripts/demo_attach.lua')"`
Enter
Sleep 4s
Show

# Open the review and land on parser.go's diff.
Type ":"
Sleep 300ms
Type@30ms `" :Diffly -- reviewing a branch; let's have Claude Code look at it too`
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

# One-time setup: install the diffly-review skill (absolute bin path baked in).
Type `# one-time setup: install the diffly-review skill for Claude Code`
Enter
Sleep 1.5s
Type `"$ROOT"/bin/diffly skill install --dir .claude/skills`
Enter
Sleep 2s

# Hand the review to Claude Code.
Type `claude --model sonnet --effort low "Review this branch and leave your findings as diffly review comments. Comments only -- do not modify files."`
Enter
Sleep 5s
# Folder-trust dialog on the fresh temp dir (no-op Enter if absent).
Enter
Sleep 12s

# The long middle: skip ahead to the finished session.
Hide
Sleep 150s
Show
Sleep 6s
Type "/exit"
Sleep 1s
Enter
Sleep 2s

# Wake the editor: Claude's notes are already in place, attributed in the diff.
Type "fg"
Enter
Sleep 4s

# Every note in one list, agent entries tagged.
Type ":"
Sleep 300ms
Type@30ms `" :Diffly comments -- Claude's notes, in your review, no GitHub round-trip`
Sleep 2.2s
Escape
Sleep 400ms
Type ":Diffly comments"
Sleep 500ms
Enter
Sleep 3.5s

# Close: quickfix, then the review from the panel.
Type ":cclose"
Enter
Sleep 1s
Type " e"
Sleep 1s
Type "q"
Sleep 1.5s
