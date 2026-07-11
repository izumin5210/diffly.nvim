# README demo recording. Regenerate with: make demo (or: vhs scripts/demo.tape from the
# repo root; needs vhs + ttyd from aqua.yaml and ffmpeg on PATH).
Output assets/demo.gif

Set FontSize 14
Set Width 1400
Set Height 820
Set Padding 10
Set Theme "Catppuccin Mocha"
Set TypingSpeed 55ms

# Build the throwaway demo repo off-screen; keep the plugin root reachable.
Hide
Type `export ROOT="$PWD" && cd "$(scripts/demo_repo.sh)" && clear`
Enter
Sleep 1s
Type `nvim --clean -u "$ROOT/scripts/demo_init.lua"`
Enter
Sleep 2s
Show

# Open the viewer: tree panel + side-by-side diff of feature/tokenizer vs main.
Type ":Difit"
Sleep 500ms
Enter
Sleep 2.5s

# Walk a couple of files with the universal ]f/[f navigation (works in every difit
# window -- the leader keys below do too, so focus never matters in this demo).
Type "]f"
Sleep 1.5s
Type "]f"
Sleep 1.5s

# Mark files viewed (<leader>v) -- auto-advance carries the review to the next
# un-viewed file, and the panel progress/greying follows.
Type `\v`
Sleep 1.5s
Type `\v`
Sleep 1.5s

Screenshot assets/screenshot.png

# Switch to the unified (inline overlay) view and back (<leader>s).
Type `\s`
Sleep 4s
Type `\s`
Sleep 2s

# Sweep a whole pattern group (lock files) in one go via vim.ui.select.
Type ":Difit sweep"
Sleep 500ms
Enter
Sleep 1.5s
Type "2"
Sleep 400ms
Enter
Sleep 2s

# Land in the panel for the closing shot, then quit.
Type `\e`
Sleep 1.5s
Type "q"
Sleep 1s
