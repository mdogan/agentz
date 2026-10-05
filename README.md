# agentz

A native macOS app that holds your Claude Code and Codex sessions in one place: a list of sessions, and the selected one running next to it in a [Ghostty](https://ghostty.org) terminal. Resume any session with one click, keep several agents running, and get a notification when one is done. Agents, and shells that run something, keep running when you quit the app: a small background server holds them, and the app shows them again when it opens.

See [macos/README.md](macos/README.md) for how to use it. The Rust core it uses is in `core/`, with the server in `core/src/server/`.

## Build

```sh
make            # build the app: macos/.build/Agentz.app
make install    # copy it to ~/Applications/Agentz.app
make test       # unit tests of everything
make check      # formatting and lints
make smoke      # open the app with real terminals and check it
```

`cd core && cargo test -- --ignored` also starts the real `claude` and `codex` in the server, without a prompt, and checks that they draw their screens again when attached to.
