// FileViewController.swift
// Port of FileViewController.m (core half): view construction, FSEvents
// monitoring, data loading, clipboard/transfer/archive actions.
// The view datasources/delegates, drag & drop, Quick Look, context menus and
// inline rename live in FileViewController+Views.swift.

import AppKit
import CoreServices
import Quartz
import OFinderServices
import UniformTypeIdentifiers

enum FileViewMode: Int {
    case icon = 0
    case list = 1
    case columns = 2
    case gallery = 3
}

@MainActor
protocol FileViewControllerDelegate: AnyObject {
    func fileViewController(_ vc: FileViewController, didNavigateToPath path: String)
}

final class FileViewController: NSViewController {

    weak var delegate: FileViewControllerDelegate?
    /// Coalesces flow-layout metric invalidations from thumbnail arrivals.
    var iconLayoutRefreshScheduled = false

    private(set) var currentPath: String

    static var showHidden = false

    var viewMode: FileViewMode = .list {
        didSet {
            scrollView.isHidden = true
            iconScrollView.isHidden = true
            columnView.isHidden = true
            switch viewMode {
            case .list:
                scrollView.isHidden = false
            case .icon:
                iconScrollView.isHidden = false
                collectionView.reloadData()
            case .columns:
                // Column browsing walks a directory tree. Recents is a flat
                // query with no tree to walk, so fall back to list there
                // rather than showing an empty first column.
                if RecentsService.isRecents(currentPath) {
                    scrollView.isHidden = false
                } else {
                    columnView.isHidden = false
                    columnView.reload(fromPath: currentPath)
                }
            case .gallery:
                // Gallery not yet implemented – fall back to list
                scrollView.isHidden = false
            }
        }
    }

