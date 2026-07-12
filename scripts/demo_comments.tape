# README demo recording for the local-comments feature. Regenerate with: make demo
# (needs vhs from aqua.yaml plus ttyd and ffmpeg via brew). Same setup as demo.tape: the
# USER'S real Neovim config (no --clean) with the local diffly checkout injected on top
# (scripts/demo_attach.lua), against the same throwaway Go repo (scripts/demo_repo.sh).
# NOTE: assumes mapleader = <Space> (this machine's config); adjust the leader keys below
# if yours differs.
Output assets/demo_comments.gif

Set Theme "Catppuccin Frappe"
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

# Open the viewer and walk to parser.go's real worktree buffer.
Type ":Diffly"
Sleep 500ms
Enter
Sleep 2.5s
Type "]f"
Sleep 2s

# Comment on a single line: land on the tokens declaration (a SHORT line, so the
# collapsed-mode eol indicator below stays on screen), <leader>ca opens the markdown
# compose float in insert mode, <C-s> saves -- the note renders inline below the line and
# the panel row gains a ✎1 count.
Type "/Token{}"
Sleep 500ms
Enter
Sleep 1s
Type " ca"
Sleep 1.5s
Type "prealloc with len(fields)?"
Sleep 800ms
Ctrl+S
Sleep 2.5s

# Comment on a visual RANGE: select the loop, same key.
Type "/classify(field)"
Sleep 500ms
Enter
Sleep 800ms
Type "Vk"
Sleep 800ms
Type " ca"
Sleep 1.5s
Type "extract this loop into a helper"
Sleep 800ms
Ctrl+S
Sleep 2.5s

# <leader>ct collapses every comment to an eol ✎ marker (and back).
Type " ct"
Sleep 2s
Type " ct"
Sleep 2s

# <leader>cY copies every comment as one difit-format AI prompt (unnamed register +
# clipboard) -- ready to paste into a coding agent.
Type " cY"
Sleep 2.5s

# :Diffly comments lists every comment in quickfix.
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
Sleep 1s
