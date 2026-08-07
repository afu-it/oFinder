# oFinder — Migration to Swift

Plan to remove Zig and Objective-C from the project and land on a single-language
Swift codebase, without ever leaving `main` in a broken state.

**Guiding rule: the app builds, runs, and ships at every single commit.** Swift and
Objective-C compile into the same target with automatic bidirectional bridging, so
every step below is independently shippable. If the migration stalls halfway, the
app is still fine.

---

## 1. Why

Zig currently provides no capability the platform doesn't already offer. All 1,667
lines of it are either thin POSIX wrappers or subprocess launchers that parse stdout —
nothing compute-bound, nothing that benefits from manual memory control or `comptime`.

What it costs today:

- **FFI tax.** `include/bridge.h` forces manual ownership across the language line
  (`zig_free_dir_listing`), `void *ctx` threading, and hand-rolled
  `dispatch_async(dispatch_get_main_queue(), …)` on every worker-thread callback. A
  meaningful fraction of the Zig code exists only to serve the boundary, not to do work.
- **Stdlib churn.** The code uses `std.Io`, `Dir.openDirAbsolute`, and
  `std.array_list.Managed` — all 0.16-era APIs. Commit `55e7851` was a forced upgrade.
  Pre-1.0 Zig breaks the stdlib every release; that's recurring maintenance for zero gain.
- **Correctness left on the table.** `zig_delete_files` shells out to `/bin/rm -rf`;
  `FileManager.trashItem` gives a real Trash with Finder undo support. Iterating
  `/Volumes` by hand misses what `mountedVolumeURLs(includingResourceValuesForKeys:)`
  reports correctly.
- **Non-standard toolchain.** `build.zig` *is* the build system and `main.zig` *is* the
  entry point, which puts the project outside every standard macOS tool (Xcode,
  SwiftPM, Instruments templates, `swift test`).

Point 4 matters for choosing the target language: **removing Zig requires replacing the
build system regardless**, so "just rewrite Zig → Objective-C" is not the cheap option
it appears to be. You pay the build migration either way and end up in a language that
is harder to read.

---

## 2. Current inventory

### Zig — 1,667 lines, to be deleted entirely

| File | Lines | Real work | Swift replacement |
|---|---:|---|---|
| [src/fs_ops.zig](src/fs_ops.zig) | 167 | none — C-ABI plumbing, `@export` table, allocator setup | *deleted* |
| [src/dir_listing.zig](src/dir_listing.zig) | 136 | `readdir` + `stat` → flat C array | `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:options:)` |
| [src/volumes.zig](src/volumes.zig) | 115 | iterate `/Volumes`, `getenv("HOME")` | `mountedVolumeURLs(...)`, `FileManager.urls(for:in:)` |
| [src/file_ops.zig](src/file_ops.zig) | 147 | spawn `rm -rf`, mkdir, rename | `trashItem` / `removeItem` / `createDirectory` / `moveItem` |
| [src/transfer.zig](src/transfer.zig) | 571 | spawn `rsync`, parse `-P` progress, collision check | `Process` + `Pipe` + `AsyncStream` |
| [src/archive.zig](src/archive.zig) | 517 | spawn `7zz`, parse progress, serialize via mutex | `Process` + `Pipe` + `actor` |
| [src/main.zig](src/main.zig) | 14 | calls `objc_run_app()` | `@main` / `NSApplicationMain` |

Estimated result: **~1,667 Zig lines → ~350–400 Swift lines**, plus deletion of
[include/bridge.h](include/bridge.h) (137 lines) and every manual `free`/`ctx` dance in
the ObjC layer.

The bridge surface is small — **19 call sites** across the ObjC code, no external Zig
dependencies in [build.zig.zon](build.zig.zon).

### Objective-C — 3,179 lines, migrated last and incrementally

