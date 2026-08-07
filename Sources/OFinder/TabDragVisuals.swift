// TabDragVisuals.swift
// The floating tab and the drop zone shown while dragging a tab.

import AppKit

/// Draws what a tab drag is doing: a copy of the tab under the pointer, and a
/// highlighted half of the pane when the drag has reached the edge that would
/// split it.
///
/// Both live in the window's content view rather than in the tab strip. The
/// strip is 28pt tall and clips; a tab dragged over the file list has to be
/// drawn above everything, and the drop zone covers half the pane.
@MainActor
final class TabDragVisuals {

    private weak var contentView: NSView?
    private var ghost: NSImageView?
    private var zone: NSView?

    /// Offset from the pointer to the ghost's origin, captured at the start so
    /// the tab stays under the same part of itself it was grabbed by, instead
    /// of jumping so its corner meets the pointer.
    private var grabOffset: NSPoint = .zero

    var isActive: Bool { ghost != nil }

    func begin(dragging item: NSView, at windowPoint: NSPoint) {
        guard let content = item.window?.contentView, !isActive else { return }
        contentView = content

        guard let rep = item.bitmapImageRepForCachingDisplay(in: item.bounds) else { return }
        item.cacheDisplay(in: item.bounds, to: rep)
        let image = NSImage(size: item.bounds.size)
        image.addRepresentation(rep)

        let view = NSImageView(frame: NSRect(origin: .zero, size: item.bounds.size))
        view.image = image
        view.imageScaling = .scaleNone
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.layer?.masksToBounds = false
        view.layer?.shadowOpacity = 0.3
        view.layer?.shadowRadius = 8
        view.layer?.shadowOffset = .zero
        view.alphaValue = 0.92

        let itemOriginInContent = item.convert(NSPoint.zero, to: content)
        let pointInContent = content.convert(windowPoint, from: nil)
        grabOffset = NSPoint(x: itemOriginInContent.x - pointInContent.x,
                             y: itemOriginInContent.y - pointInContent.y)

        content.addSubview(view)
        ghost = view
        move(to: windowPoint)
    }

    /// Follows the pointer, unless a drop zone is showing — then the ghost
    /// settles into it. That snap is the whole "magnet" feeling: the drag
    /// stops tracking the hand and commits to a destination.
    func update(to windowPoint: NSPoint, snappingTo zoneRect: NSRect?) {
        guard let ghost, let content = contentView else { return }
        if let zoneRect {
            showZone(zoneRect)
            let target = NSPoint(x: zoneRect.midX - ghost.frame.width / 2,
                                 y: zoneRect.midY - ghost.frame.height / 2)
            guard ghost.frame.origin != target else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                ghost.animator().setFrameOrigin(target)
            }
        } else {
            hideZone()
            let point = content.convert(windowPoint, from: nil)
            ghost.setFrameOrigin(NSPoint(x: point.x + grabOffset.x,
                                         y: point.y + grabOffset.y))
        }
    }

    func end() {
        ghost?.removeFromSuperview()
        ghost = nil
        hideZone()
        contentView = nil
    }

    private func move(to windowPoint: NSPoint) {
        update(to: windowPoint, snappingTo: nil)
    }

    private func showZone(_ rect: NSRect) {
        guard let content = contentView else { return }
        if let zone {
            zone.frame = rect
            return
        }
        let view = NSView(frame: rect)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.18).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 6
        // Below the ghost, so the tab being dragged stays on top of the
        // highlight it is being dropped into.
        content.addSubview(view, positioned: .below, relativeTo: ghost)
        zone = view
    }

    private func hideZone() {
        zone?.removeFromSuperview()
        zone = nil
    }
}
