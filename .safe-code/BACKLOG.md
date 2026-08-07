# Backlog

_2026-08-07_

## High

- Grant Full Disk Access to oFinder. The bundle identifier and the signing
  certificate both changed, so macOS treats it as a new app and the old grant
  no longer applies. The stale "R2 Finder" entry in System Settings can be
  removed at the same time.

## Medium

- Run `swift test` on a machine with Xcode. Eleven test files exist and have
  never been executed; correctness was established by compiling the same
  sources standalone. `TransferHandleTests` matters most here — it is the only
  coverage of the cancel path, and two of its cases spawn real processes.
- A cancelled compress leaves a half-written archive behind. Deleting it is not
  obviously safe: `7zz a` appends to an existing archive, so a cancel could
  destroy a file that was already there. Decide whether to write to a temporary
  name and rename on success.
  [extracted: Sources/OFinderServices/ArchiveService.swift]

## Low

- Check whether `docs/` (the GitHub Pages site) still matches this fork.
- The README download section still describes a release that does not exist
  yet. It needs rewriting once v0.0.1 is actually published, or removing until
  then.
- The GitHub repo is still `afu-it/r2_finder` and so is the local checkout
  folder. Renaming either is optional; nothing depends on it.
- The upstream tags `v1.0.0`-`v2.0.2` are mirrored into this fork. They point
  at commits from `carmonac/r2_finder` and can be dropped from the fork
  without affecting upstream, or simply left as fork history.
