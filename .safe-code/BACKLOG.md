# Backlog

_

## High

- **Cancel does not stop rsync.** `ProgressWindowController.swift:149` closes
  the progress window without signalling the child process, so a cancelled copy
  or move runs to completion unseen — and for a move, `--remove-source-files`
  keeps deleting sources after the user thought they stopped it.
  [extracted: Sources/R2Finder/ProgressWindowController.swift:149]

## Medium

- Run `swift test` on a machine with Xcode. Ten test files exist and have
  never been executed; correctness was established by compiling the same
  sources standalone.

## Low

- Check whether `docs/` (the GitHub Pages site) still matches this fork.
- README still points downloads at `carmonac/r2_finder` releases, which do not
  include this fork's work.
