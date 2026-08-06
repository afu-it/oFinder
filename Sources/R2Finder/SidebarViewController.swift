// SidebarViewController.swift
// Port of SidebarViewController.m: the favourites / cloud / volumes source list.

import AppKit
import R2FinderServices

@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelectPath path: String)
    func sidebar(_ sidebar: SidebarViewController,
                 dropFilePaths paths: [String], toDir dstDir: String, isMove: Bool)
    func sidebar(_ sidebar: SidebarViewController, openInNewTab path: String)
    func sidebar(_ sidebar: SidebarViewController, openInNewSplit path: String)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Internal model
// ─────────────────────────────────────────────────────────────────────────────

private final class SidebarItem {
    let name: String
    let path: String?
    let icon: NSImage?
    let isHeader: Bool
    /// Set for mounted volumes. Read once when the section is built rather
    /// than per redraw: it is a statfs call, and the number moves slowly.
    var capacity: VolumeCapacity?
    var children: [SidebarItem] = []

    /// Height of a blank separating row, or nil for a real entry.
    var spacerHeight: CGFloat?

    /// A gap, not a destination. Trash sits below the volumes and reads as one
    /// more of them when it butts up against the list; the space is what says
    /// it is something else.
    init(spacerHeight: CGFloat) {
        name = ""
        path = nil
        icon = nil
        isHeader = false
        self.spacerHeight = spacerHeight
    }

    init(header title: String) {
        name = title
        path = nil
        icon = nil
        isHeader = true
    }

    init(name: String, path: String, icon: NSImage?) {
        self.name = name
        self.path = path
        self.icon = icon
        isHeader = false
    }

}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SidebarViewController
// ─────────────────────────────────────────────────────────────────────────────

