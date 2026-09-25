# agentz has two parts:
#   core/    the Rust core (sessions, processes, rate limits, saved tabs,
#            busy tracking) and its bridge to Swift
#   macos/   the macOS app, in Swift (see macos/Makefile)
# These targets cover both.

.PHONY: all install uninstall test check fmt smoke clean

all:
	$(MAKE) -C macos app

# Copies the app to ~/Applications/Agentz.app.
install:
	$(MAKE) -C macos install

uninstall:
	$(MAKE) -C macos uninstall

# Unit tests: the Rust core, then the macOS app.
test:
	cd core && cargo test
	$(MAKE) -C macos test

check:
	cd core && cargo fmt --check
	cd core && cargo clippy --release --all-targets -- -D warnings

fmt:
	cd core && cargo fmt

# Opens the macOS app with real terminals for about half a minute.
smoke:
	$(MAKE) -C macos smoke

clean:
	cd core && cargo clean
	$(MAKE) -C macos clean
