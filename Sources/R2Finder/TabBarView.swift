// TabBarView.swift
// The strip of tabs above a pane's file view.

import AppKit

@MainActor
protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didClose index: Int)
    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int)
    func tabBar(_ bar: TabBarView, didDragTab index: Int, toEdge edge: NSRectEdge)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
}

/// A horizontal tab strip.
///
/// Hand-built rather than NSTabView: that control owns the child view
/// controllers and its tabs cannot be reordered by dragging, both of which are
/// the point here. This view is display only — it holds titles and an index,
/// never the panes themselves.
final class TabBarView: NSView {

    weak var delegate: TabBarViewDelegate?

    private(set) var titles: [String] = []
    private(set) var selectedIndex = 0
    /// One split per drag. Without this the pointer sitting near the edge
    /// fires on every mouse-moved event and the window splits repeatedly.
    private var edgeSignalled = false

    private let stack = NSStackView()
    private let addButton = HoverButton(
        symbol: "plus", pointSize: 10,
        accessibilityDescription: L10n.t("tab.new", "New Tab"))

    static let height: CGFloat = 28
    private static let minTabWidth: CGFloat = 50
    private static let maxTabWidth: CGFloat = 110
    /// How close to the pane's edge a dragged tab must get to mean "split
    /// here" rather than "reorder". Wide enough to be reachable without
    /// precision, narrow enough that dragging within a wide strip is safe.
    private static let edgeMargin: CGFloat = 60

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stack.orientation = .horizontal
        stack.spacing = 1
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        addButton.target = self
        addButton.action = #selector(newTabClicked)
        addSubview(addButton)

        // Hug the tabs so the strip ends where the last tab does, rather than
        // spreading them across the full width.
        stack.setHuggingPriority(.defaultHigh, for: .horizontal)

        let addTrailing = addButton.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -6)
        // Below required, so that with enough tabs to fill the strip the plus
        // slides off rather than the layout becoming unsatisfiable.
        addTrailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Sits just past the last tab rather than pinned to the far edge:
            // it belongs to the run of tabs, and a plus floating alone at the
            // right reads as a toolbar button for the whole window.
            addButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 4),
            addTrailing,
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 18),
            addButton.heightAnchor.constraint(equalToConstant: 18),

            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Hairline against the file view below.
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func setTabs(_ titles: [String], selected: Int) {
        self.titles = titles
        selectedIndex = selected

        // Reuse the existing tabs whenever the count is unchanged — a
        // selection change or a reorder must not replace the view a drag is
        // currently being delivered to. Only opening or closing a tab rebuilds.
        let items = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        guard items.count == titles.count else {
            rebuild()
            return
        }
        for (index, item) in items.enumerated() {
            item.index = index
            item.update(title: titles[index],
                        isSelected: index == selected,
                        showsClose: titles.count > 1)
        }
        needsDisplay = true
    }

    private func rebuild() {
        // A rebuild means the view that owned any in-flight drag is gone, so
        // its mouseUp will never arrive to clear this. Left set, the strip
        // would refuse every later edge drag.
        edgeSignalled = false
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, title) in titles.enumerated() {
            let item = TabItemView(title: title,
                                   isSelected: index == selectedIndex,
                                   // A lone tab has no close button: closing it
                                   // would mean closing the window, and a tab
                                   // strip that can empty itself is a trap.
                                   showsClose: titles.count > 1)
            item.index = index
            item.delegate = self
            item.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minTabWidth)
                .isActive = true
            item.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxTabWidth)
                .isActive = true
            stack.addArrangedSubview(item)
        }
        needsDisplay = true
    }

    @objc private func newTabClicked() {
        delegate?.tabBarDidRequestNewTab(self)
    }
}

extension TabBarView: TabItemViewDelegate {
    func tabItemClicked(_ item: TabItemView) {
        delegate?.tabBar(self, didSelect: item.index)
    }

    func tabItemCloseClicked(_ item: TabItemView) {
        delegate?.tabBar(self, didClose: item.index)
    }

    /// Reorder is resolved here, in view space, because the drop target is
    /// "which gap did the cursor land in" — a question only the strip can
    /// answer, and one the model has no business knowing about.
    ///
    /// A drag that leaves the strip and reaches the edge of the pane means
    /// something else entirely: split, and take this tab with you.
    func tabItem(_ item: TabItemView, draggedTo pointInBar: NSPoint) {
        let items = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        if let target = items.first(where: { $0.frame.contains(pointInBar) }) {
            guard target.index != item.index else { return }
            delegate?.tabBar(self, didMove: item.index, to: target.index)
            return
        }

        // The strip only spans its tabs, so edges are measured against the
        // pane it sits in — otherwise a drag just past the last tab would
        // count as reaching the far side of the window.
        guard !edgeSignalled, let host = superview else { return }
        let point = convert(pointInBar, to: host)
        if point.x > host.bounds.maxX - Self.edgeMargin {
            edgeSignalled = true
            delegate?.tabBar(self, didDragTab: item.index, toEdge: .maxX)
        } else if point.x < host.bounds.minX + Self.edgeMargin {
            edgeSignalled = true
            delegate?.tabBar(self, didDragTab: item.index, toEdge: .minX)
        }
    }

    func tabItemDragEnded(_ item: TabItemView) {
        edgeSignalled = false
    }
}
