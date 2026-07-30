// FileViewController.swift
// Port of FileViewController.m (core half): view construction, FSEvents
// monitoring, data loading, clipboard/transfer/archive actions.
// The view datasources/delegates, drag & drop, Quick Look, context menus and
// inline rename live in FileViewController+Views.swift.

import AppKit
import CoreServices
import Quartz
import R2FinderServices

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
                columnView.isHidden = false
                columnView.reload(fromPath: currentPath)
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

    // Loading
    private let loadQueue = DispatchQueue(label: "com.r2finder.dirload")
    // nonisolated(unsafe): mutated only on the main actor; the background
    // icon/listing loops read it as an advisory early-exit check, where a
    // stale value is harmless (the main-actor guard re-checks on delivery).
    private nonisolated(unsafe) var loadGeneration = 0
    private var isLoading = false

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
            ("name", "Nombre", 340),
            ("size", "Tamaño", 100),
            ("date", "Fecha de modificación", 180),
            ("kind", "Tipo", 120),
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

    private func startWatching(path: String) {
        stopWatching()
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let vc = Unmanaged<FileViewController>.fromOpaque(info).takeUnretainedValue()
            // Events are delivered on the main queue (SetDispatchQueue below).
            MainActor.assumeIsolated {
                vc.scheduleReload()
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
        if pathChanged { startWatching(path: path) }

        // On navigation, blank the view immediately so the user sees they've
        // moved. On in-place refresh (FSEvents), keep the existing entries on
        // screen so the UI doesn't flicker through "Cargando…" every time
        // rsync deletes a file.
        if pathChanged {
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
            let newEntries = Self.entriesList(forPath: path, showHidden: showHidden)

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

                self.entries = newEntries
                self.reloadAllViews()
                self.updateStatusBar()

                // Fill real icons in the background. icon(forFile:) can do
                // synchronous metadata I/O — on Samba shares this blocks the
                // main thread for hundreds of round-trips.
                self.fillIcons(for: newEntries, generation: thisGeneration)
            }
        }
    }

    /// Build FileEntry objects for a directory (no icons).
    nonisolated static func entriesList(forPath path: String, showHidden: Bool) -> [FileEntry] {
        guard let listed = DirectoryLister.list(path: path) else { return [] }
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
        if viewMode == .columns {
            columnView.reload(fromPath: currentPath)
        }
    }

    /// Reload the outline without losing the user's place. Reloads rebuild the
    /// FileEntry objects (and fire asynchronously — FSEvents, icon fill-in,
    /// clipboard changes), so a plain reloadData() would collapse every
    /// expanded folder and drop the selection mid-interaction. Expansion and
    /// selection are snapshotted and restored by path.
    private func reloadOutlinePreservingState() {
        var expandedPaths: [String] = []
        var selectedPathSet = Set<String>()
        for row in 0..<outlineView.numberOfRows {
            guard let e = outlineView.item(atRow: row) as? FileEntry else { continue }
            if outlineView.isItemExpanded(e) { expandedPaths.append(e.path) }
            if outlineView.selectedRowIndexes.contains(row) { selectedPathSet.insert(e.path) }
        }

        outlineView.reloadData()
        guard !expandedPaths.isEmpty || !selectedPathSet.isEmpty else { return }

        // Re-expand parents before children so nested rows materialize.
        for path in expandedPaths.sorted(by: { $0.count < $1.count }) {
            for row in 0..<outlineView.numberOfRows {
                if let e = outlineView.item(atRow: row) as? FileEntry, e.path == path {
                    outlineView.expandItem(e)
                    break
                }
            }
        }

        var indexes = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let e = outlineView.item(atRow: row) as? FileEntry,
               selectedPathSet.contains(e.path) {
                indexes.insert(row)
            }
        }
        if !indexes.isEmpty {
            outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    func updateStatusBar() {
        if isLoading {
            statusLabel.stringValue = "Cargando…"
            return
        }
        let folders = entries.lazy.filter(\.isDir).count
        let files = entries.count - folders
        statusLabel.stringValue = "\(folders) carpeta\(folders == 1 ? "" : "s"), "
            + "\(files) archivo\(files == 1 ? "" : "s")"
    }

    /// Synchronous children loading for outline-view expansion.
    func loadChildren(for entry: FileEntry) {
        guard !entry.childrenLoaded else { return }
        entry.childrenLoaded = true
        entry.children = Self.entriesList(forPath: entry.path, showHidden: Self.showHidden)
        let ws = NSWorkspace.shared
        for fe in entry.children {
            let icon = ws.icon(forFile: fe.path)
            icon.size = NSSize(width: 16, height: 16)
            fe.icon = icon
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Public API
    // ─────────────────────────────────────────────────────────────────────────

    func createNewFolder(inPath path: String) {
        let alert = NSAlert()
        alert.messageText = "Nueva carpeta"
        alert.informativeText = "Nombre de la nueva carpeta:"
        alert.addButton(withTitle: "Crear")
        alert.addButton(withTitle: "Cancelar")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "Carpeta sin titulo"
        input.stringValue = "Carpeta sin titulo"
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

    @IBAction func copySelected(_ sender: Any?) {
        FileClipboard.set(selectedPaths(), operation: .copy)
    }

    @IBAction func cutSelected(_ sender: Any?) {
        FileClipboard.set(selectedPaths(), operation: .cut)
    }

    @IBAction func pasteHere(_ sender: Any?) {
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

    func performTransfer(fromPaths paths: [String], toDir dstDir: String, isMove: Bool) {
        if FileService.checkCollision(sources: paths, dstDir: dstDir) {
            let alert = NSAlert()
            alert.messageText = "Ya existe un elemento con ese nombre"
            alert.informativeText = "Deseas reemplazar los archivos existentes?"
            alert.addButton(withTitle: "Reemplazar")
            alert.addButton(withTitle: "Cancelar")
            alert.addButton(withTitle: "Mantener ambos")
            let resp = alert.runModal()
            if resp == .alertSecondButtonReturn { return }
            startTransfer(paths: paths, dstDir: dstDir,
                          overwrite: resp == .alertFirstButtonReturn, isMove: isMove)
        } else {
            startTransfer(paths: paths, dstDir: dstDir, overwrite: false, isMove: isMove)
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
            showErrorMessage("No se encontró el binario rsync")
            return
        }
        let pwc = makeProgressWindow(title: isMove ? "Moviendo" : "Copiando", destination: dstDir)
        let (onProgress, onDone) = progressHandlers(pwc)
        if isMove {
            TransferService.move(rsyncPath: rsync, sources: paths, dstDir: dstDir,
                                 overwrite: overwrite, onProgress: onProgress, onDone: onDone)
        } else {
            TransferService.copy(rsyncPath: rsync, sources: paths, dstDir: dstDir,
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
            ? "Mover \"\((paths[0] as NSString).lastPathComponent)\" a la papelera?"
            : "Mover \(paths.count) elementos a la papelera?"
        alert.addButton(withTitle: "Mover a la papelera")
        alert.addButton(withTitle: "Cancelar")
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
            ? "\"\((paths[0] as NSString).lastPathComponent)\" se eliminará permanentemente."
            : "\(paths.count) elementos se eliminarán permanentemente."
        alert.informativeText = "Este volumen no tiene papelera. Esta acción no se puede deshacer."
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        alert.alertStyle = .critical
        // Make the "Eliminar" button visually destructive
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
    /// are deliberately excluded). Drives "Descomprimir" in the context menu.
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
            showErrorMessage("No se encontró el binario 7zz")
            return
        }

        let pwc = makeProgressWindow(title: "Comprimiendo", destination: currentPath)
        let (onProgress, onDone) = progressHandlers(pwc)
        ArchiveService.compress(sevenzzPath: sevenzz, sources: paths, archivePath: archive,
                                onProgress: onProgress, onDone: onDone)
    }

    @IBAction func splitSelected(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }

        guard let sevenzz = Self.sevenzzPath else {
            showErrorMessage("No se encontró el binario 7zz")
            return
        }

        // Input panel asking for the part size in MB
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Ej: 100"
        field.font = .systemFont(ofSize: 13)
        field.stringValue = "100"

        let alert = NSAlert()
        alert.messageText = "Dividir en partes"
        alert.informativeText = "Tamaño de cada parte en MB:"
        alert.addButton(withTitle: "Dividir")
        alert.addButton(withTitle: "Cancelar")
        alert.accessoryView = field

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }

            let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sizeMB = Int(input), sizeMB > 0 else {
                showErrorMessage("El tamaño debe ser un número mayor que 0")
                return
            }

            // Detect if all selected files are already compressed archives
            let storeOnly = paths.allSatisfy {
                Self.compressedExtensions.contains(($0 as NSString).pathExtension.lowercased())
            }

            let baseName = ((paths[0] as NSString).lastPathComponent as NSString).deletingPathExtension
            let archive = (currentPath as NSString).appendingPathComponent(baseName + ".7z")

            let pwc = makeProgressWindow(title: "Dividiendo", destination: currentPath)
            let (onProgress, onDone) = progressHandlers(pwc)
            ArchiveService.compress(sevenzzPath: sevenzz, sources: paths, archivePath: archive,
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
            showErrorMessage("No se encontró el binario 7zz")
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

        let pwc = makeProgressWindow(title: "Descomprimiendo", destination: currentPath)
        let (onProgress, onDone) = progressHandlers(pwc)
        ArchiveService.uncompress(sevenzzPath: sevenzz, archivePath: archivePath, dstDir: dstDir,
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
        alert.informativeText = msg ?? "Operacion fallida"
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

    func kind(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let description = type.localizedDescription {
            return description
        }
        let ext = (path as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "Archivo" : "Archivo \(ext)"
    }
}
