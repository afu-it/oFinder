<div align="center">

<img src="docs/assets/logo.png" width="160" alt="oFinder logo">

# oFinder

A macOS file manager with the small things Finder refuses to do.

[![Version](https://img.shields.io/badge/version-0.0.1-blue)](https://github.com/afu-it/oFinder/releases)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](#building-from-source)
[![UI](https://img.shields.io/badge/UI-AppKit-8A2BE2)](#architecture)
[![Transfers](https://img.shields.io/badge/transfers-rsync-2E8B57)](#transfers-go-through-rsync)

**English** · [Bahasa Melayu](README.ms.md)

</div>

---

## Why this exists

Finder has refused to do the same small things for twenty years. You can't cut a file with Cmd+X. You can't select the path in the title bar and copy it. And it forgets how you like things shown: sort order, column layout, window size.

oFinder is a Finder replacement built around exactly those annoyances:

- Cut with Cmd+X, paste to move, the way every other platform does it
- A path bar you can select and copy a path out of
- A display that keeps your choices: sort order, column order and widths, view mode, and window size all persist
- Recents that opens with the newest files on top

## Transfers go through rsync

The transfer engine is inherited from the project this one forked from: every copy and move runs through `/usr/bin/rsync` rather than the Finder copy APIs.

```
rsync -a -P [--ignore-existing] [--remove-source-files] <sources> <destination>/
```

A pleasant side effect is that copies to Samba/NAS shares finish reliably (no error -36, which Finder triggers by pushing macOS metadata many SMB servers reject), interrupted transfers resume instead of starting over, and a move deletes the source only after the destination is fully written.

## Features

**Transfers**
- Copy and move through rsync, with a progress window showing speed and ETA
- Cancel actually cancels: the rsync process and its forks are stopped, not orphaned
- Cut with Cmd+X, copy, and paste, including files copied from Finder; a cut item dims until it is pasted or released
- Drag and drop between windows and to or from other apps

**Browsing**
- Grid, list, and column views; the app remembers which one you last used
- List columns (Name, Date Modified, Type, Size) can be dragged into any order, and the order, widths, and your sort choice all stick
- Recents opens sorted by newest first
- Tabs, split panes, and multiple independent windows
- Sidebar with favorites and mounted volumes, refreshed on mount and unmount
- Back and forward with toolbar buttons, Cmd+[ and Cmd+], or the side buttons on your mouse
- A path bar you can actually copy a path out of

**Files**
- Quick Look preview on Space
- Inline rename, new folder (Cmd+Shift+N), Get Info
- 7z archive creation and extraction
- Show or hide dotfiles
- The interface follows your Mac's system language

## Install

No packaged release yet. oFinder restarted at v0.0.1 under its own name, and a DMG will appear on the [releases page](https://github.com/afu-it/oFinder/releases) once one is built. Until then, build from source below.

The app is not notarized, so macOS quarantines it on first launch. Clear the flag before opening:

```bash
xattr -d com.apple.quarantine /Applications/oFinder.app
```

Some folders (Desktop, Documents, Trash, and others) stay unreadable until you grant the app Full Disk Access in System Settings → Privacy & Security.

## Requirements

- macOS 13 or newer
- Swift 6.0 toolchain (Xcode command line tools) to build from source

## Building from source

```bash
# Run directly (debug; uses the repo's bin/rsync and bin/7zz)
swift run

# Release build
swift build -c release

# Create oFinder.app in .build/ and open it
Scripts/bundle.sh
open ".build/oFinder.app"

# Unit tests (services: listing, transfers, archives, parsers)
swift test
```

The `.app` bundle is self-contained; copy `.build/oFinder.app` anywhere to install. If you plan to grant it Full Disk Access, run `Scripts/make-signing-cert.sh` once first so rebuilds keep a stable signing identity, and install with `Scripts/install.sh` rather than deleting the old bundle.

## Architecture

The app is 100% Swift, migrated from Zig and Objective-C (the story is in `SWIFT_MIGRATION.md`), and builds in Swift 6 language mode with strict concurrency.

| Layer | Responsibility |
|-------|----------------|
| `Sources/OFinderServices/` | Filesystem services: listing, rsync transfers, delete, mkdir, rename, volumes, 7z archives |
| `Sources/OFinder/` | The app: entry point and AppKit UI (windows, toolbar, sidebar, file views, progress, Quick Look) |

Transfers run on background threads inside the service layer; the UI receives progress callbacks on the main queue and stays responsive during large copies.

## What's different from the original

oFinder began as a fork of [r2_finder](https://github.com/carmonac/r2_finder) by Carlos Carmona, and the rsync-first idea comes from that project. Since the fork it has diverged in these ways:

| | r2_finder | oFinder |
|---|---|---|
| Cancel during a transfer | rsync kept running in the background | Stops the rsync process and its forks |
| Back / forward | Toolbar buttons | Also Cmd+[ / Cmd+] and the side buttons on a mouse |
| Path bar | Display only | The path can be selected and copied |
| Sorting | Reset on every visit | Your choice persists; Recents opens newest first |
| Columns | Fixed order: Name, Size, Date, Kind | Name, Date Modified, Type, Size; drag to reorder, order and widths saved |
| Window | Opened at the minimum width each launch | Opens wide enough for every column, then remembers your size |
| View mode | List on every launch | Grid by default, last-used view remembered |
| App identity | `com.example.r2finder`, ad-hoc signature | `dev.afuit.ofinder` with a stable signing certificate, so Full Disk Access survives rebuilds |

## Credits

Thanks to Carlos Carmona for r2_finder, the project this one grew out of.
