// SidebarViewController.swift
// Port of SidebarViewController.m: favourites / volumes / network source list.
//
// Network discovery still uses NSNetServiceBrowser (deprecated) exactly like
// the ObjC version did — migrating to NWBrowser is a separate, bisectable
// change (see SWIFT_MIGRATION.md, "Not in scope").

import AppKit
import Darwin
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
    let networkHostname: String?  // non-nil for network hosts
    /// Set for mounted volumes. Read once when the section is built rather
    /// than per redraw: it is a statfs call, and the number moves slowly.
    var capacity: VolumeCapacity?
    var children: [SidebarItem] = []

    init(header title: String) {
        name = title
        path = nil
        icon = nil
        isHeader = true
        networkHostname = nil
    }

    init(name: String, path: String, icon: NSImage?) {
        self.name = name
        self.path = path
        self.icon = icon
        isHeader = false
        networkHostname = nil
    }

    init(networkHost name: String, hostname: String, icon: NSImage?) {
        self.name = name
        path = nil
        self.icon = icon
        isHeader = false
        networkHostname = hostname
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SidebarViewController
// ─────────────────────────────────────────────────────────────────────────────

final class SidebarViewController: NSViewController, NSOutlineViewDataSource,
                                   NSOutlineViewDelegate,
                                   NSMenuDelegate,
                                   @preconcurrency NetServiceBrowserDelegate,
                                   @preconcurrency NetServiceDelegate {

    weak var delegate: SidebarViewControllerDelegate?

    private var scrollView = NSScrollView()
    private var outlineView = NSOutlineView()
    private var sections: [SidebarItem] = []
    /// Set while highlightPath() is executing a programmatic selection so that
    /// outlineViewSelectionDidChange doesn't call back into the delegate (and
    /// hence pushPath) for a selection change we initiated ourselves.
    private var isHighlighting = false

    // Network discovery
    // nonisolated(unsafe): only assigned on the main actor; deinit
    // (nonisolated) needs to stop it.
    private nonisolated(unsafe) var smbBrowser: NetServiceBrowser?
    private var discoveredServices: [NetService] = []
    private var networkHeader = SidebarItem(header: L10n.t("sidebar.network", "NETWORK"))

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
        smbBrowser?.stop()
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

        // ── Devices / Volumes ─────────────────────────────────────────────
        let volHeader = SidebarItem(header: L10n.t("sidebar.devices", "DEVICES"))
        volumesSection = volHeader
        populateVolumes(volHeader)
        sections.append(volHeader)

        // ── Network ───────────────────────────────────────────────────────
        networkHeader = SidebarItem(header: L10n.t("sidebar.network", "NETWORK"))
        sections.append(networkHeader)
        startNetworkDiscovery()
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
    // MARK: – Network discovery
    // ─────────────────────────────────────────────────────────────────────────

    private func startNetworkDiscovery() {
        discoveredServices = []

        // 1) Bonjour – finds servers that advertise via mDNS/Avahi
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_smb._tcp.", inDomain: "")
        smbBrowser = browser

        // 2) Port scan – finds SMB servers that don't advertise via Bonjour
        scanSubnetForSMB()
    }

    // ─── Bonjour delegate ────────────────────────────────────────────────────

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        discoveredServices.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService, moreComing: Bool) {
        discoveredServices.removeAll { $0 == service }
        networkHeader.children.removeAll { $0.name == service.name }
        if !moreComing {
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
        }
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        var hostname = service.hostName ?? service.name
        if hostname.hasSuffix(".") { hostname.removeLast() }
        addNetworkHost(name: service.name, hostname: hostname)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        addNetworkHost(name: sender.name, hostname: sender.name)
    }

    // ─── Subnet scan for port 445 (SMB) ──────────────────────────────────────

    private func scanSubnetForSMB() {
        DispatchQueue.global().async { [weak self] in
            // Get local IPv4 addresses and their netmasks
            var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&ifaddrsPtr) == 0 else { return }
            defer { freeifaddrs(ifaddrsPtr) }

            var ifa = ifaddrsPtr
            while let cur = ifa {
                defer { ifa = cur.pointee.ifa_next }
                guard let addrPtr = cur.pointee.ifa_addr,
                      addrPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
                let flags = Int32(cur.pointee.ifa_flags)
                // Skip loopback; must be up and running
                if flags & IFF_LOOPBACK != 0 { continue }
                if flags & IFF_UP == 0 || flags & IFF_RUNNING == 0 { continue }

                let ip = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                guard let maskPtr = cur.pointee.ifa_netmask else { continue }
                let net = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                let base = ip & net
                let bcast = base | ~net
                // Limit scan to /24 or smaller to avoid flooding large subnets
                let range = min(bcast - base, 254)

                let group = DispatchGroup()
                let queue = DispatchQueue(label: "smb.scan", attributes: .concurrent)

                for i in 1...max(range, 1) where base + i != ip { // skip self
                    let target = base + i
                    queue.async(group: group) { [weak self] in
                        self?.probeSMB(atIP: target)
                    }
                }

                _ = group.wait(timeout: .now() + 5)
            }
        }
    }

    /// Decode a NUL-terminated CChar buffer (replacement for the deprecated
    /// `String(cString: [CChar])` overload).
    nonisolated private static func string(fromCChars chars: [CChar]) -> String {
        let bytes = chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated private func probeSMB(atIP ip: UInt32) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // Set non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(445).bigEndian
        addr.sin_addr.s_addr = ip.bigEndian

        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Wait up to 300ms for connection (poll ≡ the old select() wait)
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 300) > 0 else { return }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard err == 0 else { return }

        // Port 445 is open – resolve hostname
        var sa = sockaddr_in()
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr.s_addr = ip.bigEndian

        var ipChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sa.sin_addr, &ipChars, socklen_t(INET_ADDRSTRLEN))
        let ipStr = Self.string(fromCChars: ipChars)

        var hostChars = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let resolved = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &hostChars, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
            }
        }

        let displayName: String
        let hostname: String
        if resolved == 0 {
            // Got a DNS name – strip the domain suffix for display
            // (e.g. "server.local" → "server")
            let fullName = Self.string(fromCChars: hostChars)
            displayName = fullName.components(separatedBy: ".").first ?? fullName
            hostname = fullName
        } else {
            // No reverse DNS – use IP address
            displayName = ipStr
            hostname = ipStr
        }

        Task { @MainActor in
            self.addNetworkHost(name: displayName, hostname: hostname)
        }
    }

    // ─── Common helper ───────────────────────────────────────────────────────

    private func addNetworkHost(name: String, hostname: String) {
        // Avoid duplicates
        guard !networkHeader.children.contains(where: { $0.networkHostname == hostname }) else {
            return
        }
        let icon = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.networkName)
        networkHeader.children.append(SidebarItem(networkHost: name, hostname: hostname, icon: icon))
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    private func connectToNetworkHost(_ item: SidebarItem) {
        // Open smb://hostname – macOS handles authentication and mounting.
        // Once mounted the volume appears in /Volumes and our NSWorkspace
        // mount notification refreshes DISPOSITIVOS automatically.
        guard let hostname = item.networkHostname,
              let url = URL(string: "smb://\(hostname)") else { return }
        NSWorkspace.shared.open(url)
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
        (item as? SidebarItem)?.capacity != nil ? 42 : ov.rowHeight
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
        (item as? SidebarItem)?.isHeader == false
    }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let si = item as? SidebarItem else { return nil }

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

        if item.networkHostname != nil {
            connectToNetworkHost(item)
            return
        }
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
