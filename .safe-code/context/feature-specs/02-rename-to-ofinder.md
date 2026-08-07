---
status: done
created: 2026-08-07
---

# Rename to oFinder, and reset to v0.0.1

## Problem

The project was a fork carrying the upstream name, an `com.example.` bundle
identifier that was never meant to ship, and a version line continuing from
someone else's releases. None of it said whose project this now is.

## Proposal

- Display name `oFinder`, module names `OFinder` / `OFinderServices`,
  executable `ofinder`.
- Bundle identifier `dev.afuit.ofinder`, on a domain the owner holds.
- Signing certificate renamed to `oFinder Self-Signed`.
- Version restarts at `0.0.1`.

The identifier and the certificate both changed in the same build on purpose.
Either one alone resets the app's identity as far as TCC is concerned, so
doing both at once costs a single Full Disk Access re-grant instead of two.

Favorites are filed under the bundle identifier, so they would have vanished.
`FavoritesStore.adoptPreviousFavoritesIfNeeded()` copies the old domain across
on first launch, and only when this app has none of its own, so it can never
overwrite a layout the user has since changed. The old domain is left in place
rather than deleted, so the original is still there if the copy is ever wrong.

## Out of scope

- Renaming the GitHub repository (`afu-it/r2_finder`) and the local checkout
  folder. Both still carry the old name.
- The upstream tags `v1.0.0` through `v2.0.2` mirrored into this fork. They
  belong to `carmonac/r2_finder`, not to this project.

## Verification

- `swift build -c release` from a wiped `.build`, then `Scripts/bundle.sh
  0.0.1 release`, which reported `signed: oFinder Self-Signed` rather than
  falling back to ad-hoc.
- `codesign -d -r-` on the installed bundle reports
  `identifier "dev.afuit.ofinder"`.
- After launching, `defaults read dev.afuit.ofinder` shows both saved keys,
  including the two custom folders and the removed Music entry, and
  `com.example.r2finder` is still intact.
- No occurrence of the old name survives outside `r2_finder` in paths and the
  `previousBundleID` constant the migration needs.
