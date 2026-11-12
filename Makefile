.PHONY: test test-chat format

test:
	nvim --headless -u NONE -l tests/run.lua

test-chat:
	nvim --headless -u NONE -l tests/chat.lua

check:
	stylua --check lua tests examples

format:
	stylua lua tests examples