| File | Lines | Difficulty | Notes |
|---|---:|---|---|
| [objc/GoToFolderPanel.m](objc/GoToFolderPanel.m) | 66 | trivial | One sheet, one completion block |
| [objc/ProgressWindowController.m](objc/ProgressWindowController.m) | 192 | easy | Pure programmatic AppKit; becomes the `async` progress sink |
| [objc/AppDelegate.m](objc/AppDelegate.m) | 211 | easy | Menu construction, window registry, dock menu |
| [objc/FinderWindowController.m](objc/FinderWindowController.m) | 306 | easy | `NSSplitViewController`, `NSToolbarDelegate`, nav history |
| [objc/SidebarViewController.m](objc/SidebarViewController.m) | 594 | moderate | `NSOutlineView` source list, drop target, **`NSNetServiceBrowser`** (deprecated) |
| [objc/FileViewController.m](objc/FileViewController.m) | 1,810 | **hard — do last** | 4 view modes, FSEvents, drag & drop, Quick Look, pasteboard, inline rename |

---

## 3. Target state

```
OFinder/
├── Package.swift
├── Sources/
│   ├── OFinder/main.swift             // entry point
│   ├── OFinderServices/               // ← replaced all of src/*.zig (Phase 2 ✅)
│   │   ├── DirectoryLister.swift
│   │   ├── VolumeService.swift
│   │   ├── FileService.swift
│   │   ├── TransferService.swift
│   │   ├── ArchiveService.swift
│   │   ├── ProgressParsers.swift
│   │   ├── Subprocess.swift
│   │   └── CBridge.swift               // temporary @_cdecl shims for the ObjC UI
│   └── OFinderObjC/                   // ← becomes Swift in Phases 4–5
│       ├── include/                    // headers incl. bridge.h (dies with CBridge)
│       └── *.m
├── Tests/OFinderTests/
└── Scripts/bundle.sh                   // ← replaced makeBundleStep (Phase 1 ✅)
```

(Layout is per-target because SwiftPM forbids mixed-language targets; the plan's
original single-target tree was not buildable.)

**Build system: SwiftPM + a bundling script**, not an Xcode project.

Rationale: `makeBundleStep` in [build.zig](build.zig) already assembles the `.app` by
hand (writes `Info.plist`, copies the executable, `AppIcon.icns`, `r2_finder.png`, and
the bundled `bin/7zz` + `bin/rsync` into `Resources/`). A shell script does exactly the
same thing, keeps CI headless and diff-minimal, and avoids checking in a 3,000-line
`project.pbxproj`. The app isn't signed or notarized today, so there is nothing an
Xcode project would buy.

The CI change in [.github/workflows/release.yml](.github/workflows/release.yml) is
confined to two steps — drop `mlugg/setup-zig@v2`, and replace
`zig build bundle -Doptimize=ReleaseFast -Dversion=$TAG` with
`swift build -c release && Scripts/bundle.sh "$TAG"`. Everything downstream (`hdiutil`,
`gh release create`, the README rewrite) is untouched.

**Deployment target: macOS 13**, matching `LSMinimumSystemVersion` today. Swift
Concurrency requires 10.15+, so `async`/`await` is fully available.

**Swift language mode: start at `.v5`, flip to `.v6` in Phase 6.** An AppKit app full
of delegate callbacks and `dispatch_async` will not pass strict concurrency checking on
day one, and fighting that during a rewrite conflates two separate problems.

---

## 4. Phases

Each phase is a mergeable PR. Phases 1–3 remove Zig; phases 4–5 remove Objective-C.

### Phase 1 — Build system swap (no language change)

Take the build off Zig while leaving all Zig **and** ObjC source untouched and working.

- [x] Add `Package.swift` — two targets, since SwiftPM forbids mixed-language targets:
      `OFinderObjC` (the six `.m` files, headers in `include/`, `-fobjc-arc`, linked
      frameworks) and executable `ofinder` (named to match `CFBundleExecutable`),
      `platforms: [.macOS(.v13)]`.
