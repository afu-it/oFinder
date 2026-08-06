# AI Workflow Rules

## Verify, do not assume

This repo has burned several plausible assumptions. Check before building on
one:

- Running the app binary from a terminal reports the **terminal's** TCC access,
  not the app's. Launch through LaunchServices.
- `open --env` does not pass environment variables to the app.
- `exit()` skips `defer`, so a report written from a defer is never written.
- Spotlight caches per query shape: the first run of a predicate costs ~1.1s and
  later ones ~0.12s. A *different* warm-up query does not help.

When a measurement contradicts the obvious explanation, trust the measurement
and say so.

## Verification without a test runner

`swift test` cannot run on a Command Line Tools machine. For pure logic, compile
the source file together with a throwaway `main.swift` in a scratch directory
and run it. Then write the XCTest file anyway, so it runs wherever Xcode exists.

## Scope

- One concern per change. Build, install, and check before moving on.
- Quit the app before installing; a running app holds its executable and the old
  code keeps running. `Scripts/install.sh` does this for you.
- After installing, confirm it actually runs before claiming anything works:
  `open -a "R2 Finder"`, then check the process exists
  (`ps ax | grep [r]s_2finder`). To catch Auto Layout complaints and runtime
  errors, run the bundled binary once with stderr captured — accepting that TCC
  answers for the terminal in that mode, so it is a crash check, not a
  permissions check.
- Never push. Commits are local unless the user asks.

## Destructive operations

Confirm first, and prefer a way back. Moves are undoable through `MoveUndo`;
deletions are not, so they ask.
