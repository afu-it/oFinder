// TabItemView.swift
// One tab in the strip.

import AppKit

@MainActor
protocol TabItemViewDelegate: AnyObject {
    func tabItemClicked(_ item: TabItemView)
    func tabItemCloseClicked(_ item: TabItemView)
    func tabItem(_ item: TabItemView, draggedTo pointInBar: NSPoint)
}

final class TabItemView: NSView {

    weak var delegate: TabItemViewDelegate?
    var index = 0

    private let label = NSTextField(labelWithString: "")
    private let closeButton: HoverButton
    private let isSelected: Bool

    /// Distance the pointer must travel before a press counts as a drag.
    /// Without it, the small movement inside an ordinary click reorders tabs
    /// by accident.
    private static let dragThreshold: CGFloat = 4

    init(title: String, isSelected: Bool, showsClose: Bool) {
        self.isSelected = isSelected
        closeButton = HoverButton(
            symbol: "xmark", pointSize: 8,
            accessibilityDescription: L10n.t("tab.close", "Close Tab"))
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = !showsClose
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            // The title gives way before the close button does: a truncated
            // name is still usable, a half-drawn close target is not.
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor,
                                            constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        layer?.backgroundColor = isSelected
            ? NSColor.controlBackgroundColor.cgColor
            : NSColor.windowBackgroundColor.cgColor
    }

    @objc private func closeClicked() {
        delegate?.tabItemCloseClicked(self)
    }

    // ── Click and drag ──────────────────────────────────────────────────────

    private var pressOrigin: NSPoint?
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        didDrag = false
        // Select on press, not on release: the tab should light up under the
        // finger, and a drag that follows is a reorder of an already-current
        // tab rather than a jump at the end of it.
        delegate?.tabItemClicked(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin else { return }
        if !didDrag,
           abs(event.locationInWindow.x - origin.x) < Self.dragThreshold {
            return
        }
        didDrag = true
        guard let bar = superview?.superview else { return }
        delegate?.tabItem(self, draggedTo: bar.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
        didDrag = false
    }
}
