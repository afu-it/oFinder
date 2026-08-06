// FileViewController+Views.swift
// Port of FileViewController.m (views half): outline/collection/browser
// datasources and delegates, context menus, inline rename, Get Info,
// drag & drop, and Quick Look.

import AppKit
import Quartz
import R2FinderServices
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – NSOutlineViewDataSource / Delegate (list view)
// ─────────────────────────────────────────────────────────────────────────────

extension FileViewController: NSOutlineViewDataSource, NSOutlineViewDelegate,
                              ContextMenuOutlineViewDelegate {

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let entry = item as? FileEntry else { return entries.count } // root
        guard entry.isDir else { return 0 }
        // Zero until the listing lands — loadChildren reloads the item then.
        // Listing a folder inline here blocks the main thread for the round-trip.
        loadChildren(for: entry)
        return entry.children.count
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        // Bounds-checked on purpose: AppKit can ask for a row it cached before
        // the model shrank (it materializes rows lazily inside itemAtRow:), and
        // an out-of-range subscript here is a hard trap that takes the app down.
        // A placeholder renders as a blank row until the pending reload lands.
        let siblings = (item as? FileEntry).map(\.children) ?? entries
        guard index >= 0, index < siblings.count else { return FileEntry() }
        return siblings[index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileEntry)?.isDir ?? false
    }

    func outlineView(_ ov: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sd = ov.sortDescriptors.first, let key = sd.key else { return }
        entries.sort { a, b in
            let ascending: Bool
            switch key {
            case "size": ascending = a.size < b.size
            case "date": ascending = a.mtime < b.mtime
            case "kind": ascending = !a.isDir && b.isDir
            default:
                ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return sd.ascending ? ascending : !ascending
        }
        ov.reloadData()
    }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? FileEntry, let ident = col?.identifier.rawValue else { return nil }

        if ident == "name" {
            let identifier = NSUserInterfaceItemIdentifier("NameCell")
            let cell = ov.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? {
                    let cell = NSTableCellView(frame: .zero)
                    cell.identifier = identifier
                    let iv = NSImageView(frame: .zero)
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    iv.imageScaling = .scaleProportionallyDown
                    cell.addSubview(iv)
                    cell.imageView = iv
                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    tf.lineBreakMode = .byTruncatingTail
                    cell.addSubview(tf)
                    cell.textField = tf
                    NSLayoutConstraint.activate([
                        iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 16),
                        iv.heightAnchor.constraint(equalToConstant: 16),
                        tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    return cell
                }()
            cell.textField?.stringValue = entry.name
            cell.imageView?.image = thumbnail(for: entry) ?? entry.icon
            cell.alphaValue = opacity(for: entry)
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("BasicCell")
        let cell = ov.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let cell = NSTableCellView(frame: .zero)
                cell.identifier = identifier
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                cell.addSubview(tf)
                cell.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
        switch ident {
        case "size":
            cell.textField?.stringValue = entry.isDir ? "-" : formattedSize(entry.size)
        case "date":
            cell.textField?.stringValue = formattedDate(entry.mtime)
        case "kind":
            cell.textField?.stringValue = entry.isDir ? L10n.t("kind.folder", "Folder")
                : (entry.isSymlink ? "Alias" : kind(forPath: entry.path))
        default:
            break
        }
        cell.alphaValue = opacity(for: entry)
        return cell
    }

    @IBAction func tableViewDoubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let entry = outlineView.item(atRow: row) as? FileEntry else { return }
        openEntry(entry)
    }

    // Keep the Quick Look panel in sync when the selection changes, and record
    // the selection so a reload can restore it (see reloadOutlinePreservingState).
    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !isRestoringOutlineState {
            selectedOutlinePaths = Set(outlineView.selectedRowIndexes.compactMap {
                (outlineView.item(atRow: $0) as? FileEntry)?.path
            })
        }
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    // Expansion is likewise tracked as it happens rather than read back from
    // the outline at reload time, when its rows and `entries` disagree.
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringOutlineState,
              let entry = notification.userInfo?["NSObject"] as? FileEntry else { return }
        expandedOutlinePaths.insert(entry.path)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringOutlineState,
              let entry = notification.userInfo?["NSObject"] as? FileEntry else { return }
        expandedOutlinePaths.remove(entry.path)
    }

    // ── Drag source ─────────────────────────────────────────────────────────

    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let entry = item as? FileEntry else { return nil }
        return NSURL(fileURLWithPath: entry.path)
    }

    // ── Drag destination ────────────────────────────────────────────────────

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let entry = item as? FileEntry, !entry.isDir { return [] }
        if info.draggingSourceOperationMask.contains(.move) { return .move }
        return .copy
    }

    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let dstDir = (item as? FileEntry)?.path ?? currentPath
        let isMove = info.draggingSourceOperationMask.contains(.move)
        performTransfer(fromPaths: urls.map(\.path), toDir: dstDir, isMove: isMove)
        return true
    }

    // ── Context menu ────────────────────────────────────────────────────────

    func contextMenu(forOutlineView ov: NSOutlineView, clickedRow row: Int) -> NSMenu? {
        let entry = row >= 0 ? ov.item(atRow: row) as? FileEntry : nil
        if row >= 0, !ov.selectedRowIndexes.contains(row) {
            ov.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenu(for: entry)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – NSDraggingSource
// ─────────────────────────────────────────────────────────────────────────────

extension FileViewController: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – NSCollectionView (icon view)
// ─────────────────────────────────────────────────────────────────────────────

extension FileViewController: NSCollectionViewDataSource, NSCollectionViewDelegate,
                              ContextMenuCollectionViewDelegate,
                              NSCollectionViewDelegateFlowLayout {

    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        guard indexPath.item < entries.count else { return NSSize(width: 90, height: 90) }
        let well = IconCollectionViewItem.wellWidth(for: entries[indexPath.item])
        // The label needs room even under a narrow portrait thumbnail, so the
        // cell never gets tighter than the old square did.
        return NSSize(width: max(well, 74) + 8, height: 90)
    }

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: .init("IconItem"), for: indexPath)
        let idx = indexPath.item
        if idx < entries.count {
            let entry = entries[idx]
            item.textField?.stringValue = entry.name
            if let thumb = thumbnail(for: entry) {
                // The well already matches the picture's aspect, so let it
                // fill — including scaling up a thumbnail smaller than 64pt.
                item.imageView?.imageScaling = .scaleProportionallyUpOrDown
                item.imageView?.image = thumb
            } else if let icon = entry.icon?.copy() as? NSImage {
                // Type icon while the thumbnail generates, or forever if the
                // file has no preview. Only scaled down: blowing a 16pt raster
                // up to 64 is what made these look washed out.
                icon.size = NSSize(width: IconCollectionViewItem.wellHeight,
                                   height: IconCollectionViewItem.wellHeight)
                item.imageView?.imageScaling = .scaleProportionallyDown
                item.imageView?.image = icon
            }
            (item as? IconCollectionViewItem)?
                .setWellWidth(IconCollectionViewItem.wellWidth(for: entry))
            item.view.alphaValue = opacity(for: entry)
        }
        return item
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    func contextMenu(forCollectionView cv: NSCollectionView, at point: NSPoint) -> NSMenu? {
        if let ip = cv.indexPathForItem(at: point) {
            if !cv.selectionIndexPaths.contains(ip) {
                cv.selectionIndexPaths = [ip]
            }
            let entry = ip.item < entries.count ? entries[ip.item] : nil
            return contextMenu(for: entry)
        }
        return contextMenu(for: nil)
    }

    func collectionViewDidDoubleClick(_ cv: NSCollectionView, at indexPath: IndexPath) {
        if indexPath.item < entries.count {
            openEntry(entries[indexPath.item])
        }
    }

    // ── Drag source ─────────────────────────────────────────────────────────

    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ cv: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let idx = indexPath.item
        guard idx < entries.count else { return nil }
        return NSURL(fileURLWithPath: entries[idx].path)
    }

    // ── Drag destination ────────────────────────────────────────────────────

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if info.draggingSourceOperationMask.contains(.move) { return .move }
        return .copy
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        var dstDir = currentPath
        if dropOperation == .on, indexPath.item < entries.count {
            let target = entries[indexPath.item]
            if target.isDir { dstDir = target.path }
        }
        let isMove = info.draggingSourceOperationMask.contains(.move)
        performTransfer(fromPaths: urls.map(\.path), toDir: dstDir, isMove: isMove)
        return true
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – MillerColumnViewDelegate (column view)
// ─────────────────────────────────────────────────────────────────────────────

