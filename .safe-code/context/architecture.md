# Architecture

## Stack

Swift 6, AppKit, SwiftPM. No SwiftUI. Minimum macOS 13.
[extracted: Package.swift — `swift-tools-version: 6.0`, `platforms: [.macOS(.v13)]`]

## Targets

| Target | Path | Role |
|---|---|---|
| `rs_2finder` | `Sources/R2Finder` | Executable: AppKit UI. Named to match `CFBundleExecutable`. |
| `R2FinderServices` | `Sources/R2FinderServices` | Library: filesystem, transfers, archives, queries. No AppKit. |
| `R2FinderTests` | `Tests/R2FinderTests` | Depends on `R2FinderServices` only. |

[extracted: Package.swift]

## The boundary that matters

`R2FinderServices` does not import AppKit, and the test target depends only on
it. That is why pure logic gets real tests — `NavigationHistory`, `PathCrumbs`,
`TransferGuard`, `TrashIndex`, `DirectoryLister`, `ProgressParsers` — while
anything needing a window does not. When a piece of logic is worth testing, it
belongs in the service layer. [extracted: Package.swift, Tests/R2FinderTests/]

## Navigation map

**UI (`Sources/R2Finder`)**

- `App.swift` — entry point, main menu, app delegate
- `FinderWindowController.swift` — window, toolbar, owns the panes; holds no
  browsing state of its own
- `PaneViewController.swift` — one pane: a tab strip over a file view.
  `BrowserTab` = a `FileViewController` plus its `NavigationHistory`
- `FileViewController.swift` + `+Views.swift` — the three view modes (outline
  list, icon collection, Miller columns), FSEvents watching, transfers,
  archives, context menus
- `SidebarViewController.swift` — Recents, Favorites, Cloud, Devices, Trash
- `PathBarView.swift` / `PathCrumbs` — breadcrumbs that navigate, or a text
  field to copy from
- `TabBarView.swift`, `TabItemView.swift`, `TabDragVisuals.swift` — tabs and
  the drag-to-split gesture
- `ThumbnailService.swift` — QuickLook thumbnails, on demand
- `FullDiskAccess.swift` — detection, explanation, and the diagnostic probe

**Services (`Sources/R2FinderServices`)**

Every file below is `Sources/R2FinderServices/<Name>.swift`.

- `TransferService` — rsync copy/move; `ArchiveService` — 7zz
- `TransferGuard` — refuses a destination inside its own source
- `DirectoryLister` — returns nil when a directory cannot be opened, which is
  not the same as empty
- `RecentsService` — Spotlight `MDQuery`; `TrashIndex` — reads put-back records
  out of `~/.Trash/.DS_Store`
- `VolumeService`, `CloudService`, `TrashService`, `NavigationHistory`,
  `PathCrumbs`, `Subprocess`, `ProgressParsers`

**Localization** is per target, and each has its own copy — `Bundle.module`
resolves per module, so one shared helper would read the wrong bundle:

```
Sources/R2Finder/Localization.swift          + Resources/{en,es}.lproj/Localizable.strings
Sources/R2FinderServices/Localization.swift  + Resources/{en,es}.lproj/Localizable.strings
```

A UI string goes in the R2Finder pair; a message produced by the service layer
goes in the R2FinderServices pair.

## Bundled binaries

`bin/rsync` and `bin/7zz` are copied into `Contents/Resources` by
`Scripts/bundle.sh` and invoked as subprocesses. [extracted: Scripts/bundle.sh]

## Invariants

- Every copy and move goes through rsync. Do not reach for
  `FileManager.copyItem` for user-initiated transfers — the SMB failures are
  the reason this project exists.
- Anything that reads or writes a location must tolerate being refused. TCC
  protects `~/.Trash` and more; "cannot read" must never render as "empty".
- Localization: user-facing strings go through `L10n.t`/`L10n.f` with the
  English text at the call site as the fallback value. A new key must be added
  to both `en.lproj` and `es.lproj`; a missing key fails silently to English.
- `Scripts/install.sh` overwrites in place with `ditto`. Deleting the bundle
  invalidates TCC grants.
