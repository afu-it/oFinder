# Code Standards

Derived from the existing source, not imposed on it. [extracted: Sources/]

## Comments

Comments explain **why**, never what. The bar this repo actually holds: a
comment earns its place by recording a decision, a constraint, or a trap that
the code cannot state itself. Examples in the tree:

- why rsync rather than FileManager
- why the tab strip is hand-built rather than `NSTabView`
- why `ptbN` is not redundant with the Trash entry's filename

Do not narrate. `// increment the counter` would be deleted in review.

## Naming

- Types: `UpperCamelCase`; a view controller is `…ViewController`, a view is
  `…View`, a service is `…Service`.
- Localization keys are dotted and grouped by area: `action.`, `menu.`,
  `sidebar.`, `toolbar.`, `column.`, `progress.`, `button.`, `trash.`.

## Layout

- 4-space indent, roughly 88-column wrap.
- `// MARK: –` section headers inside long files.
- File header: filename, then one line on what the file is for.

## Concurrency

- UI types are `@MainActor`. Background work uses explicit queues
  (`loadQueue`, `DispatchQueue.global`) and hops back with `Task { @MainActor }`.
- `nonisolated(unsafe)` appears only where a value is written on the main actor
  and read as an advisory hint elsewhere; each use carries a comment saying so.

## Errors

Never fail silently. A refused directory, a missing binary, or a failed restore
produces a message that names the cause. Alerts confirm before anything
destructive, and destructive buttons set `hasDestructiveAction`.

## Tests

Pure logic lives in `R2FinderServices` and gets XCTest coverage. Tests name the
behaviour, not the method: `testPushingFromTheMiddleDropsTheForwardBranch`, not
`testPush`.
