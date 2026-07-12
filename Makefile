.PHONY: deps test lint fmt demo

deps:
	@if [ ! -d deps/mini.nvim ]; then \
		mkdir -p deps && \
		git clone --depth 1 https://github.com/echasnovski/mini.nvim deps/mini.nvim; \
	fi

test:
ifdef FILE
	nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"
else
	nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"
endif

lint:
	stylua --check lua tests

fmt:
	stylua lua tests

# Regenerate the README demo GIFs + screenshot. Needs vhs and ttyd (aqua.yaml) plus
# ffmpeg on PATH; records throwaway repos built by scripts/demo_repo.sh.
demo:
	vhs scripts/demo.tape
	vhs scripts/demo_sweep.tape
	vhs scripts/demo_comments.tape
