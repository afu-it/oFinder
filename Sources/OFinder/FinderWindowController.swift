// FinderWindowController.swift
// Window + toolbar, hosting the sidebar and one or two browsing panes.
//
// The window owns no browsing state of its own. Path and history belong to a
// tab, tabs belong to a pane, and the window only knows which pane is active —
// which is what lets the same toolbar drive either half of a split.

import AppKit
import OFinderServices

final class FinderWindowController: NSWindowController, NSToolbarDelegate,
                                    NSMenuItemValidation,
                                    SidebarViewControllerDelegate,
                                    PathBarViewDelegate,
                                    PaneViewControllerDelegate {

    private var splitVC = NSSplitViewController()
    private let sidebarVC = SidebarViewController()

    private var panes: [PaneViewController] = []
    private var activePaneIndex = 0

    // Toolbar items
    private var navControl: NSSegmentedControl?      // back / forward segments
    private var viewModeControl: NSSegmentedControl?
    private var pathBar: PathBarView?
    private var newFolderItem: NSToolbarItem?

    private var sideButtonMonitor: Any?

    private var activePane: PaneViewController { panes[activePaneIndex] }
    private var fileVC: FileViewController { activePane.fileVC }
    var isSplit: Bool { panes.count > 1 }


    init(path: String) {
        // Wide enough that the list view shows every column through Size
        // (sidebar + Name 340 + Date 180 + Type 120 + Size 100 + chrome).
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered,
                           defer: false)
        win.title = "oFinder"
        win.minSize = NSSize(width: 640, height: 400)
        win.center()

        super.init(window: win)

        // NSWindowController ignores the window's frame autosave while
        // shouldCascadeWindows (its default) is on — nothing ever gets saved.
        shouldCascadeWindows = false

        panes = [makePane(path: path)]
        setupToolbar()
        setupContent()

        // Assigning contentViewController (in setupContent) resizes the window
        // to the split view's fitting size — Auto Layout collapses that to the
        // 640-wide minimum, silently discarding the frame above. Restore the
        // intended frame afterwards. Autosave must live on the *controller*
        // (windowFrameAutosaveName) — a name set on the window itself is
        // ignored under NSWindowController and never saves anything. Setting
        // it also restores the saved frame; when nothing was saved yet, fall
        // back to the wide first-run default.
        windowFrameAutosaveName = "oFinderMainWindow"
        if !win.setFrameUsingName("oFinderMainWindow") {
            win.setContentSize(NSSize(width: 1200, height: 700))
            win.center()
        }

        locationChanged()
        watchForSideButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }


    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(addToSidebar(_:)):
            return !sidebarCandidates().isEmpty
        case #selector(createNewFolder(_:)):
            return !RecentsService.isRecents(fileVC.currentPath)
        case #selector(closeTab(_:)):
            return true
        case #selector(openInNewTab(_:)), #selector(openInNewSplit(_:)):
            return fileVC.selectedPaths().contains(where: Self.isDirectory)
        case #selector(toggleSplit(_:)):
            item.title = isSplit
                ? L10n.t("view.mergePanes", "Merge Panels")
                : L10n.t("view.splitPane", "Split Panel")
            return true
        case #selector(focusOtherPane(_:)):
            return isSplit
        case #selector(goBack(_:)):
            return activePane.activeTab.history.canGoBack
        case #selector(goForward(_:)):
            return activePane.activeTab.history.canGoForward
        default:
            return true
        }
    }

    // ───────────────────────────────────────────────
    // MARK: – Toolbar
    // ───────────────────────────────────────────────

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "OFinderToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        // Flexible spaces only centre an item within the space left over, so
        // the wider group on the right pushed the path bar off the window's
        // real centre. This pins it to the window.
        toolbar.centeredItemIdentifiers = [.init("PathLabel")]
        window?.toolbar = toolbar
        window?.titlebarAppearsTransparent = false
        // The title said the folder's name and the path label said its path —
        // two readings of the same thing competing for the middle of the
        // titlebar. The label keeps the job; the title is still set, so the
        // Window menu and Mission Control still name the window properly.
        window?.titleVisibility = .hidden
    }

    // ───────────────────────────────────────────────
    // MARK: – Content
    // ───────────────────────────────────────────────

    private func makePane(path: String) -> PaneViewController {
        let pane = PaneViewController(path: path)
        pane.delegate = self
        return pane
    }

    private func setupContent() {
        sidebarVC.delegate = self

        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 280
        splitVC.addSplitViewItem(sideItem)

        let contentItem = NSSplitViewItem(viewController: panes[0])
        contentItem.minimumThickness = 300
        splitVC.addSplitViewItem(contentItem)

        panes[0].isActive = true
        window?.contentViewController = splitVC
    }

    // ───────────────────────────────────────────────
    // MARK: – Panes
    // ───────────────────────────────────────────────

    @IBAction func toggleSplit(_ sender: Any?) {
        isSplit ? mergePanes() : splitPane()
    }

    private func splitPane(adopting tab: BrowserTab? = nil, onLeft: Bool = false) {
        guard !isSplit else { return }
        // Without a tab to carry over, the new pane opens where the current one
        // is looking. Starting it at home would throw away the context the
        // split was opened for — the usual reason to split is to move
        // something out of here.
        let pane: PaneViewController
        if let tab {
            pane = PaneViewController(adopting: tab)
            pane.delegate = self
        } else {
            pane = makePane(path: activePane.activeTab.currentPath)
        }

        let item = NSSplitViewItem(viewController: pane)
        item.minimumThickness = 250
        // Split view item 0 is the sidebar, so the content panes start at 1.
        if onLeft {
            panes.insert(pane, at: 0)
            splitVC.insertSplitViewItem(item, at: 1)
        } else {
            panes.append(pane)
            splitVC.addSplitViewItem(item)
        }

        for pane in panes {
            pane.showsActiveBorder = true
            pane.allowsClosingLastTab = true
        }
        setActivePane(panes.firstIndex(where: { $0 === pane }) ?? 0)
    }

    /// Removes a named pane. Callers say which one goes rather than which one
    /// stays: closing a pane's last tab has to discard *that* pane, and a
    /// "keep the active one" rule discards the healthy half instead.
    private func closePane(_ pane: PaneViewController) {
        guard isSplit, let index = panes.firstIndex(where: { $0 === pane }) else { return }
        if let item = splitVC.splitViewItems.first(where: { $0.viewController === pane }) {
            splitVC.removeSplitViewItem(item)
        }
        panes.remove(at: index)
        for pane in panes {
            pane.showsActiveBorder = false
            pane.allowsClosingLastTab = false
        }
        setActivePane(0)
    }

    private func mergePanes() {
        guard isSplit else { return }
        // Merging from the menu keeps what the user is looking at.
        closePane(panes[activePaneIndex == 0 ? 1 : 0])
    }

    @IBAction func focusOtherPane(_ sender: Any?) {
        guard isSplit else { return }
        setActivePane(activePaneIndex == 0 ? 1 : 0)
    }

    private func setActivePane(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        activePaneIndex = index
        for (i, pane) in panes.enumerated() { pane.isActive = i == index }
        locationChanged()
    }

    // ───────────────────────────────────────────────
    // MARK: – Tabs
    // ───────────────────────────────────────────────

    @IBAction func newTab(_ sender: Any?) {
        activePane.addTab(path: activePane.activeTab.currentPath)
    }

    @IBAction func closeTab(_ sender: Any?) {
        // closeTab reports back through paneDidCloseLastTab when it is the
        // pane's last, which collapses the split or closes the window.
        activePane.closeTab(at: activePane.activeIndex)
    }

    /// Opens the selected folders as tabs. Several selected folders open
    /// several tabs, and the last one wins the selection — the same thing that
    /// happens if you open them one at a time.
    @IBAction func openInNewTab(_ sender: Any?) {
        let folders = fileVC.selectedPaths().filter(Self.isDirectory)
        guard !folders.isEmpty else { return }
        for folder in folders { activePane.addTab(path: folder) }
    }

    func openInNewTab(path: String) {
        activePane.addTab(path: path)
    }

    /// Opens folders in the other half of the window, splitting first if there
    /// is no other half yet.
    @IBAction func openInNewSplit(_ sender: Any?) {
        openInNewSplit(paths: fileVC.selectedPaths().filter(Self.isDirectory))
    }

    func openInNewSplit(paths: [String]) {
        guard let first = paths.first else { return }
        if isSplit {
            let other = activePaneIndex == 0 ? 1 : 0
            panes[other].addTab(path: first)
            setActivePane(other)
        } else {
            // splitPane leaves the new pane active, which is where the
            // remaining folders below should land.
            splitPane(adopting: BrowserTab(path: first))
        }
        // A window has two halves, so extra folders stack up as tabs in the
        // one just opened rather than splitting further.
        for path in paths.dropFirst() { activePane.addTab(path: path) }
    }

    @IBAction func selectNextTab(_ sender: Any?) {
        activePane.selectNextTab()
    }

    @IBAction func selectPreviousTab(_ sender: Any?) {
        activePane.selectNextTab(reverse: true)
    }

    /// Cmd+1…9. The ninth shortcut selects the last tab rather than the ninth,
    /// matching browsers: with six tabs open, Cmd+9 should still go somewhere.
    @IBAction func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let number = Int(item.keyEquivalent) else { return }
        let index = number == 9 ? activePane.tabs.count - 1 : number - 1
        activePane.select(index: index)
    }

    // ───────────────────────────────────────────────
    // MARK: – Navigation
    // ───────────────────────────────────────────────

    func navigateToPath(_ path: String) {
        activePane.navigate(to: path)
    }

    @IBAction func goBack(_ sender: Any?) { activePane.goBack() }
    @IBAction func goForward(_ sender: Any?) { activePane.goForward() }

    // ───────────────────────────────────────────────
    // MARK: – Mouse side buttons
    // ───────────────────────────────────────────────

    /// What macOS reports for the two thumb buttons on a multi-button mouse.
    /// AppKit names the first three buttons and stops, so these are literals.
    private enum SideButton {
        static let back = 3
        static let forward = 4
    }

    /// Watches for the thumb buttons.
    ///
    /// A monitor rather than an `otherMouseDown` override: an override only
    /// fires if the event survives every view it passes on the way up the
    /// responder chain, and the outline, icon and column views are each free
    /// to swallow it. The monitor sees the event before any of them do.
    private func watchForSideButtons() {
        sideButtonMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) {
            [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.buttonNumber {
            case SideButton.back:
                self.navigateFromMouse(at: event.locationInWindow) { $0.goBack() }
            case SideButton.forward:
                self.navigateFromMouse(at: event.locationInWindow) { $0.goForward() }
            default:
                return event
            }
            // Swallowed: a view receiving this afterwards would read it as a
            // stray click on whatever row sits under the pointer.
            return nil
        }

        // The window's close retires the monitor rather than deinit, which is
        // nonisolated and so cannot touch the (non-Sendable) monitor token.
        NotificationCenter.default.addObserver(
            self, selector: #selector(retireSideButtonMonitor),
            name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func retireSideButtonMonitor() {
        guard let sideButtonMonitor else { return }
        NSEvent.removeMonitor(sideButtonMonitor)
        self.sideButtonMonitor = nil
    }

    /// Moves the pane under the pointer rather than whichever one happens to
    /// be active. In a split, pressing back over the other half should move
    /// that half, the same as any ordinary click there would.
    private func navigateFromMouse(at pointInWindow: NSPoint,
                                   _ move: (PaneViewController) -> Void) {
        if let index = paneIndex(at: pointInWindow), index != activePaneIndex {
            setActivePane(index)
        }
        move(activePane)
    }

    private func paneIndex(at pointInWindow: NSPoint) -> Int? {
        panes.firstIndex { pane in
            // isViewLoaded rather than viewIfLoaded: the latter needs macOS 14
            // and this app supports 13. Touching .view unconditionally would
            // force a load just to hit-test.
            guard pane.isViewLoaded else { return false }
            let view = pane.view
            return view.bounds.contains(view.convert(pointInWindow, from: nil))
        }
    }

    /// Pushes the active pane's location out to everything that mirrors it.
    private func locationChanged() {
        let path = activePane.activeTab.currentPath
        let title = activePane.activeTab.title
        window?.title = title
        pathBar?.show(path: path)
        sidebarVC.highlightPath(path)
        viewModeControl?.selectedSegment = fileVC.viewMode.rawValue
        if let newFolderItem { applyNewFolderRole(to: newFolderItem) }
        navControl?.setEnabled(activePane.activeTab.history.canGoBack, forSegment: 0)
        navControl?.setEnabled(activePane.activeTab.history.canGoForward, forSegment: 1)
    }

    // ───────────────────────────────────────────────
    // MARK: – NSToolbarDelegate
    // ───────────────────────────────────────────────

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Navigation on the left, the location in the middle, and the two
        // controls that act on the view itself gathered in the right corner.
        [.init("BackForward"), .flexibleSpace,
         .init("PathLabel"), .flexibleSpace,
         .init("NewFolder"), .init("ViewMode")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier.rawValue {
        case "BackForward":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            // .momentary: each click ALWAYS fires the action with a valid
            // selectedSegment (0 or 1). No toggle confusion.
            let control = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L10n.t("toolbar.back", "Back"))!,
                    NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L10n.t("toolbar.forward", "Forward"))!,
                ],
                trackingMode: .momentary,
                target: self,
                action: #selector(backForwardAction(_:)))
            control.segmentStyle = .separated
            control.setEnabled(false, forSegment: 0)
            control.setEnabled(false, forSegment: 1)
            navControl = control
            item.view = control
            return item

        case "ViewMode":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let control = NSSegmentedControl()
            control.segmentCount = 3
            control.trackingMode = .selectOne
            control.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: L10n.t("toolbar.icons", "Icons")), forSegment: 0)
            control.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: L10n.t("toolbar.list", "List")), forSegment: 1)
            control.setImage(NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: L10n.t("toolbar.columns", "Columns")), forSegment: 2)
            control.selectedSegment = 1
            control.target = self
            control.action = #selector(viewModeAction(_:))
            control.sizeToFit()
            viewModeControl = control
            item.view = control
            return item

        case "PathLabel":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let bar = PathBarView(frame: .zero)
            bar.delegate = self
            bar.translatesAutoresizingMaskIntoConstraints = false
            // No size constraints at all: the bar reports both from its
            // contents. A fixed height fought the toolbar row's own height and
            // left the text riding above the middle of the capsule.
            pathBar = bar
            item.view = bar
            return item

        case "NewFolder":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            newFolderItem = item
            applyNewFolderRole(to: item)
            return item

        default:
            return nil
        }
    }

    @IBAction func viewModeAction(_ seg: NSSegmentedControl) {
        fileVC.viewMode = FileViewMode(rawValue: seg.selectedSegment) ?? .list
    }

    @IBAction func backForwardAction(_ seg: NSSegmentedControl) {
        if seg.selectedSegment == 0 { goBack(seg) } else { goForward(seg) }
    }

    /// The same toolbar slot is New Folder everywhere except in the Trash,
    /// where creating a folder makes no sense and emptying it is the only
    /// thing anyone comes here to do.
    private func applyNewFolderRole(to item: NSToolbarItem) {
        if TrashService.isTrash(fileVC.currentPath) {
            item.image = NSImage(systemSymbolName: "trash.slash",
                                 accessibilityDescription: L10n.t("action.emptyTrash", "Empty Trash"))
            item.label = L10n.t("action.emptyTrash", "Empty Trash")
            item.toolTip = item.label
            item.action = #selector(emptyTrash(_:))
        } else {
            item.image = NSImage(systemSymbolName: "folder.badge.plus",
                                 accessibilityDescription: L10n.t("action.newFolder", "New Folder"))
            item.label = L10n.t("action.newFolder", "New Folder")
            item.toolTip = item.label
            item.action = #selector(createNewFolder(_:))
        }
    }

    @IBAction func emptyTrash(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.t("trash.emptyTitle",
                                   "Permanently erase the items in the Trash?")
        alert.informativeText = L10n.t("trash.emptyBody",
                                       "You can't undo this action.")
        alert.addButton(withTitle: L10n.t("action.emptyTrash", "Empty Trash"))
        alert.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Asks Finder rather than deleting the files here. Reading ~/.Trash
        // needs Full Disk Access and deleting from it needs the same; Finder
        // already has both, and it also handles locked items and the
        // per-volume .Trashes folders that a plain removeItem loop would miss.
        let script = NSAppleScript(source: "tell application \"Finder\" to empty the trash")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)

        if let error {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = L10n.t("trash.emptyFailed", "Couldn't empty the Trash")
            failure.informativeText = (error[NSAppleScript.errorMessage] as? String)
                ?? L10n.t("progress.unknownError", "Unknown error")
            failure.addButton(withTitle: L10n.t("button.ok", "OK"))
            failure.runModal()
            return
        }
        activePane.fileVC.loadPath(TrashService.path)
    }

    @IBAction func createNewFolder(_ sender: Any?) {
        let current = fileVC.currentPath
        // Recents is a query result, not a place a folder can be created in.
        guard !current.isEmpty, !RecentsService.isRecents(current) else { return }
        fileVC.createNewFolder(inPath: current)
    }

    @IBAction func addToSidebar(_ sender: Any?) {
        let targets = sidebarCandidates()
        guard !targets.isEmpty else { return }
        var changed = false
        for path in targets where FavoritesStore.add(path: path) { changed = true }
        if changed { sidebarVC.reloadFavorites() }
    }

    /// Selected folders, or the folder being viewed when nothing is selected —
    /// the same fallback Finder uses, so ⌘⌃T always has something to act on.
    private func sidebarCandidates() -> [String] {
        let selected = fileVC.selectedPaths().filter(Self.isDirectory)
        if !selected.isEmpty { return selected }
        let current = fileVC.currentPath
        guard !current.isEmpty, !RecentsService.isRecents(current),
              Self.isDirectory(current) else { return [] }
        return [current]
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }

    @IBAction func goToFolderAction(_ sender: Any?) {
        GoToFolderPanel.runAsSheet(on: window) { [weak self] path in
            if let path { self?.navigateToPath(path) }
        }
    }

    // ───────────────────────────────────────────────
    // MARK: – PathBarViewDelegate
    // ───────────────────────────────────────────────

    func pathBar(_ bar: PathBarView, didChoose path: String) {
        activePane.navigate(to: path)
    }

    // ───────────────────────────────────────────────
    // MARK: – SidebarViewControllerDelegate
    // ───────────────────────────────────────────────

    func sidebar(_ sidebar: SidebarViewController, didSelectPath path: String) {
        activePane.navigate(to: path)
    }

    func sidebar(_ sidebar: SidebarViewController, openInNewTab path: String) {
        openInNewTab(path: path)
    }

    func sidebar(_ sidebar: SidebarViewController, openInNewSplit path: String) {
        openInNewSplit(paths: [path])
    }

    func sidebar(_ sidebar: SidebarViewController,
                 dropFilePaths paths: [String], toDir dstDir: String, isMove: Bool) {
        fileVC.performTransfer(fromPaths: paths, toDir: dstDir, isMove: isMove)
    }

    // ───────────────────────────────────────────────
    // MARK: – PaneViewControllerDelegate
    // ───────────────────────────────────────────────

    func paneDidChangeLocation(_ pane: PaneViewController) {
        guard pane === activePane else { return }
        locationChanged()
    }

    func paneDidBecomeActive(_ pane: PaneViewController) {
        guard let index = panes.firstIndex(where: { $0 === pane }),
              index != activePaneIndex else { return }
        setActivePane(index)
    }

    /// Dragging a tab off the side of a pane splits the window and takes the
    /// tab with it; when the window is already split, it hands the tab to the
    /// other side.
    func pane(_ pane: PaneViewController, didDragTab index: Int, toEdge edge: NSRectEdge) {
        guard let source = panes.firstIndex(where: { $0 === pane }) else { return }

        if isSplit {
            let destination = source == 0 ? 1 : 0
            // Only when the drag heads away from the destination's own side is
            // it a move; dragging left in the left pane means nothing.
            let wantsRight = edge == .maxX
            guard (destination == 1) == wantsRight else { return }
            guard let tab = pane.detachTab(at: index) else { return }
            panes[destination].adopt(tab)
            setActivePane(destination)
            return
        }

        // A pane holding a single tab has nothing to give away: splitting and
        // emptying it would leave half the window blank. Split anyway — the
        // gesture plainly means "two panes" — just without moving anything.
        let tab = pane.tabs.count > 1 ? pane.detachTab(at: index) : nil
        splitPane(adopting: tab, onLeft: edge == .minX)
    }

    func paneDidCloseLastTab(_ pane: PaneViewController) {
        // The pane that ran out of tabs is the one that goes; with no split to
        // collapse into, the window closes instead.
        if isSplit {
            closePane(pane)
        } else {
            window?.performClose(nil)
        }
    }
}
