.PHONY: install build copy

build:
	zig build --release=small

copy:
	cp zig-out/bin/gh-notify ~/.local/bin/gh-notify

install: build copy
	@echo "gh-notify is available in ~/.local/bin/gh-notify!"

