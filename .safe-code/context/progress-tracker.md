# Progress Tracker

last_synced_commit: ed7bbeab1fac7402ddb8e5825e9a3bf58d6da75f
context_synced_at: 2026-08-07
context_selftest: 12/12 (2026-08-07, after gap fill; 11/12 before)

## Current Phase

Active feature work on a public fork. 93 commits on `main`, worktree clean.
[extracted: git log, git status]

## Current Goal

None outstanding. The project brain was created and verified this session; the
audit found no dead code and no config trust issues, but did surface one real
bug — see BACKLOG High.

## Next Up

Nothing queued. See `.safe-code/BACKLOG.md`.

## Decisions

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
