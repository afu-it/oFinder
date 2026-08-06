// HoverButton.swift
// A borderless button that shows a background under the pointer.

import AppKit

/// A borderless icon button that fills a soft rounded background while the
/// pointer is over it.
///
/// Without it a bare glyph gives no sign it can be clicked until you try —
/// the hover fill is the only affordance a borderless button has.
final class HoverButton: NSButton {

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    init(symbol: String, pointSize: CGFloat, accessibilityDescription: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imageScaling = .scaleProportionallyDown
        title = ""
        // The glyph is sized independently of the button, so the target can
        // stay comfortably clickable while the mark itself stays small.
        image = NSImage(systemSymbolName: symbol,
                        accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            // .inVisibleRect keeps the area correct as tabs are added, removed
            // and reordered underneath it, without recomputing rects by hand.
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Hovering a button on a tab that then goes away would otherwise leave
    /// the highlight stuck on whatever view is recycled into its place.
    override func viewDidHide() { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.secondaryLabelColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}
