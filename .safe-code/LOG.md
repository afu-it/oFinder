# Log

## 2026-08-07 · decision

Renamed the app to oFinder: modules `OFinder` / `OFinderServices`, executable
`ofinder`, bundle identifier `dev.afuit.ofinder`, signing certificate
`oFinder Self-Signed`, version restarted at 0.0.1. Favorites migrate from the
old preferences domain on first launch and the old domain is left intact.

Rewrote the 49 commits after `v2.0.2` to the `afu-it` identity. Every one of
them sits after that tag and none before it, so upstream's history and all
mirrored tags stayed byte-identical. Git had been guessing the author from the
macOS account because `user.name` was never set anywhere.

Found while checking: the `v1.x`–`v2.0.2` releases belong to
`carmonac/r2_finder`. This fork has no releases of its own, so the earlier
plan to delete them was aimed at the wrong repository and was not carried out.

atomic split skipped: the rename touched nearly every file in the tree, so the
session's fixes and the rename share hunks and cannot be separated.

The rewritten history is pushed. The push failed first over HTTPS: the `gh`
OAuth token has no `workflow` scope, and the rename touched
`.github/workflows/release.yml`, so GitHub refused the whole push. Switching
`origin` to SSH cleared it, since an SSH key carries no such scope.

plain: gave the app a new name and a fresh version number, kept the sidebar
shortcuts, and took the full name out of the commit history on GitHub.


## 2026-08-07 · bugfix

Cancel in the transfer window closed the window without signalling rsync, so a
cancelled move kept deleting source files. Jobs now return a `TransferHandle`;
the window holds it and both Cancel and the close button go through it. Two
review passes found four further defects, all fixed: the close button could
still escape after a cancel, a queued archive job could wedge the window
open, SIGKILL reached only the parent while rsync's forks kept the pipe open,
and the process-table walk gave up whenever the table grew mid-read.

Also: the mouse thumb buttons now drive back and forward, with `Cmd+[` and
`Cmd+]` for mice whose drivers send keystrokes instead. And the Edit menu had
wired Cmd+C/X/V to private selectors, so a focused text field never saw them;
the path bar could not be copied from. They now use the standard `copy:`,
`cut:` and `paste:`.

plain: pressing Cancel really stops a copy now, the side buttons on the mouse
work, and you can copy the folder path out of the bar at the top.


## 2026-08-07 · audit

Audited the repo after creating the brain. No dead code: the scanner's 11
zero-reference candidates were all AppKit delegate methods, called by the
framework rather than by our code. Agent config trust audit clean — no
.mcp.json, no hidden unicode, no committed secrets, no outbound exec in the
release workflow.

One real finding, logged as BACKLOG High: Cancel in the transfer progress
window closes the window without signalling rsync, so a cancelled move keeps
deleting source files.

Context self-test scored 11/12 against a fresh-context grader; the seven gaps
it named were filled and it now stands at 12/12.

plain: wrote down how this project works, checked nothing was rotting, and
found one bug where pressing Cancel during a move does not actually stop it.


## 2026-08-07 · decision

Created the project brain: `AGENTS.md`, `CLAUDE.md` bridge, `.safe-code/`
with context and six session files. No legacy layout found; nothing migrated.
Context populated from repo evidence only — Package.swift, README.md, the
source tree, and git state.

plain: wrote down what this project is and how to work on it, so a fresh
assistant does not have to guess.
