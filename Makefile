.PHONY: deps test lint fmt

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

# Regenerate the README demo GIF + screenshot. Needs vhs and ttyd (aqua.yaml) plus
# ffmpeg on PATH; records a throwaway repo built by scripts/demo_repo.sh.
demo:
	vhs scripts/demo.tape