extension FileViewController: MillerColumnViewDelegate {

    /// Entries for one column: folders first with localized ordering (matching
    /// the old NSBrowser-era behavior). Listing and icons run off-main — done
    /// inline, clicking a folder on an SMB share froze the UI for the round-trip.
    func columnView(_ v: MillerColumnView, entriesForPath path: String,
                    completion: @escaping @MainActor ([FileEntry]) -> Void) {
        loadColumnEntries(forPath: path, completion: completion)
    }

    func columnView(_ v: MillerColumnView, didSelectDirectory path: String) {
        setCurrentPathFromColumns(path)
        delegate?.fileViewController(self, didNavigateToPath: path)
        updateStatusBar()
    }

    func columnView(_ v: MillerColumnView, didSelectFileInDirectory path: String) {
        setCurrentPathFromColumns(path)
        updateStatusBar()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    func columnView(_ v: MillerColumnView, open entry: FileEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
    }

    func columnView(_ v: MillerColumnView, contextMenuFor entry: FileEntry?) -> NSMenu? {
        contextMenu(for: entry)
    }

    func columnView(_ v: MillerColumnView, dropPaths paths: [String],
                    toDir dstDir: String, isMove: Bool) {
        performTransfer(fromPaths: paths, toDir: dstDir, isMove: isMove)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Context menu + validation
// ─────────────────────────────────────────────────────────────────────────────

extension FileViewController: NSMenuDelegate, NSMenuItemValidation {

    /// How solid an entry should be drawn.
    ///
    /// Hidden items are shown faded once Show Hidden Files is on, so they read
    /// as "normally not here" without a separate badge or colour. Cut items
    /// fade further, and win when an entry is both — the clipboard state is
    /// the one the user is in the middle of acting on.
    func opacity(for entry: FileEntry) -> CGFloat {
        if FileClipboard.operation == .cut, FileClipboard.paths.contains(entry.path) {
            return 0.35
        }
        return entry.name.hasPrefix(".") ? 0.55 : 1.0
    }

    /// Cached thumbnail if ready; otherwise nil now and a redraw of just this
    /// row once QuickLook answers.
    ///
    /// Directories are skipped: QuickLook renders a folder as the folder icon,
    /// which is what the fallback already shows, at the cost of a generation
    /// request per folder.
    func thumbnail(for entry: FileEntry) -> NSImage? {
        guard !entry.isDir else { return nil }
        if let ready = entry.thumbnail { return ready }
        let image = ThumbnailService.shared.thumbnail(
            for: entry.path, mtime: entry.mtime) { [weak self, weak entry] image in
                guard let self, let entry else { return }
                entry.thumbnail = image
                self.redrawRow(for: entry)
            }
        entry.thumbnail = image
        return image
    }

    /// Refreshes a single row rather than the whole view: thumbnails arrive
    /// one at a time while scrolling, and a full reload per arrival would
    /// fight the user's scroll and drop the selection.
    private func redrawRow(for entry: FileEntry) {
        switch viewMode {
        case .icon:
            guard let idx = entries.firstIndex(where: { $0 === entry }) else { return }
            collectionView.reloadItems(at: [IndexPath(item: idx, section: 0)])
            scheduleIconLayoutRefresh()
        case .columns:
            columnView.redraw(entry: entry)
        default:
            let row = outlineView.row(forItem: entry)
            guard row >= 0 else { return }
            outlineView.reloadData(forRowIndexes: IndexSet(integer: row),
                                   columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
        }
    }

    /// Flow layout caches item sizes, so a newly-arrived thumbnail only
    /// changes the grid once metrics are invalidated. Arrivals come in bursts
    /// while scrolling and each invalidation re-measures the whole section, so
    /// they are coalesced into one pass per runloop turn.
    private func scheduleIconLayoutRefresh() {
        guard !iconLayoutRefreshScheduled else { return }
        iconLayoutRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.iconLayoutRefreshScheduled = false
            guard self.viewMode == .icon else { return }
            let context = NSCollectionViewFlowLayoutInvalidationContext()
            context.invalidateFlowLayoutDelegateMetrics = true
            self.collectionView.collectionViewLayout?.invalidateLayout(with: context)
        }
    }

    /// "New Split" only stays true until there is one. Once the window is
    /// already split the same command opens in the other half, and a menu that
    /// says otherwise is describing a window the user is not looking at.
    var splitActionTitle: String {
        let isSplit = (view.window?.windowController as? FinderWindowController)?
            .isSplit ?? false
        return isSplit
            ? L10n.t("action.openInOtherPane", "Open in Other Pane")
            : L10n.t("action.openInNewSplit", "Open in New Split")
    }

    func contextMenu(for entry: FileEntry?) -> NSMenu {
        let menu = NSMenu(title: "")

        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }

        if let entry {
            add(L10n.t("action.open", "Open"), #selector(openSelected(_:)))
            menu.addItem(.separator())
            add(L10n.t("action.copy", "Copy"), #selector(copySelected(_:)))
            add(L10n.t("action.cut", "Cut"), #selector(cutSelected(_:)))
            menu.addItem(.separator())
            add(L10n.t("action.rename", "Rename"), #selector(renameSelected(_:)))
            add(L10n.t("action.getInfo", "Get Info"), #selector(showInfoSelected(_:)))
            if entry.isDir {
                // target stays nil so the responder chain carries these up to
                // FinderWindowController, which owns the tabs and the sidebar.
                menu.addItem(withTitle: L10n.t("action.openInNewTab", "Open in New Tab"),
                             action: #selector(FinderWindowController.openInNewTab(_:)),
                             keyEquivalent: "")
                menu.addItem(withTitle: splitActionTitle,
                             action: #selector(FinderWindowController.openInNewSplit(_:)),
                             keyEquivalent: "")
                menu.addItem(withTitle: L10n.t("action.addToSidebar", "Add to Sidebar"),
                             action: #selector(FinderWindowController.addToSidebar(_:)),
                             keyEquivalent: "")
            }
            menu.addItem(.separator())
            // Compress / Uncompress
            let ext = (entry.path as NSString).pathExtension.lowercased()
            if !entry.isDir, Self.extractableExtensions.contains(ext) {
                add(L10n.t("action.extract", "Extract"), #selector(uncompressSelected(_:)))
            } else {
                add(L10n.t("action.compress", "Compress"), #selector(compressSelected(_:)))
            }
            add(L10n.t("action.splitIntoParts", "Split into Parts"), #selector(splitSelected(_:)))
            menu.addItem(.separator())
            add(L10n.t("action.moveToTrash", "Move to Trash"), #selector(deleteSelected(_:)))
            menu.addItem(.separator())
        }

        let paste = menu.addItem(withTitle: L10n.t("action.paste", "Paste"), action: #selector(pasteHere(_:)), keyEquivalent: "")
        paste.target = self
        paste.keyEquivalentModifierMask = []

        // AppKit hides this item and shows it in place of Paste while Option
        // is held. alternate = true + matching keyEquivalent is the standard
        // mechanism.
        let moveHere = menu.addItem(withTitle: L10n.t("action.moveHere", "Move Here"), action: #selector(moveHere(_:)), keyEquivalent: "")
        moveHere.target = self
        moveHere.isAlternate = true
        moveHere.keyEquivalentModifierMask = .option

        menu.delegate = self

        menu.addItem(.separator())
        add(L10n.t("action.newFolder", "New Folder"), #selector(newFolderAction(_:)))
        add(L10n.t("action.showHidden", "Show Hidden"), #selector(toggleHidden(_:)))
        return menu
    }

    // Proper enabled-state gate that respects autoenablesItems = true.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(pasteHere(_:)) || item.action == #selector(moveHere(_:)) {
            return !effectiveClipboardPaths().isEmpty
        }
        if item.action == #selector(undoLastMove(_:)) {
            return MoveUndo.available != nil
        }
        if item.action == #selector(toggleHidden(_:)) {
            item.title = Self.showHidden ? L10n.t("action.hideHiddenFiles", "Hide Hidden Files") : L10n.t("action.showHiddenFiles", "Show Hidden Files")
        }
        return true
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Inline rename
// ─────────────────────────────────────────────────────────────────────────────

extension FileViewController: NSTextFieldDelegate {

    @IBAction func renameSelected(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        renameRow = row
        // Delay activation so the window fully settles after context-menu dismiss.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.beginInlineRename()
        }
    }

    private func beginInlineRename() {
        guard renameRow >= 0 else { return }
        let nameCol = outlineView.column(withIdentifier: .init("name"))
        guard nameCol >= 0,
              let cell = outlineView.view(atColumn: nameCol, row: renameRow,
                                          makeIfNecessary: true) as? NSTableCellView,
              let tf = cell.textField else {
            renameRow = -1
            return
        }
        tf.isEditable = true
        tf.isSelectable = true
        tf.delegate = self
        // Use the outline view's own editing path to properly install the
        // field editor within the cell.
        outlineView.editColumn(nameCol, row: renameRow, with: nil, select: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard renameRow >= 0 else { return false }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            // Escape – cancel rename, restore original name
            let entry = outlineView.item(atRow: renameRow) as? FileEntry
            guard let tf = control as? NSTextField else { return false }
            tf.stringValue = entry?.name ?? ""
            tf.isEditable = false
            tf.isSelectable = false
            renameRow = -1
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard renameRow >= 0, let tf = note.object as? NSTextField else { return }
        let newName = tf.stringValue
        tf.isEditable = false
        tf.isSelectable = false
        let entry = outlineView.item(atRow: renameRow) as? FileEntry
        renameRow = -1
        guard let entry, !newName.isEmpty, newName != entry.name else { return }
        let newPath = ((entry.path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(newName)
        if let error = FileService.rename(src: entry.path, dst: newPath) {
            showErrorMessage(error)
        } else {
            loadPath(currentPath)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Get Info
// ─────────────────────────────────────────────────────────────────────────────

extension FileViewController {

    @IBAction func showInfoSelected(_ sender: Any?) {
        let paths = selectedPaths()
        guard let filePath = paths.first else { return }

        // Show info for the first selected item
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: filePath) else { return }

        let fileURL = URL(fileURLWithPath: filePath)
        let fileName = (filePath as NSString).lastPathComponent
        let isDir = attrs[.type] as? FileAttributeType == .typeDirectory

        // Kind
        let kindStr = isDir ? L10n.t("kind.folder", "Folder") : kind(forPath: filePath)

        // Size
        let sizeStr: String
        if isDir {
            // Calculate folder size recursively
            var totalSize: UInt64 = 0
            var fileCount = 0
            if let enumerator = fm.enumerator(at: fileURL,
                                              includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let url as URL in enumerator {
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          values.isRegularFile == true else { continue }
                    totalSize += UInt64(values.fileSize ?? 0)
                    fileCount += 1
                }
            }
            sizeStr = L10n.f("info.sizeWithFileCount", "%@ (%d files)",
                             formattedSize(totalSize), fileCount)
        } else {
            let bytes = (attrs[.size] as? UInt64) ?? 0
            sizeStr = "\(formattedSize(bytes)) (\(bytes) bytes)"
        }

        // Dates
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .medium
        let createdStr = (attrs[.creationDate] as? Date).map(df.string(from:)) ?? "-"
        let modifiedStr = (attrs[.modificationDate] as? Date).map(df.string(from:)) ?? "-"

        // Permissions
        let posix = (attrs[.posixPermissions] as? Int) ?? 0
        let bits: [(Int, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"),
                                        (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                        (0o004, "r"), (0o002, "w"), (0o001, "x")]
        let permsStr = String(bits.map { posix & $0.0 != 0 ? $0.1 : "-" })

        // Icon
        let icon = NSWorkspace.shared.icon(forFile: filePath)
        icon.size = NSSize(width: 64, height: 64)

        // Build the info panel
        let alert = NSAlert()
        alert.messageText = fileName
        alert.icon = icon
        alert.informativeText = """
            \(L10n.t("info.kind", "Kind")): \(kindStr)

            \(L10n.t("info.size", "Size")): \(sizeStr)

            \(L10n.t("info.location", "Location")): \((filePath as NSString).deletingLastPathComponent)

            \(L10n.t("info.created", "Created")): \(createdStr)

            \(L10n.t("info.modified", "Modified")): \(modifiedStr)

            \(L10n.t("info.permissions", "Permissions")): \(permsStr)
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L10n.t("action.revealInFinder", "Reveal in Finder"))

        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Quick Look (QLPreviewPanelController / DataSource / Delegate)
// ─────────────────────────────────────────────────────────────────────────────

extension FileViewController: @preconcurrency QLPreviewPanelDataSource,
                              @preconcurrency QLPreviewPanelDelegate {

    // AppKit asks each responder in the chain whether it can control the panel.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // These overrides are nonisolated (they come from an NSObject category),
    // but AppKit only invokes them on the main thread.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedPaths().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let sel = selectedPaths()
        guard index < sel.count else { return nil }
        return NSURL(fileURLWithPath: sel[index])
    }

    // Forward arrow keys to the file view so the user can navigate the list
    // while the preview panel is visible.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.specialKey {
        case .some(.upArrow), .some(.downArrow), .some(.leftArrow), .some(.rightArrow):
            let target: NSView
            switch viewMode {
            case .icon: target = collectionView
            case .columns: target = columnView.keyTarget ?? outlineView
            default: target = outlineView
            }
            target.keyDown(with: event)
            return true
        default:
            if event.characters == " " {
                panel.orderOut(nil)
                return true
            }
            return false
        }
    }
}
