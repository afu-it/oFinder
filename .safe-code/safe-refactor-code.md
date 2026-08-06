# Safe Refactor

_

## Flagged Candidates

_none — first pass, see the audit below_

## Graveyard

Removals with a way back. Never delete entries from this list.

- 2026-08-07 · Sources/R2Finder/SidebarViewController.swift (network discovery, ~220
  lines) · why: ran a Bonjour browser and a port-445 sweep of up to 254
  addresses per subnet at launch, for a sidebar section nobody used · evidence:
  user request + the scan cost · restore: `git revert 2390d79`
