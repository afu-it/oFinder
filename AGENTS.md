# AGENTS.md

oFinder — a macOS file manager written in Swift + AppKit. It exists because
Finder's copy path breaks on SMB shares; every transfer here goes through
`rsync` instead.

## Read First

1. `.safe-code/context/project-overview.md` — what this is and who it is for
2. `.safe-code/context/architecture.md` — targets, boundaries, invariants
3. `.safe-code/context/code-standards.md` — conventions this repo actually follows
4. `.safe-code/context/ai-workflow-rules.md` — how to work here safely
5. `.safe-code/context/progress-tracker.md` — phase, current goal, open questions
6. `.safe-code/context/ui-context.md` — only for UI work

Session state lives in `.safe-code/`: `ACTIVE.md` (resume point), `SESSION.md`
(working memory), `LOG.md` (diary), `BACKLOG.md`, `MEMORY.md`,
`safe-refactor-code.md`.

## Build, test, run

Run these in order; each depends on the one before.

```bash
Scripts/make-signing-cert.sh    # once per machine — see below
swift build -c release          # must run OUTSIDE a sandbox — see below
Scripts/bundle.sh 0.0.1 release # <version> <config>; both optional,
                                # default 0.0.0-dev and release
Scripts/install.sh              # no arguments; quits the app, dittos
                                # .build/oFinder.app into /Applications
open -a "oFinder"              # always launch this way, never the binary
```

`install.sh` does not build or bundle — it copies whatever `bundle.sh` last
produced, and errors out if `.build/oFinder.app` is absent.

Launch through `open`, not by running
`.../Contents/MacOS/ofinder` directly: TCC attributes a request to the
responsible process, so a terminal-launched binary reports the terminal's
permissions rather than the app's.

- **SwiftPM invokes `sandbox-exec` itself.** Building inside another sandbox
  fails with `sandbox_apply: Operation not permitted`. Build unsandboxed.
- `swift test` needs XCTest, which ships with full Xcode. A machine with only
  Command Line Tools cannot run the suite; pure logic is verified by compiling
  the source file together with a throwaway `main.swift` instead.

## Two rules that are not obvious

**Never install with `rm -rf` + `cp`.** Deleting the bundle and recreating it
gives it a new identity, and any TCC permission is left pointing at something
that no longer exists — Full Disk Access then reads as granted in System
Settings while the running app has none of it. `Scripts/install.sh` uses
`ditto`, which overwrites contents in place.

**Sign with the stable identity, not ad-hoc.** TCC remembers an app by its code
signature; for an ad-hoc signature that is the binary's own hash, so every
rebuild looks like a different app. `Scripts/make-signing-cert.sh` creates the
certificate once per machine — a fresh clone must run it **before** the first
`bundle.sh`, or every build is ad-hoc signed and Full Disk Access will not
survive. It is safe to re-run: it prints `already present` and exits. To check
by hand: `security find-identity -v -p codesigning`. `bundle.sh` picks the
identity up automatically and reports which one it used.
