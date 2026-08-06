// CapacityBarView.swift
// The thin used/free bar under a volume in the sidebar.

import AppKit

struct VolumeCapacity {
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double {
        total > 0 ? min(1, max(0, Double(used) / Double(total))) : 0
    }

    /// Reads capacity for a mount point, or nil if the volume does not report
    /// it — network shares and some disk images do not.
    init?(path: String) {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }

        // "Important usage" is what Finder reports: it counts space macOS
        // could reclaim by evicting purgeable files, so it matches the number
        // people see elsewhere. Not every filesystem provides it.
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)

        self.total = Int64(total)
        self.available = max(0, min(Int64(total), available))
    }
}

/// A rounded track with a fill, drawn rather than assembled from an
/// NSProgressIndicator: the indicator's bar has a fixed minimum height and its
/// own inset, both too large for a sidebar row.
final class CapacityBarView: NSView {

    /// Above this, the fill turns red. Running out of disk is the one thing
    /// this bar exists to warn about, and by the time it is visibly near the
    /// end it is often already a problem.
    private static let warningFraction = 0.9

    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2

        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard fraction > 0 else { return }
        // Never narrower than the track is tall, so a nearly-empty disk still
        // shows a dot instead of nothing.
        let width = max(bounds.height, bounds.width * CGFloat(fraction))
        let fill = NSRect(x: 0, y: 0, width: width, height: bounds.height)

        (fraction >= Self.warningFraction ? NSColor.systemRed
                                          : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