final class SidebarViewController: NSViewController, NSOutlineViewDataSource,
                                   NSOutlineViewDelegate,
                                   NSMenuDelegate {

    weak var delegate: SidebarViewControllerDelegate?

    private var scrollView = NSScrollView()
    private var outlineView = NSOutlineView()
    private var sections: [SidebarItem] = []
    /// Set while highlightPath() is executing a programmatic selection so that
    /// outlineViewSelectionDidChange doesn't call back into the delegate (and
    /// hence pushPath) for a selection change we initiated ourselves.
    private var isHighlighting = false

    /// Parallel to the Favorites header's children — index i in one is index i
    /// in the other. Kept so a dragged row can be turned back into the entry
    /// it represents without threading the identifier through SidebarItem.
    private var favoriteEntries: [FavoritesStore.Entry] = []

    /// Held by reference rather than by index into `sections`. Recents sits
    /// above Favorites now, and section indices shift again the moment
    /// anything else is inserted.
    private var favoritesSection: SidebarItem?
    private var volumesSection: SidebarItem?

    /// Drag type for reordering favourites. Distinct from .fileURL so a row
    /// drag and a file drop can be told apart at the drop site.
    private static let favoriteDragType =
        NSPasteboard.PasteboardType("com.r2finder.favorite")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        view.wantsLayer = true

        outlineView = NSOutlineView(frame: view.bounds)
        outlineView.autoresizingMask = [.width, .height]
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 12
        outlineView.rowSizeStyle = .medium
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self

        // Drag destination – accept file drops onto sidebar items
        outlineView.registerForDraggedTypes([.fileURL, Self.favoriteDragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        outlineView.addTableColumn(col)

        scrollView = NSScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView

        view.addSubview(scrollView)

        buildSections()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)

        // Observe workspace notifications for volume mount/unmount
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)),
                           name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)),
                           name: NSWorkspace.didUnmountNotification, object: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Column autoresizing only distributes the *delta* when the table's
        // frame changes; it never reconciles an initial mismatch. The column
        // starts at AppKit's default 100pt inside a 200pt sidebar, so labels
        // stayed truncated by that 100pt no matter how wide the split was
        // dragged. Sizing the last column to fit closes the gap on every
        // layout pass.
        outlineView.sizeLastColumnToFit()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // ─────────────
    // Build model
    // ─────────────

    private func buildSections() {
        sections = []

        // ── Recents ───────────────────────────────────────────────────────
        // A headerless row above everything else. Recents is a query, not a
        // place: it cannot be reordered against real folders, removed, or
        // dropped onto, so living inside Favorites promised behaviour it does
        // not have.
        sections.append(SidebarItem(
            name: L10n.t("sidebar.recents", "Recents"),
            path: RecentsService.locationID,
            icon: NSImage(systemSymbolName: "clock",
                          accessibilityDescription: "recents")))

        // ── Favourites ────────────────────────────────────────────────────
        // Order comes from FavoritesStore so the user's arrangement survives
        // relaunch; the rows themselves are resolved fresh each time.
        let favHeader = SidebarItem(header: L10n.t("sidebar.favorites", "FAVORITES"))
        favoritesSection = favHeader
        let specialsByKey = Dictionary(
            uniqueKeysWithValues: VolumeService.specialDirs().compactMap { dir in
                dir.key.map { ($0, dir) }
            })

        favoriteEntries = FavoritesStore.entries()
        for entry in favoriteEntries {
            switch entry {
            case .special(let key):
                guard let dir = specialsByKey[key] else { continue }
                favHeader.children.append(SidebarItem(
                    name: L10n.t("sidebar.\(key)", dir.name), path: dir.path,
                    icon: iconForSpecialDir(key, defaultPath: dir.path)))
            case .custom(let path):
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 16, height: 16)
                favHeader.children.append(SidebarItem(
                    name: (path as NSString).lastPathComponent, path: path, icon: icon))
            }
        }
        sections.append(favHeader)

        // ── Cloud ─────────────────────────────────────────────────────────
        // Only when there is something in it: an empty CLOUD header is a
        // promise the machine cannot keep.
        let cloudLocations = CloudService.locations()
        if !cloudLocations.isEmpty {
            let cloudHeader = SidebarItem(header: L10n.t("sidebar.cloud", "CLOUD"))
            for location in cloudLocations {
                let symbol = location.key == "icloud" ? "icloud" : "cloud"
                cloudHeader.children.append(SidebarItem(
                    name: location.name, path: location.path,
                    icon: NSImage(systemSymbolName: symbol,
                                  accessibilityDescription: location.name)))
            }
            sections.append(cloudHeader)
        }

        // ── Devices / Volumes ─────────────────────────────────────────────
        let volHeader = SidebarItem(header: L10n.t("sidebar.devices", "DEVICES"))
        volumesSection = volHeader
        populateVolumes(volHeader)
        sections.append(volHeader)

        // ── Network ───────────────────────────────────────────────────────
        sections.append(SidebarItem(spacerHeight: 18))

        // ── Trash ─────────────────────────────────────────────────────────
        // Headerless and last, mirroring Recents at the top: both are single
        // destinations rather than groups, and Trash belongs at the end
        // because that is where everything else in the system puts it.
        sections.append(SidebarItem(
            name: L10n.t("sidebar.trash", "Trash"),
            path: NSHomeDirectory() + "/.Trash",
            icon: NSImage(systemSymbolName: "trash",
                          accessibilityDescription: "trash")))

    }

    private func populateVolumes(_ header: SidebarItem) {
        header.children.removeAll()

        // Always add Macintosh HD (root)
        let hddIcon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.computerName)
        let boot = SidebarItem(name: "Macintosh HD", path: "/", icon: hddIcon)
        boot.capacity = VolumeCapacity(path: "/")
        header.children.append(boot)

        for vol in VolumeService.volumes() {
            // Skip the symlink that points to /
            if vol.path == "/Volumes/Macintosh HD" { continue }
            let icon = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
                ?? NSImage(named: NSImage.multipleDocumentsName)
            let item = SidebarItem(name: vol.name, path: vol.path, icon: icon)
            item.capacity = VolumeCapacity(path: vol.path)
            header.children.append(item)
        }
    }

    /// Keyed by VolumeEntry.key, not by display name — the label is
    /// translated, the identifier is not.
    private static let specialDirSymbols: [String: String] = [
        "home": "house",
        "desktop": "desktopcomputer",
        "documents": "doc",
        "downloads": "arrow.down.circle",
        "music": "music.note",
        "pictures": "photo",
        "movies": "film",
        "applications": "square.grid.2x2",
    ]

    private func iconForSpecialDir(_ key: String, defaultPath path: String) -> NSImage {
        if let sym = Self.specialDirSymbols[key],
           let img = NSImage(systemSymbolName: sym, accessibilityDescription: key) {
            return img
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    // ─────────────
    // Volume changes
    // ─────────────

    @objc private func volumesChanged(_ note: Notification) {
        // NSWorkspace mount/unmount notifications are delivered on the main
        // thread; this @objc method is main-actor-isolated.
        guard let volumesSection else { return }
        populateVolumes(volumesSection)
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Public API
    // ─────────────────────────────────────────────────────────────────────────

    /// Highlight the sidebar row matching the given path (best-effort).
    func highlightPath(_ path: String) {
        isHighlighting = true
        defer { isHighlighting = false }

        // Find the sidebar item whose path is the longest prefix of the
        // navigated path, so "/" (Macintosh HD) doesn't win over more specific
        // mount-points like "/Volumes/SambaShare".
        var bestMatch: SidebarItem?
        var bestLen = 0

        for section in sections {
            for item in section.children {
                guard let itemPath = item.path else { continue }
                let len = itemPath.utf16.count
                guard len > bestLen, path.hasPrefix(itemPath) else { continue }
                // Ensure the prefix ends at a path boundary: either the prefix
                // is "/" itself, the prefix equals the full path, or the
                // character right after the prefix is '/'.
                let pathLen = path.utf16.count
                if len == 1 || len == pathLen
                    || path[path.index(path.startIndex, offsetBy: len)] == "/" {
                    bestMatch = item
                    bestLen = len
                }
            }
        }

        if let bestMatch {
            let row = outlineView.row(forItem: bestMatch)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            outlineView.deselectAll(nil)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – NSOutlineViewDataSource
    // ─────────────────────────────────────────────────────────────────────────

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let si = item as? SidebarItem else { return sections.count }
        return si.children.count
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let si = item as? SidebarItem else { return sections[index] }
        return si.children[index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.children.isEmpty == false
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – NSOutlineViewDelegate
    // ─────────────────────────────────────────────────────────────────────────

    /// Volume rows carry a capacity bar and a free-space line under the name,
    /// so they need more room than a plain row.
    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let si = item as? SidebarItem else { return ov.rowHeight }
        if let spacerHeight = si.spacerHeight { return spacerHeight }
        return si.capacity != nil ? 42 : ov.rowHeight
    }

    private func volumeCell(for si: SidebarItem, capacity: VolumeCapacity,
                            in ov: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("VolumeCell")
        let cell = ov.makeView(withIdentifier: identifier, owner: self) as? VolumeCellView
            ?? {
                let cell = VolumeCellView(frame: .zero)
                cell.identifier = identifier
                return cell
            }()
        cell.configure(name: si.name, icon: si.icon, capacity: capacity)
        return cell
    }

    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.isHeader ?? false
    }

    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let si = item as? SidebarItem else { return false }
        return !si.isHeader && si.spacerHeight == nil
    }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let si = item as? SidebarItem else { return nil }

        if si.spacerHeight != nil { return NSView() }

        if si.isHeader {
            let identifier = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = ov.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? {
                    let cell = NSTableCellView(frame: .zero)
                    cell.identifier = identifier
                    let tf = NSTextField(labelWithString: "")
                    tf.font = .systemFont(ofSize: 11, weight: .semibold)
                    tf.textColor = .tertiaryLabelColor
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(tf)
                    cell.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    return cell
                }()
            cell.textField?.stringValue = si.name
            return cell
        }

        if let capacity = si.capacity {
            return volumeCell(for: si, capacity: capacity, in: ov)
        }

        let identifier = NSUserInterfaceItemIdentifier("ItemCell")
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
                tf.font = .systemFont(ofSize: 13)
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                cell.addSubview(tf)
                cell.textField = tf

                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
        cell.textField?.stringValue = si.name
        let icon = si.icon ?? NSWorkspace.shared.icon(forFile: si.path ?? "/")
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if isHighlighting { return } // programmatic selection – don't push to history
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem,
              !item.isHeader else { return }

        guard let path = item.path else { return }
        delegate?.sidebar(self, didSelectPath: path)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Drag destination
    // ─────────────────────────────────────────────────────────────────────────

    /// Only favourite rows are draggable, and only to reorder themselves.
    func outlineView(_ ov: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let entry = favoriteEntry(for: item) else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(entry.id, forType: Self.favoriteDragType)
        return pbItem
    }

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Reordering: dropping between favourite rows, never onto one.
        if info.draggingPasteboard.availableType(from: [Self.favoriteDragType]) != nil {
            guard index >= 0, isFavoritesHeader(item) else { return [] }
            return .move
        }
        // Recents carries a path so it can be navigated to, but it is a query:
        // nothing can be dropped into it.
        guard let si = item as? SidebarItem, !si.isHeader, let path = si.path,
              !RecentsService.isRecents(path) else { return [] }
        if info.draggingSourceOperationMask.contains(.move) { return .move }
        return .copy
    }

    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        if let id = info.draggingPasteboard.string(forType: Self.favoriteDragType),
           let entry = FavoritesStore.Entry(id: id) {
            guard index >= 0, isFavoritesHeader(item) else { return false }
            FavoritesStore.move(entry, to: index)
            reloadFavorites()
            return true
        }

        guard let si = item as? SidebarItem, !si.isHeader, let dstDir = si.path,
              !RecentsService.isRecents(dstDir) else { return false }
        guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let isMove = info.draggingSourceOperationMask.contains(.move)
        delegate?.sidebar(self, dropFilePaths: urls.map(\.path), toDir: dstDir, isMove: isMove)
        return true
    }

    private func isFavoritesHeader(_ item: Any?) -> Bool {
        guard let si = item as? SidebarItem else { return false }
        return si === favoritesSection
    }

    private func favoriteEntry(for item: Any) -> FavoritesStore.Entry? {
        guard let si = item as? SidebarItem, !si.isHeader,
              let children = favoritesSection?.children,
              let idx = children.firstIndex(where: { $0 === si }),
              idx < favoriteEntries.count else { return nil }
        return favoriteEntries[idx]
    }

    // ─────────────
    // Context menu
    // ─────────────

    /// Any favourite can be removed, built-in ones included. A removed
    /// built-in is remembered as removed, and comes back by navigating to the
    /// folder and using Add to Sidebar.
    @objc private func openClickedInNewTab(_ sender: Any?) {
        guard let path = openTargetPath else { return }
        delegate?.sidebar(self, openInNewTab: path)
    }

    @objc private func copyClickedPath(_ sender: Any?) {
        guard let path = openTargetPath, !RecentsService.isRecents(path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func openClickedInNewSplit(_ sender: Any?) {
        guard let path = openTargetPath else { return }
        delegate?.sidebar(self, openInNewSplit: path)
    }

    /// Captured with the menu, like the eject and remove targets: clickedRow
    /// has reset to -1 by the time the item fires.
    private var openTargetPath: String?

    @objc private func removeClickedFavorite(_ sender: Any?) {
        guard let entry = removeTargetEntry else { return }
        FavoritesStore.remove(entry)
        reloadFavorites()
    }

    /// Captured while the menu is built. `clickedRow` has reset by the time
    /// the item fires, so reading it in the action removes the wrong row.
    private var removeTargetEntry: FavoritesStore.Entry?

    /// Whether this volume can be detached.
    ///
    /// The boot volume is excluded outright — it reports as removable on some
    /// Macs, and offering to eject the disk the system is running from is not
    /// a useful thing to be right about. Network mounts have no media to
    /// eject, but unmountAndEjectDevice unmounts them, which is what "eject"
    /// means for a share.
    private func isEjectable(_ path: String) -> Bool {
        guard path != "/" else { return false }
        let keys: Set<URLResourceKey> = [
            .volumeIsEjectableKey, .volumeIsRemovableKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey,
        ]
        guard let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: keys) else { return false }
        if values.volumeIsRootFileSystem == true { return false }
        return values.volumeIsEjectable == true
            || values.volumeIsRemovable == true
            || values.volumeIsLocal == false
    }

    /// The clicked row's path, but only if it is a volume row.
    private func clickedVolumePath() -> String? {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem,
              !item.isHeader, let path = item.path,
              volumesSection?.children.contains(where: { $0 === item }) == true
        else { return nil }
        return path
    }

    @objc private func ejectClickedVolume(_ sender: Any?) {
        guard let path = ejectTargetPath else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.f("eject.failed", "Couldn't eject “%@”.",
                                       (path as NSString).lastPathComponent)
            // The reason is nearly always "a file is open" and the system
            // message names the process, so it is worth surfacing verbatim.
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.t("button.ok", "OK"))
            alert.runModal()
        }
        // On success the workspace unmount notification rebuilds the section.
    }

    /// Captured when the menu is built: clickedRow is only valid during the
    /// click, and by the time the menu item fires it has reset to -1.
    private var ejectTargetPath: String?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        ejectTargetPath = nil
        removeTargetEntry = nil
        openTargetPath = nil

        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }

        // Anything with a location can be opened in a tab — favourites,
        // volumes and Recents alike. Network hosts have no path yet, so they
        // fall through to whatever else applies.
        if let si = item as? SidebarItem, !si.isHeader, let path = si.path {
            openTargetPath = path
            let open = menu.addItem(
                withTitle: L10n.t("action.openInNewTab", "Open in New Tab"),
                action: #selector(openClickedInNewTab(_:)), keyEquivalent: "")
            open.target = self

            let isSplit = (view.window?.windowController as? FinderWindowController)?
                .isSplit ?? false
            let split = menu.addItem(
                withTitle: isSplit
                    ? L10n.t("action.openInOtherPane", "Open in Other Panel")
                    : L10n.t("action.openInNewSplit", "Open in New Panel"),
                action: #selector(openClickedInNewSplit(_:)), keyEquivalent: "")
            split.target = self

            // Recents is a query, not a place, so there is no path worth
            // handing to a terminal.
            if !RecentsService.isRecents(path) {
                let copyPath = menu.addItem(
                    withTitle: L10n.t("action.copyAsPath", "Copy as Path"),
                    action: #selector(copyClickedPath(_:)), keyEquivalent: "")
                copyPath.target = self
            }
        }

        if let entry = favoriteEntry(for: item) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            removeTargetEntry = entry
            let remove = menu.addItem(
                withTitle: L10n.t("action.removeFromSidebar", "Remove from Sidebar"),
                action: #selector(removeClickedFavorite(_:)), keyEquivalent: "")
            remove.target = self
            return
        }

        if let path = clickedVolumePath(), isEjectable(path) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            ejectTargetPath = path
            let eject = menu.addItem(withTitle: L10n.t("action.eject", "Eject"),
                                     action: #selector(ejectClickedVolume(_:)),
                                     keyEquivalent: "")
            eject.target = self
        }
    }

    /// Rebuilds the sidebar and restores expansion, which reloadData drops.
    func reloadFavorites() {
        buildSections()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }
}