    // Views
    let scrollView = NSScrollView()                     // list view
    let outlineView = ContextMenuOutlineView()
    let iconScrollView = NSScrollView()                 // icon view
    let collectionView = ContextMenuCollectionView()
    let columnView = MillerColumnView()                 // column view
    private let statusLabel = NSTextField(labelWithString: "")
    private let loadingSpinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))

    // Model
    var entries: [FileEntry] = []
    var renameRow = -1

    // Outline expansion/selection, tracked live as the user drives them rather
    // than read back from the outline at reload time. A reload always follows a
    // change to `entries`, and querying rows in that window makes AppKit
    // materialize stale rows through the data source (itemAtRow: →
    // outlineView(_:child:ofItem:)) with indices the new model no longer has.
    var expandedOutlinePaths: Set<String> = []
    var selectedOutlinePaths: Set<String> = []
    // Set while reloadOutlinePreservingState() re-applies the snapshot, so the
    // expand/collapse/selection callbacks it triggers don't overwrite it.
    var isRestoringOutlineState = false
    // Folders whose children are being listed off-main, by path, so repeated
    // data-source queries during an expansion enqueue the listing only once.
    // It doubles as backpressure: while a folder's refresh is in flight, the
    // next FSEvents tick won't queue another listing of it behind the first.
    private var childrenLoading: Set<String> = []
    // The `showHidden` setting the on-screen entries were listed with. A
    // mismatch means carried-over subtrees were filtered differently and can't
    // be reused.
    private var loadedShowHidden = FileViewController.showHidden

    // Loading
    private let loadQueue = DispatchQueue(label: "dev.afuit.ofinder.dirload")
    // nonisolated(unsafe): mutated only on the main actor; the background
    // icon/listing loops read it as an advisory early-exit check, where a
    // stale value is harmless (the main-actor guard re-checks on delivery).
    private nonisolated(unsafe) var loadGeneration = 0
    private var isLoading = false
    /// The last load was refused rather than returning nothing.
    private var currentLocationUnreadable = false

    // FSEvents — nonisolated(unsafe) so deinit (nonisolated) can clean up;
    // both are otherwise only touched on the main actor.
    private nonisolated(unsafe) var fsEventStream: FSEventStreamRef?
    private nonisolated(unsafe) var reloadDebounce: DispatchSourceTimer?

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Init / View
    // ─────────────────────────────────────────────────────────────────────────

    init(path: String) {
        currentPath = path
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipboardDidChange(_:)),
                                               name: FileClipboard.changedNotification,
                                               object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        // Inline cleanup: deinit is nonisolated and cannot call the
        // main-actor-isolated stopWatching().
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        reloadDebounce?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clipboardDidChange(_ note: Notification) {
        reloadAllViews()
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        view.wantsLayer = true

        // Status bar at bottom
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Loading spinner (centered, hidden when stopped)
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.isDisplayedWhenStopped = false
        view.addSubview(loadingSpinner)

        // Outline view (supports expandable folders)
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnResizing = true
        outlineView.allowsColumnReordering = false
        outlineView.rowSizeStyle = .medium
        outlineView.gridStyleMask = .solidHorizontalGridLineMask
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.indentationPerLevel = 18
        outlineView.autoresizesOutlineColumn = true
        outlineView.doubleAction = #selector(tableViewDoubleClicked(_:))
        outlineView.target = self

        // Drag source
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        // Drag destination
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.draggingDestinationFeedbackStyle = .regular

        // Columns
        let columnDefs: [(id: String, title: String, width: CGFloat)] = [
            ("name", L10n.t("column.name", "Name"), 340),
            ("size", L10n.t("column.size", "Size"), 100),
            ("date", L10n.t("column.dateModified", "Date Modified"), 180),
            ("kind", L10n.t("column.kind", "Kind"), 120),
        ]
        for (i, def) in columnDefs.enumerated() {
            let col = NSTableColumn(identifier: .init(def.id))
            col.title = def.title
            col.width = def.width
            col.minWidth = 60
            col.sortDescriptorPrototype = NSSortDescriptor(key: def.id, ascending: true)
            outlineView.addTableColumn(col)
            if i == 0 {
                outlineView.outlineTableColumn = col // disclosure triangles in Name column
            }
        }

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Icon view (NSCollectionView)
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = NSSize(width: 90, height: 90)
        flow.minimumInteritemSpacing = 10
        flow.minimumLineSpacing = 10
        flow.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        collectionView.collectionViewLayout = flow
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(IconCollectionViewItem.self,
                                forItemWithIdentifier: .init("IconItem"))
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        iconScrollView.hasVerticalScroller = true
        iconScrollView.hasHorizontalScroller = false
        iconScrollView.documentView = collectionView
        iconScrollView.translatesAutoresizingMaskIntoConstraints = false
        iconScrollView.isHidden = true // start with list view
        view.addSubview(iconScrollView)

        // Column view (Miller columns)
        columnView.translatesAutoresizingMaskIntoConstraints = false
        columnView.isHidden = true
        columnView.delegate = self
        view.addSubview(columnView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            iconScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            iconScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            iconScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            iconScrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            columnView.topAnchor.constraint(equalTo: view.topAnchor),
            columnView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            columnView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            columnView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            statusLabel.heightAnchor.constraint(equalToConstant: 18),

            loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadPath(currentPath)
    }

    override func keyDown(with event: NSEvent) {
        if renameRow >= 0 { return } // let the rename field handle all keys
        let cmd = event.modifierFlags.contains(.command)
        // Finder behavior: ⏎ renames, ⌘↓ / ⌘O opens.
        if event.specialKey == .carriageReturn, !cmd {
            renameSelected(nil)
            return
        }
        if cmd, event.specialKey == .downArrow { openSelected(nil); return }
        if cmd, event.charactersIgnoringModifiers == "o" { openSelected(nil); return }
        if event.specialKey == .delete { deleteSelected(nil); return }
        if event.characters == " " {
            if let panel = QLPreviewPanel.shared() {
                if panel.isVisible {
                    panel.orderOut(nil)
                } else {
                    panel.makeKeyAndOrderFront(nil)
                }
            }
            return
        }
        super.keyDown(with: event)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – FSEvents directory monitoring
    // ─────────────────────────────────────────────────────────────────────────

    /// Coalesce bursts of FSEvents (e.g. rsync deleting many files in a row
    /// over SMB) into a single reload that fires after a short quiet period.
    func scheduleReload() {
        if reloadDebounce == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                reloadDebounce?.schedule(deadline: .distantFuture)
                loadPath(currentPath)
            }
            timer.resume()
            reloadDebounce = timer
        }
        reloadDebounce?.schedule(deadline: .now() + .milliseconds(400),
                                 repeating: .never,
                                 leeway: .milliseconds(50))
    }

    /// Reload only when an event actually changes what this listing shows.
    ///
    /// FSEvents watches a directory *tree*. In "/" that is the whole disk, so
    /// every log write and cache update anywhere arrived here and triggered a
    /// full reload — the flicker in the root listing. An event matters only if
    /// it touched the watched directory itself, one of its direct children, or
    /// a folder the user has expanded in the outline.
    func handleFSEvents(_ paths: [String], count: Int) {
        // A dropped-events notification arrives with no usable paths; reload
        // rather than risk showing a stale listing.
        guard !paths.isEmpty else {
            scheduleReload()
            return
        }
        let watched = currentPath
        let relevant = paths.contains { path in
            if path == watched { return true }
            let parent = (path as NSString).deletingLastPathComponent
            return parent == watched || expandedOutlinePaths.contains(parent)
        }
        guard relevant else { return }
        scheduleReload()
    }

    private func startWatching(path: String) {
        stopWatching()
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let vc = Unmanaged<FileViewController>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes makes eventPaths a CFArray of
            // CFString.
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String])
                ?? []
            // Events are delivered on the main queue (SetDispatchQueue below).
            MainActor.assumeIsolated {
                vc.handleFSEvents(paths, count: numEvents)
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &ctx,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // 500ms latency – batches rapid changes
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        // (The ObjC version used the deprecated ScheduleWithRunLoop; the
        // dispatch-queue API is its direct replacement with identical
        // main-thread delivery.)
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }

    private func stopWatching() {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Data loading
    // ─────────────────────────────────────────────────────────────────────────

    func loadPath(_ path: String) {
        let pathChanged = currentPath != path
        currentPath = path
        // Recents has no directory to watch; FSEvents on the token would fail
        // and leave the previous directory's stream running.
        if pathChanged {
            if RecentsService.isRecents(path) {
                stopWatching()
            } else {
                startWatching(path: path)
            }
        }

        // On navigation, blank the view immediately so the user sees they've
        // moved. On in-place refresh (FSEvents), keep the existing entries on
        // screen so the UI doesn't flicker through Loading… every time
        // rsync deletes a file.
        if pathChanged {
            // The old directory's expansion/selection means nothing here, and
            // keeping it would re-expand same-named folders in the new one.
            expandedOutlinePaths.removeAll()
            selectedOutlinePaths.removeAll()
            entries.removeAll()
            reloadAllViews()
            isLoading = true
            loadingSpinner.startAnimation(nil)
            updateStatusBar()
        }

        // Capture generation to detect superseded loads
        loadGeneration += 1
        let thisGeneration = loadGeneration
        let showHidden = Self.showHidden

        loadQueue.async { [weak self] in
            let listed = Self.entriesList(forPath: path, showHidden: showHidden)
            let unreadable = listed == nil
            let newEntries = listed ?? []

            // Assign cheap placeholder icons synchronously (no I/O) so the UI
            // can render immediately. Real per-file icons are fetched
            // off-main below.
            let folderPlaceholder = NSImage(named: NSImage.folderName)
            let filePlaceholder = NSImage(named: NSImage.multipleDocumentsName)
            folderPlaceholder?.size = NSSize(width: 16, height: 16)
            filePlaceholder?.size = NSSize(width: 16, height: 16)
            for fe in newEntries {
                fe.icon = fe.isDir ? folderPlaceholder : filePlaceholder
            }

            Task { @MainActor in
                guard let self, self.loadGeneration == thisGeneration else { return }

                self.isLoading = false
                self.loadingSpinner.stopAnimation(nil)
                self.currentLocationUnreadable = unreadable
                if unreadable {
                    FullDiskAccess.explain(blockedPath: path, in: self.view.window)
                }

                // On an in-place refresh (FSEvents during a transfer or
                // extraction), carry over the already-loaded icons by path —
                // otherwise every reload flashes placeholder icons until the
                // background fill-in catches up ("blinking").
                var oldIcons: [String: NSImage] = [:]
                for e in self.entries where e.icon != nil {
                    oldIcons[e.path] = e.icon
                }
                if !oldIcons.isEmpty {
                    for fe in newEntries {
                        if let icon = oldIcons[fe.path] { fe.icon = icon }
                    }
                }

                // Likewise carry over expanded subtrees. Children now load
                // asynchronously, so without this an expanded folder would empty
                // out on every FSEvents refresh and repopulate a beat later.
                // Only expanded ones: a collapsed folder can re-list on demand.
                var oldChildren: [String: [FileEntry]] = [:]
                if showHidden == self.loadedShowHidden {
                    for e in self.entries
                    where e.childrenLoaded && self.expandedOutlinePaths.contains(e.path) {
                        oldChildren[e.path] = e.children
                    }
                }
                for fe in newEntries {
                    if let kids = oldChildren[fe.path] {
                        fe.children = kids
                        fe.childrenLoaded = true
                    }
                }

                self.entries = newEntries
                self.loadedShowHidden = showHidden
                self.reloadAllViews()
                self.updateStatusBar()

                // The carried-over subtrees are the *previous* listing; refresh
                // them off-main so an expanded folder tracks the transfer too.
                for fe in newEntries where oldChildren[fe.path] != nil {
                    self.loadChildren(for: fe, force: true)
                }

                // Fill real icons in the background. icon(forFile:) can do
                // synchronous metadata I/O — on Samba shares this blocks the
                // main thread for hundreds of round-trips.
                self.fillIcons(for: newEntries, generation: thisGeneration)
            }
        }
    }

    /// Build FileEntry objects for a location (no icons).
    ///
    /// Recents is a query, not a directory, so it bypasses DirectoryLister —
    /// and it ignores `showHidden`, since the query never returns dotfiles.
    /// Returns nil when the location cannot be read at all, which is not the
    /// same as it being empty — ~/.Trash and the other TCC-protected folders
    /// refuse to open until the app is granted Full Disk Access, and an empty
    /// list there says "nothing here" when the truth is "not allowed to look".
    nonisolated static func entriesList(forPath path: String, showHidden: Bool) -> [FileEntry]? {
        let listed: [DirEntry]
        if RecentsService.isRecents(path) {
            listed = RecentsService.list()
        } else {
            guard let dir = DirectoryLister.list(path: path) else { return nil }
            listed = dir
        }
        return listed.compactMap { e in
            if !showHidden && e.name.hasPrefix(".") { return nil }
            let fe = FileEntry()
            fe.name = e.name
            fe.path = e.path
            fe.isDir = e.isDir
            fe.isSymlink = e.isSymlink
            fe.size = e.size
            fe.mtime = e.mtime
            return fe
        }
    }

    private func fillIcons(for entries: [FileEntry], generation: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ws = NSWorkspace.shared
            for fe in entries {
                guard let self, self.loadGeneration == generation else { return }
                let img = ws.icon(forFile: fe.path)
                img.size = NSSize(width: 16, height: 16)
                Task { @MainActor in
                    guard self.loadGeneration == generation else { return }
                    fe.icon = img
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.reloadAllViews()
            }
        }
    }

    func reloadAllViews() {
        reloadOutlinePreservingState()
        collectionView.reloadData()
        if viewMode == .columns, !RecentsService.isRecents(currentPath) {
            columnView.reload(fromPath: currentPath)
        }
    }

    /// Reload the outline without losing the user's place. Reloads rebuild the
    /// FileEntry objects (and fire asynchronously — FSEvents, icon fill-in,
    /// clipboard changes), so a plain reloadData() would collapse every
    /// expanded folder and drop the selection mid-interaction. Expansion and
    /// selection are restored by path from the snapshot kept in
    /// `expandedOutlinePaths`/`selectedOutlinePaths`; the outline itself is only
    /// queried *after* reloadData(), when its rows match `entries` again.
    private func reloadOutlinePreservingState() {
        let expanded = expandedOutlinePaths

        isRestoringOutlineState = true
        defer { isRestoringOutlineState = false }

        outlineView.reloadData()
        guard !expanded.isEmpty || !selectedOutlinePaths.isEmpty else { return }

        // Re-expand parents before children so nested rows materialize.
        for path in expanded.sorted(by: { $0.count < $1.count }) {
            for row in 0..<outlineView.numberOfRows {
                if let e = outlineView.item(atRow: row) as? FileEntry, e.path == path {
                    outlineView.expandItem(e)
                    break
                }
            }
        }

        restoreOutlineSelection()
    }

    /// Re-select the rows whose paths are in `selectedOutlinePaths`. Every
    /// reload rebuilds the FileEntry objects, so selection only survives by path.
    /// Only safe once the outline's rows agree with `entries` again.
    private func restoreOutlineSelection() {
        guard !selectedOutlinePaths.isEmpty else { return }
        var indexes = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let e = outlineView.item(atRow: row) as? FileEntry,
               selectedOutlinePaths.contains(e.path) {
                indexes.insert(row)
            }
        }
        if !indexes.isEmpty {
            outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    func updateStatusBar() {
        if isLoading {
            statusLabel.stringValue = L10n.t("progress.loading", "Loading…")
            return
        }
        if currentLocationUnreadable {
            statusLabel.stringValue = L10n.t(
                "status.unreadable",
                "Can't read this folder — grant Full Disk Access in System Settings")
            return
        }
        let folders = entries.lazy.filter(\.isDir).count
        let files = entries.count - folders
        let folderStr = folders == 1
            ? L10n.f("status.folderOne", "%d folder", folders)
            : L10n.f("status.folderMany", "%d folders", folders)
        let fileStr = files == 1
            ? L10n.f("status.fileOne", "%d file", files)
            : L10n.f("status.fileMany", "%d files", files)
        statusLabel.stringValue = "\(folderStr), \(fileStr)"
    }

    /// Column-view listing, off-main. Icons are fetched on the same background
    /// pass rather than filled in later: a column's rows are all visible at
    /// once, and reloadAllViews() — which the icon fill-in ends with — would
    /// rebuild the columns and throw away the user's place in them.
    func loadColumnEntries(forPath path: String,
                           completion: @escaping @MainActor ([FileEntry]) -> Void) {
        let showHidden = Self.showHidden
        loadQueue.async {
            let result = Self.entriesList(forPath: path, showHidden: showHidden) ?? []
            let ws = NSWorkspace.shared
            for fe in result {
                let icon = ws.icon(forFile: fe.path)
                icon.size = NSSize(width: 16, height: 16)
                fe.icon = icon
            }
            let sorted = result.sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            Task { @MainActor in completion(sorted) }
        }
    }

    /// Load an expanded folder's children off the main thread.
    ///
    /// Both halves of this used to run inline in
    /// `outlineView(_:numberOfChildrenOfItem:)`: the directory listing and one
    /// `NSWorkspace.icon(forFile:)` per child, each a synchronous round-trip.
    /// On an SMB share that froze the UI for the whole expansion. The data
    /// source now reports zero children until the listing lands, then the item
    /// is reloaded (and re-expanded, since expanding an empty folder leaves the
    /// outline with nothing to show).
    ///
    /// `force` re-lists a folder whose children are already loaded — used when
    /// an in-place refresh carries an expanded subtree over to fresh entries.
    func loadChildren(for entry: FileEntry, force: Bool = false) {
        guard force || !entry.childrenLoaded else { return }
        guard !childrenLoading.contains(entry.path) else { return }
        childrenLoading.insert(entry.path)

        let path = entry.path
        let showHidden = Self.showHidden
        let generation = loadGeneration

        loadQueue.async { [weak self] in
            let children = Self.entriesList(forPath: path, showHidden: showHidden) ?? []

            // Cheap placeholders (no I/O); fillIcons replaces them off-main.
            let folderPlaceholder = NSImage(named: NSImage.folderName)
            let filePlaceholder = NSImage(named: NSImage.multipleDocumentsName)
            folderPlaceholder?.size = NSSize(width: 16, height: 16)
            filePlaceholder?.size = NSSize(width: 16, height: 16)
            for fe in children {
                fe.icon = fe.isDir ? folderPlaceholder : filePlaceholder
            }

            Task { @MainActor in
                guard let self else { return }
                self.childrenLoading.remove(path)
                // A newer load replaced the whole tree — `entry` is orphaned.
                guard self.loadGeneration == generation else { return }

                // Keep icons already fetched for this subtree (in-place refresh).
                var oldIcons: [String: NSImage] = [:]
                for e in entry.children where e.icon != nil { oldIcons[e.path] = e.icon }
                for fe in children where oldIcons[fe.path] != nil { fe.icon = oldIcons[fe.path] }

                entry.children = children
                entry.childrenLoaded = true

                // Guarded: reloading the subtree drops any selection inside it,
                // which would otherwise erase those paths from the snapshot
                // before restoreOutlineSelection() can put the rows back.
                self.isRestoringOutlineState = true
                self.outlineView.reloadItem(entry, reloadChildren: true)
                // The outline may already consider the folder expanded (the user
                // clicked its triangle while it still reported zero children), or
                // it may be a subtree we're restoring after a refresh.
                if self.outlineView.isItemExpanded(entry)
                    || self.expandedOutlinePaths.contains(path) {
                    self.expandedOutlinePaths.insert(path)
                    self.outlineView.expandItem(entry)
                }
                self.restoreOutlineSelection()
                self.isRestoringOutlineState = false

                self.fillIcons(for: children, generation: generation)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Public API
    // ─────────────────────────────────────────────────────────────────────────

    func createNewFolder(inPath path: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t("action.newFolder", "New Folder")
        alert.informativeText = L10n.t("newFolder.prompt", "Name of the new folder:")
        alert.addButton(withTitle: L10n.t("button.create", "Create"))
        alert.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = L10n.t("newFolder.untitled", "untitled folder")
        input.stringValue = L10n.t("newFolder.untitled", "untitled folder")
        alert.accessoryView = input
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            let name = input.stringValue
            guard !name.isEmpty else { return }
            let newPath = (path as NSString).appendingPathComponent(name)
            if let error = FileService.createDirectory(path: newPath) {
                showErrorMessage(error)
            } else {
                loadPath(currentPath)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Navigation
    // ─────────────────────────────────────────────────────────────────────────

    /// Column-view navigation updates the path without reloading — the
    /// columns already display the content.
    func setCurrentPathFromColumns(_ path: String) {
        currentPath = path
    }

    func openEntry(_ e: FileEntry) {
        if e.isDir {
            loadPath(e.path)
            delegate?.fileViewController(self, didNavigateToPath: e.path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: e.path))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Clipboard actions
    // ─────────────────────────────────────────────────────────────────────────

    /// The internal clipboard if set, otherwise file URLs on the system
    /// pasteboard (e.g. files copied from Finder or another app).
    func effectiveClipboardPaths() -> [String] {
        if !FileClipboard.paths.isEmpty { return FileClipboard.paths }
        guard let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return [] }
        return urls.map(\.path)
    }

    func selectedPaths() -> [String] {
        switch viewMode {
        case .icon:
            return collectionView.selectionIndexPaths.compactMap { ip in
                ip.item < entries.count ? entries[ip.item].path : nil
            }
        case .columns:
            return columnView.selectedPaths
        default:
            return outlineView.selectedRowIndexes.compactMap { idx in
                (outlineView.item(atRow: idx) as? FileEntry)?.path
            }
        }
    }

    @IBAction func openSelected(_ sender: Any?) {
        // Path-based (not a lookup in the top-level entries array) so it also
        // works for rows nested under expanded folders and for column mode.
        for path in selectedPaths() {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                loadPath(path)
                delegate?.fileViewController(self, didNavigateToPath: path)
                return
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    // These three answer to the standard editing selectors rather than names
    // of their own. A focused text field — the path bar — implements
    // `copy:`/`cut:`/`paste:` itself and handles the keystroke before it can
    // travel up here; under a private name the field ignores it, the file
    // list answers instead, and Cmd+C over a selected path quietly copies
    // files while Cmd+V pastes them into the folder behind it.
    @IBAction @objc(copy:) func copySelected(_ sender: Any?) {
        FileClipboard.set(selectedPaths(), operation: .copy)
    }

    @IBAction @objc(cut:) func cutSelected(_ sender: Any?) {
        FileClipboard.set(selectedPaths(), operation: .cut)
    }

    @IBAction @objc(paste:) func pasteHere(_ sender: Any?) {
        let paths = effectiveClipboardPaths()
        guard !paths.isEmpty else { return }
        let isMove = !FileClipboard.paths.isEmpty && FileClipboard.operation == .cut
        performTransfer(fromPaths: paths, toDir: currentPath, isMove: isMove)
        if isMove { FileClipboard.clear() }
    }

    @IBAction func moveHere(_ sender: Any?) {
        let paths = effectiveClipboardPaths()
        guard !paths.isEmpty else { return }
        performTransfer(fromPaths: paths, toDir: currentPath, isMove: true)
        FileClipboard.clear()
    }

    @IBAction func newFolderAction(_ sender: Any?) {
        createNewFolder(inPath: currentPath)
    }

    @IBAction func toggleHidden(_ sender: Any?) {
        Self.showHidden.toggle()
        loadPath(currentPath)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Transfers
    // ─────────────────────────────────────────────────────────────────────────

    /// Puts the selected items' paths on the clipboard as text.
    ///
    /// Separate from Copy, which puts the files themselves there: pasting into
    /// a folder should move file data, and pasting into a terminal should give
    /// you something to type after `cd`. One clipboard cannot mean both.
    /// Puts trashed items back where they came from.
    ///
    /// The original folder is often gone too — people clear a project by
    /// deleting the whole thing — so it is recreated rather than refused.
    /// Refusing would fail on exactly the items someone most wants back.
    @IBAction func restoreFromTrash(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }
        let origins = TrashIndex.origins(trashPath: TrashService.path)
        let fm = FileManager.default

        var unknown: [String] = []
        var blocked: [String] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard let target = origins[name] else { unknown.append(name); continue }
            guard !fm.fileExists(atPath: target) else { blocked.append(name); continue }
            let parent = (target as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            do {
                try fm.moveItem(atPath: path, toPath: target)
            } catch {
                blocked.append(name)
            }
        }
        loadPath(currentPath)

        guard !unknown.isEmpty || !blocked.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("restore.failedTitle", "Some items were not restored")
        alert.informativeText = [
            unknown.isEmpty ? nil : L10n.f("restore.noRecord",
                                           "No record of where these came from: %@",
                                           unknown.joined(separator: ", ")),
            blocked.isEmpty ? nil : L10n.f("restore.blocked",
                                           "Something is already in the way of: %@",
                                           blocked.joined(separator: ", ")),
        ].compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: L10n.t("button.ok", "OK"))
        alert.runModal()
    }

    /// Erases without the Trash step, because these are already in it.
    @IBAction func deleteImmediately(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = paths.count == 1
            ? L10n.f("delete.confirmOne", "\"%@\" will be deleted permanently.",
                     (paths[0] as NSString).lastPathComponent)
            : L10n.f("delete.confirmMany", "%d items will be deleted permanently.",
                     paths.count)
        alert.informativeText = L10n.t("trash.emptyBody", "You can't undo this action.")
        alert.addButton(withTitle: L10n.t("action.deleteImmediately", "Delete Immediately"))
        alert.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        loadPath(currentPath)
    }

    @IBAction func copyPathsAsText(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Newline-separated, which is what a shell loop and a text editor both
        // expect from a list of paths.
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func performTransfer(fromPaths paths: [String], toDir dstDir: String, isMove: Bool) {
        if let rejection = TransferGuard.check(sources: paths, dstDir: dstDir,
                                               isMove: isMove) {
            reportRejection(rejection)
            return
        }

        // A large move is the one that hurts when it was not intended, and it
        // is also the one nobody notices starting.
        if isMove, paths.count >= 25 {
            let alert = NSAlert()
            alert.messageText = L10n.f("transfer.confirmLargeMove",
                                       "Move %d items to “%@”?",
                                       paths.count,
                                       (dstDir as NSString).lastPathComponent)
            alert.informativeText = L10n.t(
                "transfer.confirmLargeMoveBody",
                "The originals will be removed from their current location.")
            alert.addButton(withTitle: L10n.t("action.moveHere", "Move Here"))
            alert.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        if FileService.checkCollision(sources: paths, dstDir: dstDir) {
            let alert = NSAlert()
            alert.messageText = L10n.t("conflict.title", "An item with that name already exists")
            alert.informativeText = L10n.t("conflict.body", "Do you want to replace the existing files?")
            alert.addButton(withTitle: L10n.t("button.replace", "Replace"))
            alert.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
            alert.addButton(withTitle: L10n.t("button.keepBoth", "Keep Both"))
            let resp = alert.runModal()
            if resp == .alertSecondButtonReturn { return }
            startTransfer(paths: paths, dstDir: dstDir,
                          overwrite: resp == .alertFirstButtonReturn, isMove: isMove)
        } else {
            startTransfer(paths: paths, dstDir: dstDir, overwrite: false, isMove: isMove)
        }
    }

    private func reportRejection(_ rejection: TransferGuard.Rejection) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch rejection {
        case .destinationIsSource(let source), .destinationInsideSource(let source):
            alert.messageText = L10n.f(
                "transfer.rejectIntoItself",
                "“%@” can't be moved into itself.",
                (source as NSString).lastPathComponent)
            alert.informativeText = L10n.t(
                "transfer.rejectIntoItselfBody",
                "Choose a destination outside the folder you are moving.")
        case .alreadyThere:
            alert.messageText = L10n.t("transfer.rejectAlreadyThere",
                                       "Those items are already in this folder.")
            alert.informativeText = ""
        }
        alert.addButton(withTitle: L10n.t("button.ok", "OK"))
        alert.runModal()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Undo
    // ─────────────────────────────────────────────────────────────────────────

    @IBAction func undoLastMove(_ sender: Any?) {
        guard let record = MoveUndo.available, let rsync = Self.rsyncPath else { return }
        MoveUndo.clear()

        // One rsync per original parent directory. A drag usually has a single
        // parent, so this is normally one pass.
        for (targetDir, movedPaths) in record.restoreGroups {
            let pwc = makeProgressWindow(title: L10n.t("progress.moving", "Moving"),
                                         destination: targetDir)
            let (onProgress, onDone) = progressHandlers(pwc)
            pwc.cancelHandle = TransferService.move(
                rsyncPath: rsync, sources: movedPaths, dstDir: targetDir,
                overwrite: false, onProgress: onProgress, onDone: onDone)
        }
    }

    /// Wrap a ProgressWindowController into main-thread service handlers.
    /// (The services invoke callbacks on background threads.)
    private func progressHandlers(_ pwc: ProgressWindowController)
        -> (TransferService.ProgressHandler, TransferService.CompletionHandler) {
        let onProgress: TransferService.ProgressHandler = { p, bytes, total, speed, eta in
            Task { @MainActor in
                pwc.updateProgress(p, bytesTransferred: bytes, totalBytes: total,
                                   speed: speed, etaSecs: eta)
            }
        }
        let onDone: TransferService.CompletionHandler = { ok, msg in
            Task { @MainActor in
                pwc.finish(success: ok, errorMessage: msg)
            }
        }
        return (onProgress, onDone)
    }

    private func makeProgressWindow(title: String, destination: String) -> ProgressWindowController {
        let pwc = ProgressWindowController(title: title, destinationFolder: destination) { [weak self] in
            guard let self else { return }
            loadPath(currentPath)
        }
        pwc.showWindow(nil)
        return pwc
    }

    private func startTransfer(paths: [String], dstDir: String, overwrite: Bool, isMove: Bool) {
        guard let rsync = Self.rsyncPath else {
            showErrorMessage(L10n.t("error.rsyncMissing", "rsync binary not found"))
            return
        }
        let pwc = makeProgressWindow(title: isMove ? L10n.t("progress.moving", "Moving") : L10n.t("progress.copying", "Copying"), destination: dstDir)
        let (onProgress, onDone) = progressHandlers(pwc)
        if isMove {
            // Record only on success. A failed or half-finished move leaves
            // files in both places, and "undo" against that would move the
            // wrong set.
            let recordingDone: TransferService.CompletionHandler = { ok, msg in
                if ok {
                    Task { @MainActor in
                        MoveUndo.record(originalPaths: paths, dstDir: dstDir)
                    }
                }
                onDone(ok, msg)
            }
            pwc.cancelHandle = TransferService.move(
                rsyncPath: rsync, sources: paths, dstDir: dstDir,
                overwrite: overwrite, onProgress: onProgress, onDone: recordingDone)
        } else {
            pwc.cancelHandle = TransferService.copy(
                rsyncPath: rsync, sources: paths, dstDir: dstDir,
                overwrite: overwrite, onProgress: onProgress, onDone: onDone)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Delete
    // ─────────────────────────────────────────────────────────────────────────

    @IBAction func deleteSelected(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }

        // Check if the volume supports Trash by looking at the volume root.
        // Boot volume (/) always supports trash. External volumes need .Trashes.
        var volumeSupportsTrash = true
        let testURL = URL(fileURLWithPath: paths[0])
        if let volumeURL = try? testURL.resourceValues(forKeys: [.volumeURLKey]).volume,
           volumeURL.path != "/" {
            let trashes = volumeURL.appendingPathComponent(".Trashes").path
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: trashes, isDirectory: &isDir) || !isDir.boolValue {
                volumeSupportsTrash = false
            }
        }

        if volumeSupportsTrash {
            confirmTrashDelete(paths)
        } else {
            confirmPermanentDelete(paths)
        }
    }

    private func confirmTrashDelete(_ paths: [String]) {
        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? L10n.f("trash.confirmOne", "Move \"%@\" to the Trash?",
                     (paths[0] as NSString).lastPathComponent)
            : L10n.f("trash.confirmMany", "Move %d items to the Trash?", paths.count)
        alert.addButton(withTitle: L10n.t("action.moveToTrash", "Move to Trash"))
        alert.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
        alert.alertStyle = .warning
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            for path in paths {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path),
                                                      resultingItemURL: nil)
                } catch {
                    // Trash failed — fall back to offering permanent deletion
                    confirmPermanentDelete(paths)
                    return
                }
            }
            loadPath(currentPath)
        }
    }

    private func confirmPermanentDelete(_ paths: [String]) {
        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? L10n.f("delete.confirmOne", "\"%@\" will be deleted permanently.",
                     (paths[0] as NSString).lastPathComponent)
            : L10n.f("delete.confirmMany", "%d items will be deleted permanently.",
                     paths.count)
        alert.informativeText = L10n.t("delete.body", "This volume has no Trash. This action cannot be undone.")
        alert.addButton(withTitle: L10n.t("button.delete", "Delete"))
        alert.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
        alert.alertStyle = .critical
        // Make the Delete button visually destructive
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            if let error = FileService.deleteFiles(paths: paths) {
                showErrorMessage(error)
            }
            loadPath(currentPath)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Archive actions
    // ─────────────────────────────────────────────────────────────────────────

    /// Extensions the bundled 7zz can extract (from `7zz i`, filtered to
    /// archive-like formats a user would actually right-click — executables,
    /// disk images the OS mounts, and zip-based document formats like .docx
    /// are deliberately excluded). Drives Extract in the context menu.
    /// "001" covers the split volumes this app itself creates.
    static let extractableExtensions: Set<String> = [
        "7z", "zip", "zipx", "rar", "r00", "tar", "tgz", "tbz", "tbz2",
        "txz", "taz", "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "z",
        "lzh", "lha", "arj", "cab", "iso", "cpio", "rpm", "deb", "wim",
        "xar", "pkg", "001",
    ]

    /// Formats that are already compressed — splitting these uses -mx0
    /// (store only) since re-compressing buys nothing.
    static let compressedExtensions: Set<String> = [
        "7z", "zip", "zipx", "rar", "tar", "tgz", "tbz", "tbz2", "txz",
        "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "z",
    ]

    @IBAction func compressSelected(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }

        // Archive name: based on the first selected item
        let baseName = ((paths[0] as NSString).lastPathComponent as NSString).deletingPathExtension
        let archive = (currentPath as NSString).appendingPathComponent(baseName + ".7z")

        guard let sevenzz = Self.sevenzzPath else {
            showErrorMessage(L10n.t("error.7zzMissing", "7zz binary not found"))
            return
        }

        let pwc = makeProgressWindow(title: L10n.t("progress.compressing", "Compressing"), destination: currentPath)
        let (onProgress, onDone) = progressHandlers(pwc)
        pwc.cancelHandle = ArchiveService.compress(
            sevenzzPath: sevenzz, sources: paths, archivePath: archive,
            onProgress: onProgress, onDone: onDone)
    }

    @IBAction func splitSelected(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }

        guard let sevenzz = Self.sevenzzPath else {
            showErrorMessage(L10n.t("error.7zzMissing", "7zz binary not found"))
            return
        }

        // Input panel asking for the part size in MB
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = L10n.t("split.placeholder", "e.g. 100")
        field.font = .systemFont(ofSize: 13)
        field.stringValue = "100"

        let alert = NSAlert()
        alert.messageText = L10n.t("action.splitIntoParts", "Split into Parts")
        alert.informativeText = L10n.t("split.prompt", "Size of each part in MB:")
        alert.addButton(withTitle: L10n.t("button.split", "Split"))
        alert.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
        alert.accessoryView = field

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }

            let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sizeMB = Int(input), sizeMB > 0 else {
                showErrorMessage(L10n.t("split.invalid", "Size must be a number greater than 0"))
                return
            }

            // Detect if all selected files are already compressed archives
            let storeOnly = paths.allSatisfy {
                Self.compressedExtensions.contains(($0 as NSString).pathExtension.lowercased())
            }

            let baseName = ((paths[0] as NSString).lastPathComponent as NSString).deletingPathExtension
            let archive = (currentPath as NSString).appendingPathComponent(baseName + ".7z")

            let pwc = makeProgressWindow(title: L10n.t("progress.splitting", "Splitting"), destination: currentPath)
            let (onProgress, onDone) = progressHandlers(pwc)
            pwc.cancelHandle = ArchiveService.compress(
                sevenzzPath: sevenzz, sources: paths, archivePath: archive,
                volumeSizeMB: UInt32(sizeMB), storeOnly: storeOnly,
                onProgress: onProgress, onDone: onDone)
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
        }
    }

    @IBAction func uncompressSelected(_ sender: Any?) {
        // Selection-based (not outlineView rows) so it works from the icon
        // and column views too.
        guard let archivePath = selectedPaths().first else { return }

        guard let sevenzz = Self.sevenzzPath else {
            showErrorMessage(L10n.t("error.7zzMissing", "7zz binary not found"))
            return
        }

        // Extract to a folder with the archive's base name; split volumes
        // (x.7z.001) shed both extensions.
        var baseName = ((archivePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        if (archivePath as NSString).pathExtension == "001" {
            baseName = (baseName as NSString).deletingPathExtension
        }
        let dstDir = (currentPath as NSString).appendingPathComponent(baseName)

        let pwc = makeProgressWindow(title: L10n.t("progress.extracting", "Extracting"), destination: currentPath)
        let (onProgress, onDone) = progressHandlers(pwc)
        pwc.cancelHandle = ArchiveService.uncompress(
            sevenzzPath: sevenzz, archivePath: archivePath, dstDir: dstDir,
            onProgress: onProgress, onDone: onDone)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Bundled binaries
    // ─────────────────────────────────────────────────────────────────────────

    private static func bundledBinary(_ name: String) -> String? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourcePath {
            let bundled = (resources as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: bundled) { return bundled }
        }
        // Development fallback (swift run / bare .build binaries): walk up
        // from the executable looking for the repo's bin/<name>. The binary
        // sits at .build/<config>/ or .build/<triple>/<config>/ depending on
        // how it was launched, so a fixed ../.. is not reliable.
        if let exePath = Bundle.main.executablePath {
            var dir = URL(fileURLWithPath: exePath)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("bin/\(name)").path
                if fm.isExecutableFile(atPath: candidate) { return candidate }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }

    static var sevenzzPath: String? { bundledBinary("7zz") }
    static var rsyncPath: String? { bundledBinary("rsync") }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Helpers
    // ─────────────────────────────────────────────────────────────────────────

    func showErrorMessage(_ msg: String?) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = msg ?? L10n.t("error.operationFailed", "Operation failed")
        alert.alertStyle = .critical
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func formattedSize(_ bytes: UInt64) -> String {
        let v = Double(bytes)
        if v < 1024 { return String(format: "%.0f B", v) }
        if v < 1_048_576 { return String(format: "%.1f KB", v / 1024.0) }
        if v < 1_073_741_824 { return String(format: "%.1f MB", v / 1_048_576.0) }
        return String(format: "%.2f GB", v / 1_073_741_824.0)
    }

    func formattedDate(_ unix: Int64) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Localized Kind column text.
    ///
    /// Resolved from the filename extension, cached, because the previous
    /// `resourceValues(forKeys: [.contentTypeKey])` hit the filesystem once per
    /// visible row on every redraw — a per-row round-trip on a network volume.
    /// Extensionless files still need the file itself to say what it is.
    func kind(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension
        if !ext.isEmpty {
            let key = ext.lowercased()
            if let cached = Self.kindCache[key] { return cached }
            if let description = UTType(filenameExtension: ext)?.localizedDescription {
                Self.kindCache[key] = description
                return description
            }
        }
        if let type = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.contentTypeKey]).contentType,
           let description = type.localizedDescription {
            return description
        }
        let upper = ext.uppercased()
        return upper.isEmpty
            ? L10n.t("kind.file", "File")
            : L10n.f("kind.fileWithExtension", "%@ File", upper)
    }

    private static var kindCache: [String: String] = [:]
}
