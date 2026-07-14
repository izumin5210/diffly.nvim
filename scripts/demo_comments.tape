# README demo recording for the local-comments feature. Regenerate with: make demo
# (needs vhs from aqua.yaml plus ttyd and ffmpeg via brew). Same setup as demo.tape: the
# USER'S real Neovim config (no --clean) with the local diffly checkout injected on top
# (scripts/demo_attach.lua), against the same throwaway Go repo (scripts/demo_repo.sh).
# Narration: each scene is introduced by typing an Ex comment (`" ...`) into the cmdline
# (rendered centered by this machine's config), held briefly, then cancelled with Escape
# -- never executed, and even an accidental Enter would be a no-op.
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

# Open the viewer and walk to parser.go's real worktree buffer.
Type ":"
Sleep 300ms
Type@30ms `" :Diffly -- open the review; let's leave some comments on it`
Sleep 2.2s
Escape
Sleep 400ms
Type ":Diffly"
Sleep 500ms
Enter
Sleep 2.5s
Type "]f"
Sleep 2s

# Comment on a single line: land on the tokens declaration (a SHORT line, so the
# collapsed-mode eol indicator later stays on screen), <leader>ca opens the markdown
# compose float in insert mode, <C-s> saves -- the note renders inline below the line and
# the panel row gains a ✎1 count.
Type ":"
Sleep 300ms
Type@30ms `" <leader>ca -- comment on the line under the cursor (<C-s> saves)`
Sleep 2.2s
Escape
Sleep 400ms
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

# Comment on a visual RANGE: select the loop, same key. A deliberately LONG body: no
# dedicated scene for it, but it lands visibly soft-wrapped to the split's width
# (comments.wrap) instead of truncated at the window edge.
Type ":"
Sleep 300ms
Type@30ms `" ...or select a range first -- same key from visual mode`
Sleep 2.2s
Escape
Sleep 400ms
Type "/classify(field)"
Sleep 500ms
Enter
Sleep 800ms
Type "Vk"
Sleep 800ms
Type " ca"
Sleep 1.5s
Type "extract this loop into a helper so classify stays testable on its own -- Render is about to grow the same append-in-a-loop shape"
Sleep 800ms
Ctrl+S
Sleep 2.5s

# <leader>ct collapses every comment to an eol ✎ marker (and back).
Type ":"
Sleep 300ms
Type@30ms `" <leader>ct -- collapse the notes to markers when they get in the way`
Sleep 2.2s
Escape
Sleep 400ms
Type " ct"
Sleep 2s
Type " ct"
Sleep 2s

# <leader>cY copies every comment as one difit-format AI prompt (unnamed register +
# clipboard) -- ready to paste into a coding agent.
Type ":"
Sleep 300ms
Type@30ms `" <leader>cY -- copy every note as an AI-agent prompt (difit format)`
Sleep 2.2s
Escape
Sleep 400ms
Type " cY"
Sleep 2.5s

# :Diffly comments lists every comment in quickfix.
Type ":"
Sleep 300ms
Type@30ms `" :Diffly comments -- every note in the review, as a quickfix list`
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
