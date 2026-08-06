// PaneViewController.swift
// One browsing pane: a tab strip over a file view.

import AppKit
import R2FinderServices

/// One tab's state: a file view and the back/forward stack that belongs to it.
///
/// The history lives here rather than on the window because it is per-tab.
/// Hanging it off the window was the assumption that made tabs impossible.
@MainActor
final class BrowserTab {
    let fileVC: FileViewController
    var history: NavigationHistory

    init(path: String) {
        fileVC = FileViewController(path: path)
        history = NavigationHistory(startingAt: path)
    }

    var currentPath: String { fileVC.currentPath }

    var title: String {
        if RecentsService.isRecents(currentPath) {
            return L10n.t("sidebar.recents", "Recents")
        }
        let last = (currentPath as NSString).lastPathComponent
        return last.isEmpty ? currentPath : last
    }
}

/// A border that cannot be clicked.
///
/// It sits above the file view purely as a marker; without this, hit-testing
/// would hand it every click meant for the rows underneath and the pane would
/// look responsive while doing nothing.
private final class PassthroughBox: NSBox {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
protocol PaneViewControllerDelegate: AnyObject {
    /// The pane's visible location changed — new tab, tab switch, navigation.
    func paneDidChangeLocation(_ pane: PaneViewController)
    /// The user interacted with this pane, so it should become the active one.
    func paneDidBecomeActive(_ pane: PaneViewController)
    /// The last tab was closed.
    func paneDidCloseLastTab(_ pane: PaneViewController)
    /// A tab was dragged past the pane's left or right edge.
    func pane(_ pane: PaneViewController, didDragTab index: Int, toEdge edge: NSRectEdge)
}

final class PaneViewController: NSViewController, TabBarViewDelegate,
                                FileViewControllerDelegate {

    weak var delegate: PaneViewControllerDelegate?

    private(set) var tabs: [BrowserTab] = []
    private(set) var activeIndex = 0

    private let tabBar = TabBarView()
    private let container = NSView()
    /// Drawn around the pane when there is more than one, so it is obvious
    /// which half the toolbar and sidebar are driving.
    private let activeBorder = PassthroughBox()

    var isActive = false {
        didSet { activeBorder.isHidden = !isActive || !showsActiveBorder }
    }

    /// Only meaningful when the window is split; a lone pane needs no marker.
    var showsActiveBorder = false {
        didSet { activeBorder.isHidden = !isActive || !showsActiveBorder }
    }

    var activeTab: BrowserTab { tabs[activeIndex] }
    var fileVC: FileViewController { activeTab.fileVC }

    init(path: String) {
        super.init(nibName: nil, bundle: nil)
        tabs = [BrowserTab(path: path)]
    }

    /// Starts the pane with a tab taken from somewhere else, so a tab dragged
    /// out to create a split carries its own history across instead of being
    /// re-opened from scratch.
    init(adopting tab: BrowserTab) {
        super.init(nibName: nil, bundle: nil)
        tabs = [tab]
    }

    /// Removes a tab and hands it over, or nil if it is the pane's last one —
    /// a pane with no tabs has nothing to draw and no location to report.
    func detachTab(at index: Int) -> BrowserTab? {
        guard tabs.count > 1, tabs.indices.contains(index) else { return nil }
        let tab = tabs[index]
        tab.fileVC.view.removeFromSuperview()
        tab.fileVC.removeFromParent()
        tabs.remove(at: index)
        select(index: min(index, tabs.count - 1))
        return tab
    }

    func adopt(_ tab: BrowserTab) {
        tabs.append(tab)
        select(index: tabs.count - 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))

        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        activeBorder.boxType = .custom
        activeBorder.borderWidth = 2
        activeBorder.borderColor = .controlAccentColor
        activeBorder.cornerRadius = 0
        activeBorder.fillColor = .clear
        activeBorder.isHidden = true
        activeBorder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activeBorder, positioned: .above, relativeTo: container)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),

            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activeBorder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            activeBorder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            activeBorder.topAnchor.constraint(equalTo: container.topAnchor),
            activeBorder.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        showActiveTabView()
        refreshTabBar()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Tabs
    // ─────────────────────────────────────────────────────────────────────────

    func addTab(path: String) {
        tabs.append(BrowserTab(path: path))
        select(index: tabs.count - 1)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard tabs.count > 1 else {
            delegate?.paneDidCloseLastTab(self)
            return
        }
        tabs[index].fileVC.view.removeFromSuperview()
        tabs[index].fileVC.removeFromParent()
        tabs.remove(at: index)
        // Land on the neighbour, the way every tabbed app does: closing the
        // last tab should not jump the selection back to the first one.
        select(index: min(index, tabs.count - 1))
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        showActiveTabView()
        refreshTabBar()
        delegate?.paneDidChangeLocation(self)
    }

    func selectNextTab(reverse: Bool = false) {
        guard tabs.count > 1 else { return }
        let step = reverse ? -1 : 1
        select(index: (activeIndex + step + tabs.count) % tabs.count)
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let moving = tabs.remove(at: from)
        tabs.insert(moving, at: to)
        // Follow the tab that moved rather than the position: the user is
        // dragging the thing they are looking at.
        activeIndex = to
        refreshTabBar()
    }

    private func showActiveTabView() {
        for child in children where child !== fileVC {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        let vc = fileVC
        vc.delegate = self
        guard vc.view.superview !== container else { return }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Set while the window is split: closing this pane's last tab is then a
    /// safe thing to offer, because the pane collapses instead of vanishing.
    var allowsClosingLastTab = false {
        didSet { refreshTabBar() }
    }

    func refreshTabBar() {
        tabBar.setTabs(tabs.map(\.title), selected: activeIndex,
                       canCloseLast: allowsClosingLastTab)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Navigation
    // ─────────────────────────────────────────────────────────────────────────

    func navigate(to path: String) {
        activeTab.history.push(path)
        fileVC.loadPath(path)
        refreshTabBar()
        delegate?.paneDidChangeLocation(self)
    }

    func goBack() {
        guard let path = activeTab.history.goBack() else { return }
        fileVC.loadPath(path)
        refreshTabBar()
        delegate?.paneDidChangeLocation(self)
    }

    func goForward() {
        guard let path = activeTab.history.goForward() else { return }
        fileVC.loadPath(path)
        refreshTabBar()
        delegate?.paneDidChangeLocation(self)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – TabBarViewDelegate
    // ─────────────────────────────────────────────────────────────────────────

    func tabBar(_ bar: TabBarView, didSelect index: Int) {
        delegate?.paneDidBecomeActive(self)
        select(index: index)
    }

    func tabBar(_ bar: TabBarView, didClose index: Int) {
        closeTab(at: index)
    }

    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int) {
        moveTab(from: from, to: to)
    }

    func tabBar(_ bar: TabBarView, didDragTab index: Int, toEdge edge: NSRectEdge) {
        delegate?.pane(self, didDragTab: index, toEdge: edge)
    }

    func tabBarDidRequestNewTab(_ bar: TabBarView) {
        delegate?.paneDidBecomeActive(self)
        addTab(path: NSHomeDirectory())
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – FileViewControllerDelegate
    // ─────────────────────────────────────────────────────────────────────────

    func fileViewController(_ vc: FileViewController, didNavigateToPath path: String) {
        // Record only. The file view has already loaded this path under its own
        // steam — calling navigate(to:) here would load it a second time.
        delegate?.paneDidBecomeActive(self)
        activeTab.history.push(path)
        refreshTabBar()
        delegate?.paneDidChangeLocation(self)
    }
}
