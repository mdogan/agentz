.PHONY: build release run install uninstall check fmt test clean

build:
	cargo build

release:
	cargo build --release

run:
	cargo run --release

install:
	cargo install --path .

uninstall:
	cargo uninstall agentz

check:
	cargo fmt --check
	cargo clippy --release -- -D warnings

fmt:
	cargo fmt

test:
	cargo test

clean:
	cargo clean
