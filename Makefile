.PHONY: test test-chat format

test:
	nvim --headless -u NONE -l tests/run.lua

test-chat:
	nvim --headless -u NONE -l tests/chat.lua

format:
	stylua lua tests examples
