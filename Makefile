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