- [x] Move `objc/*.m` → `Sources/OFinderObjC/`, `objc/*.h` + `include/bridge.h` →
      `Sources/OFinderObjC/include/` (the target's public headers dir).
- [x] Compile the Zig code into a static library, checked in temporarily as
      `libs/libfs_ops.a` (regenerate with `Scripts/build-zig-lib.sh`; built with
      `-target aarch64-macos.13.0` to match the deployment target). Note: SwiftPM does
      not track the `.a` as a dependency — after regenerating it, force a relink.
- [x] Port `makeBundleStep` to `Scripts/bundle.sh`. Verified with `diff -r` against
      `zig-out/oFinder.app`: identical except version string and a trailing newline
      in `Info.plist`; `7zz`/`rsync` keep mode 755.
- [x] Update `release.yml` (drop `setup-zig`; `swift build -c release` +
      `Scripts/bundle.sh`; DMG staging path `zig-out/` → `.build/`).
- [x] Replace the entry point: `Sources/OFinder/main.swift` calls `zig_init()` +
      `objc_run_app()`; `src/main.zig` deleted. `build.zig` trimmed to test-only
      (`zig build test` still green) instead of waiting for Phase 2.

**Checkpoint:** `swift build -c release && Scripts/bundle.sh v0.0.0-dev` produces a
launchable, feature-identical app.

> If the temporary static-library step feels ugly, swap Phase 1 and Phase 2 — do the
> Zig → Swift service rewrite first inside the existing `build.zig` (Swift can be
> compiled by `build.zig`, but it is awkward), or accept one throwaway commit with the
> checked-in `.a`. The `.a` route is simpler and lives for exactly one PR.

### Phase 2 — Zig → Swift services (the main win) ✅

Two premises of the original plan turned out wrong and were corrected during
implementation:

1. **SwiftPM cannot expose a Swift target's `@objc` interface to a sibling ObjC
   target** (no generated-header support). So instead of `@objc` services + 19
   call-site edits, the services are plain Swift and the C ABI survives as
   `@_cdecl` shims (`CBridge.swift`) — the ObjC call sites needed **zero**
   signature changes. Symbols were renamed `zig_*` → `r2_*` (types `Zig*` → `R2*`)
   since nothing Zig remains. `bridge.h` therefore stays until Phases 4–5, when
   ObjC callers become Swift and use the services directly.
2. **The Trash flow never went through Zig** — `deleteSelected:` already calls
   `trashItemAtURL:` in ObjC and only falls back to `zig_delete_files` for
   volumes without a Trash, behind an explicit "permanent, can't undo" alert.
   So `FileService.deleteFiles` keeps rm -rf semantics (`removeItem`, missing
   paths ignored) instead of `trashItem`. `NSAppleEventsUsageDescription` was
   still dropped from the plist — nothing ever used AppleScript.

- [x] **`VolumeService`** ← `volumes.zig`. `mountedVolumeURLs` filtered to
      `/Volumes/` (so the boot volume and hidden system volumes don't clutter the
      sidebar, which adds "Macintosh HD → /" itself), proper `volumeNameKey` display
      names. Special dirs keep the Spanish names, existence-checked.
- [x] **`FileService`** ← `file_ops.zig` + `zig_check_collision`. `removeItem`
      (permanent delete, see above), `createDirectory`, `rename(2)` (atomic,
      replaces existing destination like before), `checkCollision` via `fileExists`.
- [x] **`DirectoryLister`** ← `dir_listing.zig`. `contentsOfDirectory` + `lstat`/
      `stat`, preserving the exact old semantics: dirs-first + ASCII-case-insensitive
      sort, symlink-to-dir counts as dir, size/mtime follow symlinks, nil for
      unopenable dirs. Slight improvement: works on filesystems where `d_type` is
      `DT_UNKNOWN` (some SMB servers).
- [x] **`TransferService`** ← `transfer.zig`. `Process` + `Pipe` via a shared
      `Subprocess` helper (line-splits on `\n` **and** `\r`, drains stderr
      concurrently). **rsync argv byte-identical**
      (`-a --info=progress2 --no-inc-recursive [--ignore-existing]
      [--remove-source-files]`, trailing-slash destination). Preserves the subtle
      bits: ETA estimation formula, single 100 % emission, the 500 ms-delayed
      `progress = 1.5` "Sincronizando…" signal guaranteed to fire before
      completion, post-move empty-dir cleanup, Spanish error strings.
      (`AsyncStream` deferred to Phase 4 — pointless while the consumer is a C
      function pointer.)
- [x] **`ArchiveService`** ← `archive.zig`. Same `Subprocess` shape for `7zz`; the
      global `archive_lock` + 100 ms-poll loop became a serial `DispatchQueue`
      (fairer: FIFO instead of polling). Both progress sources preserved: `-bsp1`
      stdout percent lines and the 300 ms output-file-size monitor (split-volume
      aware, capped at 0.99).
- [x] Delete `src/`, `build.zig`, `build.zig.zon`, `.zig-cache/`, `zig-out/`, the
      stray `fs_ops.o`, and the Phase 1 temporaries `libs/libfs_ops.a` +
      `Scripts/build-zig-lib.sh`. (`bridge.h` stays — see above.)
- [x] Port the Zig unit tests to `Tests/OFinderTests/` (XCTest): 30 tests — all
      the old dir/file/volume/transfer/archive tests plus fixture-based parser
      tests for the rsync `--info=progress2` and 7zz `-bsp1` formats (the plan's
      "capture raw output, test the parser" mitigation).

**Checkpoint reached:** zero Zig in the repo, `swift test` green (30/30), ObjC
files changed only by the mechanical `zig_*`→`r2_*` rename. **The goal of the
migration is achieved — everything after this is optional polish.**

### Phase 3 — Consolidation ✅

Correction: the trampolines were not in `ProgressWindowController.m` (its API was
already documented main-thread-only) — they were the `progressCb`/`doneCb` statics
in `FileViewController.m`, and they were not dead: the services genuinely call
back on background threads. The consolidation was to centralize the main-queue
hop at the UI-facing boundary instead of at every call site.

- [x] `CBridge.wrapCallbacks` now delivers progress/completion callbacks on the
      main queue; the `dispatch_async` trampolines in `FileViewController.m`
      became direct calls, and `bridge.h` documents the new contract. The
      services themselves stay thread-agnostic (`@MainActor` would poison the
      pure service API for no benefit — main-thread delivery is a UI-boundary
      concern, and lives in the bridge that serves the UI). Ordering guarantees
      (sync-phase signal before completion) carry over because everything
      funnels through one serial queue.
- [x] README build instructions rewritten (done during Phase 2).
- [x] `.gitignore` updated (done during Phases 1–2).

### Phase 4 — ObjC → Swift, easy files ✅

Order correction: "smallest first" was impossible. Under SwiftPM, ObjC targets
cannot import Swift, so a class may only become Swift once **no remaining ObjC
file references it** — the migration must run top-down through the dependency
graph, not smallest-first. The graph made `AppDelegate` (referenced by nothing),
`FinderWindowController` (referenced only by AppDelegate) and `GoToFolderPanel`
(referenced only by those two) a closed cluster, ported together:

- [x] `AppDelegate.m` (211) → `App.swift`. `objc_run_app()` and `main.swift` are
      gone — a real `@main` `NSApplicationDelegate` with `static func main()`
      (held in a static: `NSApplication.delegate` is weak). First-responder menu
      selectors that live in `FileViewController.m` but aren't declared in its
      header (`copySelected:` etc.) are built with `NSSelectorFromString` until
      that class goes Swift.
- [x] `FinderWindowController.m` (306) → Swift. Conforms to the imported ObjC
      delegate protocols; `goBack`/`goForward` deduplicated into one
      `goToHistoryEntry(at:)`.
- [x] `GoToFolderPanel.m` (66) → Swift (a caseless `enum` with a static method —
      completion-handler shape kept; `async` adds nothing while callers are
      synchronous AppKit action methods).
- [ ] `ProgressWindowController.m` (192) — **deferred to Phase 5**: its only
      client is `FileViewController.m`, which is still ObjC and cannot see a
      Swift class. It must migrate together with (or after) `FileViewController`.

### Phase 5 — ObjC → Swift, hard files ✅

**The migration is complete: zero Objective-C, zero Zig.** With the last ObjC
file gone, the `OFinderObjC` target, `bridge.h`, and the `CBridge.swift`
`@_cdecl` shims were all deleted — the Swift UI calls the services directly.
`Package.swift` is down to two targets + tests, with no C-family settings.

- [x] `SidebarViewController.m` (594) → Swift. Kept `NSNetServiceBrowser`
      (deprecated) 1:1 — `NWBrowser` remains its own future, bisectable change.
      One mechanical substitution: the BSD `select()` wait in the SMB port-scan
      became `poll()` (Swift can't use the `FD_SET` macros); identical 300 ms
      timeout semantics. Volumes/special dirs now come straight from
      `VolumeService`.
- [x] `FileViewController.m` (1,810) → Swift, split across three files rather
      than nine commits (`FileViewSupport.swift` — model, shared clipboard,
      view subclasses; `FileViewController.swift` — core, FSEvents, loading,
      actions; `FileViewController+Views.swift` — datasources/delegates, drag &
      drop, Quick Look, menus, rename, Get Info). All nine pragma sections
      ported. Notes against the original checklist:
      - FSEvents uses `Unmanaged.passUnretained` as predicted; the debounce
        stayed a `DispatchSourceTimer` (a `Task.sleep` rewrite adds nothing).
        `FSEventStreamScheduleWithRunLoop` (deprecated) became
        `FSEventStreamSetDispatchQueue(stream, .main)` — same main-thread
        delivery, one warning gone.
      - The clipboard/`s_showHidden` statics became `FileClipboard` (a small
        caseless enum) and `FileViewController.showHidden` — `@MainActor`
        waits for Phase 6.
      - Quick Look's informal-protocol methods are `override func`s (they live
        in an NSObject category), exactly the compiler-unchecked spot the plan
        flagged.
      - `NSBrowser` kept as-is (still deprecated, still out of scope).
      - Transfers/archives call `TransferService`/`ArchiveService` directly;
        the main-queue hop happens at the call site since the C bridge that
        used to do it is gone. The `__bridge_retained`/`__bridge_transfer`
        lifetime dance around `ProgressWindowController` reduced to ordinary
        ARC closure capture.
- [x] `ProgressWindowController.m` (192) → Swift (deferred from Phase 4; its
      only client is now Swift, so it ported without interop tricks).

### Phase 6 — Strict concurrency ✅

- [x] `swift-tools-version` bumped to 6.0 (Swift 6 language mode by default);
      the initial flip produced ~53 diagnostics, resolved as:
      - **UI isolation came almost for free**: every controller inherits from
        `NSViewController`/`NSWindowController`, which are `@MainActor` in the
        SDK — so the classes were already isolated (and implicitly `Sendable`).
        Explicit `@MainActor` was only needed on `AppDelegate`, the
        app-defined delegate protocols, `FileClipboard`, and `GoToFolderPanel`.
      - Service handler typealiases are now `@Sendable`; the UI hops with
        `Task { @MainActor in … }` at the call sites (delivery order is
        preserved: main-actor jobs run FIFO in enqueue order, and the
        services' happens-before edges order the enqueues).
      - `Subprocess` and the tests' `Completion` are `@unchecked Sendable`
        with lock-guarded state; `FileEntry` is `@unchecked Sendable`
        (built on the loader thread, mutated only on main after handoff).
      - System protocols that predate concurrency (`NetServiceBrowserDelegate`,
        `QLPreviewPanelDataSource/Delegate`) use `@preconcurrency` conformance.
      - The FSEvents C callback wraps its main-queue delivery in
        `MainActor.assumeIsolated`; the SMB port-scan probe is `nonisolated`.
      - Three `nonisolated(unsafe)` escape hatches, each with a written
        justification: `loadGeneration` (advisory racy reads in the icon
        loop), `fsEventStream`/`reloadDebounce` and `smbBrowser` (nonisolated
        `deinit` cleanup), and the freshly-created `NSImage` handoffs.

**The migration plan (Phases 1–6) is fully executed.** Phase 7 below is
post-migration modernization work, planned separately.

### Phase 7 — Modern column view (replace `NSBrowser`)

Both `NSBrowser` and `NSBrowserCell` are deprecated with no drop-in AppKit
successor — Apple's own answer is "build Miller columns yourself". The
replacement is a small custom component; the data flow it needs
(`columnEntries` / `columnPaths`, trim-and-append on directory selection)
already exists in `FileViewController` and carries over unchanged.

**Design: `MillerColumnView`** — a horizontal `NSScrollView` containing an
`NSStackView` of columns; each column is an `NSTableView` (single column,
icon + name cells reusing the existing `NameCell` style) inside its own
vertical scroll view. Fixed column width 180 (matching the old
`minColumnWidth`); the horizontal scroller replaces `maxVisibleColumns`.

Communication via a small delegate, mirroring how the sidebar already talks
to its owner:

```swift
@MainActor protocol MillerColumnViewDelegate: AnyObject {
    func columnView(_ v: MillerColumnView, entriesForPath path: String) -> [FileEntry]
    func columnView(_ v: MillerColumnView, didSelectDirectory path: String)
    func columnView(_ v: MillerColumnView, didSelectFileInDirectory path: String)
    func columnView(_ v: MillerColumnView, open entry: FileEntry)
}
```

Steps (all done — the component landed as one piece since the delegate
surface was designed up front):

- [x] 1. `MillerColumnView.swift`: horizontal scroll + stack of per-column
      table views, column add/trim, `reload(fromPath:)`.
- [x] 2. Selection semantics matching the old `browserSingleClick`: single
      directory selection trims deeper columns and appends the child column
      (`didSelectDirectory` → `currentPath` + history); file selection sets
      `currentPath` to the containing column; double-click opens files.
      Multi-selection feeds `selectedPaths` and deliberately does *not*
      expand a child column (Finder behavior). File selection also refreshes
      an open Quick Look panel — a small upgrade over `NSBrowser` mode.
- [x] 3. Keyboard: ←/→ move column focus (→ selects the first child row if
      none), ↑/↓ native, ⏎ opens files; new columns scroll into view.
- [x] 4. Swapped into `FileViewController`: `browser`/`columnEntries`/
      `columnPaths` properties and the whole `NSBrowserDelegate` extension
      deleted (the component owns column state now); Quick Look forwarding
      targets the active column's table.
- [x] 5. Upgrades the `NSBrowser` mode never had: per-row context menus
      (same menu as the other modes) and drag & drop both directions
      (rows as drag sources; drops onto directory rows or column background,
      move-vs-copy from the drag mask).
- [x] 6. Deprecation zero: `outlineView.style = .sourceList` replaced the
      deprecated `selectionHighlightStyle` — **the project now builds with
      zero warnings**. (`NetServiceBrowser` is soft-deprecated and stays
      until an `NWBrowser` phase is planned.)

**Risk note:** column view is the least-used mode (list is the default) and
the swap is contained in one file plus one new component — but step 2's
`currentPath` semantics feed navigation history and the status bar, so a
manual click-through of column-mode navigation before merging is the main
verification.

---

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| `FileViewController` regression — it's 57% of the ObjC and holds all the fiddly interaction code | Migrated last, split into 9 commits along `#pragma mark` lines, each independently testable by hand |
| rsync/7zz progress parsing drifts during the `Process` rewrite | Keep argv byte-identical; capture a known transfer's raw stdout to a fixture file and unit-test the parser against it *before* swapping implementations |
| FSEvents C-callback bridging in Swift | Isolated to its own commit; `Unmanaged` + `@convention(c)` is well-trodden, and the existing debounce logic ports directly |
| `NSNetServiceBrowser` deprecation tempts scope creep | Explicitly its own commit in Phase 5; migration to `NWBrowser` is optional and can be deferred indefinitely |
| Bundle output differs from the Zig build (signing, permissions, exec bit on `bin/7zz`) | `diff -r` the two `.app` bundles in Phase 1 before deleting `makeBundleStep`; verify `7zz`/`rsync` keep mode `755` |
| Migration stalls halfway | Every phase ships. Stopping after Phase 2 already removes Zig — the ObjC layer can stay indefinitely |

## 6. Not in scope

- ~~Replacing `NSBrowser` (deprecated) with a modern column view~~ — promoted to
  **Phase 7** (planned above).
- Any SwiftUI adoption — **decided: staying AppKit.** The app is a thin,
  fast shell over AppKit views; SwiftUI would add a layer without adding
  capability.
- Code signing / notarization — **blocked on an Apple Developer Program
  membership (99 USD/year), which the project doesn't have.** Notarization
  requires a Developer ID certificate; there is no free tier that removes the
  Gatekeeper prompt. The binaries are already ad-hoc signed by the linker
  (mandatory on Apple Silicon), so the current `xattr -d com.apple.quarantine`
  instruction in the README remains the correct guidance. Revisit only if a
  membership is acquired.
- Behaviour changes to the rsync strategy — **permanent.** The bundled
  `bin/rsync`, the exact argv (`-a --info=progress2 --no-inc-recursive
  [--ignore-existing] [--remove-source-files]`), the trailing-slash
  destination, the post-move cleanup and the collision policy are the app's
  reason to exist (reliable copies to quirky SMB servers). Any "improvement"
  there — rsync 3.x, `--partial`, xattr flags — is a product decision to be
  made deliberately, never as a side effect of refactoring.
