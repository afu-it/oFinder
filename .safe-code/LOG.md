# Log

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
