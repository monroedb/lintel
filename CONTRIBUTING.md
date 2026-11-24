# Contributing to Lintel

Thanks for helping. Lintel is a small project, so focused changes are easiest to take.

**Issues.** Use the bug or feature template. For a bug, say which macOS version and Mac you use,
your displays (notch or not), what you did, what you expected and what happened. Logs help:
`log show --last 10m --info --predicate 'subsystem == "com.sashagilliard.lintel"'`. Read them for
anything personal before you paste them.

**Pull requests.** One change per pull request, described in plain words. Before you open one:

- `swift build` and `swift run lintel-checks` pass. CI runs both, and builds the app.
- `./scripts/build-app.sh` builds the app. It needs CMake for the bundled media adapter
  (`brew install cmake`).
- New logic goes in `Sources/LintelCore` (no UI), with checks in `Sources/LintelChecks`. AppKit
  and SwiftUI code goes in `Sources/Lintel`.
- Keep it quiet when nothing happens. No polling while idle, nothing that only matters on screen
  while the island is hidden, the displays sleep or the Mac is locked.

**Private APIs.** Lintel uses a few private or undocumented macOS interfaces. Each one is looked up
at run time, can be switched off in Settings, and has a public fallback. New ones need the same.

**Privacy.** No analytics, tracking or new network services. Discuss anything that would send data
off the Mac in an issue first.

By contributing, you agree that your contribution is licensed under the MIT License (see
`LICENSE`).
