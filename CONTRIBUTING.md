# Contributing to Loupe

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

## Getting started

Requires macOS 15 and Xcode 16 or later.

```bash
swift test                  # unit tests for the JsonCore engine
./scripts/build-app.sh      # builds build/Loupe.app
open build/Loupe.app
```

## Project layout

| Path | What lives there |
|---|---|
| `Sources/JsonCore` | The engine: buffer, lazy scanner, tree, search. No UI code. |
| `Sources/Loupe` | The AppKit app: window, outline view, rendering, theme. |
| `Sources/loupe-bench` | Generates large test files and times the engine. |
| `Tests/JsonCoreTests` | Unit tests, including a fuzz test for malformed input. |
| `scripts/` | Building, installing, packaging, icon and screenshot tools. |

## Guidelines

- **Keep the engine lazy.** Never parse or copy a whole document. New features should work on
  offsets into the buffer and scan only what they need.
- **Never block the main thread** with work that grows with file size. Use a background queue
  with a `CancelToken` and progress, like loading and search do.
- **Add tests** for engine changes in `Tests/JsonCoreTests`. Run `swift test` before opening a PR.
- **Check performance** for changes to scanning or search:
  `swift build -c release && .build/release/loupe-bench run <file>`.
- Match the existing code style: small types, clear names, comments that explain *why*.

## UI smoke test

The app can drive itself through open → expand → search → zoom and save screenshots:

```bash
LOUPE_SNAPSHOT_DIR=/tmp/shots LOUPE_SNAPSHOT_QUERY=express \
  build/Loupe.app/Contents/MacOS/Loupe "$PWD/examples/orders.json"
```

Set `LOUPE_SNAPSHOT_APPEARANCE=light` or `dark` to force a theme.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Make your change with tests.
3. Make sure `swift test` passes.
4. Open a pull request describing what changed and why. Screenshots help for UI changes.
