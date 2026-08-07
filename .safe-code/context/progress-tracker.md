# Progress Tracker

last_synced_commit: ed7bbeab1fac7402ddb8e5825e9a3bf58d6da75f
context_synced_at: 2026-08-07
context_selftest: 12/12 (2026-08-07, after gap fill; 11/12 before)

## Current Phase

The fork has become its own project: renamed oFinder, bundle identifier
`dev.afuit.ofinder`, version restarted at 0.0.1.
[extracted: Scripts/bundle.sh, git log]

## Current Goal

None outstanding.

## Next Up

Full Disk Access has to be granted again, because the bundle identifier and
the signing certificate both changed. See `.safe-code/BACKLOG.md`.

## Decisions

- Renamed to oFinder rather than a name without "Finder" in it. The earlier
  trademark worry was overstated: Path Finder, TotalFinder and XtraFinder have
  all shipped for years. "oFinder" is also a distinct search term in a way
  "Open Finder" would not have been. (2026-08-07)
- The bundle identifier and the signing certificate changed in the same
  build. Either alone resets TCC, so doing both at once costs one Full Disk
  Access re-grant instead of two. (2026-08-07)
- Favorites migrate from the old preferences domain, and only when the new
  domain is empty. A migration that could overwrite would resurrect a layout
  the user had already changed. The old domain is kept, not deleted.
  (2026-08-07)
- History rewritten for the 49 commits after `v2.0.2` only. Every commit
  carrying the personal name is in that range, so upstream's commits and every
  mirrored tag stayed untouched. (2026-08-07)
- The mirrored `v1.x`–`v2.0.2` tags were left alone. They belong to
  `carmonac/r2_finder`; this fork has no releases of its own, so deleting them
  would have been aimed at the wrong repository. (2026-08-07)
- A cancelled job reports failure with a nil message rather than the
  completion handler gaining a third case. The window that requested the
  cancel already knows what it asked for. (2026-08-07)
- The cancel path walks the process table through `sysctl` rather than
  signalling a process group. Foundation's `Process` cannot place a child in
  its own group, and signalling this app's group would kill the app.
  (2026-08-07)

- English base with Spanish kept as a translation, rather than switching the
  app to English outright — the upstream author is Spanish-speaking. (2026-08-07)
- Trash restore reads `~/.Trash/.DS_Store` directly. Finder's scripting
  dictionary has no put-back command and the file carries no origin attribute,
  so there is no supported route. (2026-08-07)
- Emptying the Trash asks Finder over AppleScript rather than deleting: Finder
  already holds the permissions and handles locked items and per-volume
  `.Trashes`. (2026-08-07)
- Network discovery removed entirely. It ran a Bonjour browser and a port-445
  sweep of up to 254 addresses per subnet at every launch. (2026-08-07)

## Open Questions

- Does the app behave correctly on a machine **without** Full Disk Access? The
  paths that need it now explain themselves, but this has only been exercised
  on a machine where the grant exists.
- `swift test` has never been run — no Xcode on this machine. The XCTest files
  are written but unexecuted; correctness was established by compiling the same
  sources standalone.
- Is `docs/` (a GitHub Pages site) still current after this fork's changes?

_The stamp is written before the save commits exist, so it always trails them
by one commit. That is expected — it means "context was checked against this
point", not "context includes this commit"._
