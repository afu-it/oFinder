// ThumbnailService.swift
// Content thumbnails via QuickLook, generated on demand.

import AppKit
import QuickLookThumbnailing

/// Lazily produces a picture *of the file's contents*, as opposed to
/// `NSWorkspace.icon(forFile:)`, which returns the icon for the file's type —
/// the same PNG document badge for every image on disk.
///
/// Generation is on demand rather than up front: a folder can hold thousands
/// of files and only a screenful is ever visible, so thumbnails are requested
/// by the view that is about to draw one.
@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    /// Generated at a size that covers the icon view on a Retina display; the
    /// list view draws the same image into 16pt and AppKit downsamples.
    static let renderSize: CGFloat = 128

    private var cache: [String: NSImage] = [:]
    /// Paths QuickLook could not render. Without this, every redraw would
    /// re-ask for a thumbnail that will never arrive — for a folder of plain
    /// text files that is a request per row per scroll.
    private var unavailable: Set<String> = []
    private var inFlight: Set<String> = []

    /// Keyed on mtime as well as path so an edited file does not keep showing
    /// the thumbnail of its previous contents.
    private func key(_ path: String, _ mtime: Int64) -> String {
        "\(path)|\(mtime)"
    }

    /// Returns a cached thumbnail if there is one. Otherwise returns nil and,
    /// unless this file is already being worked on or known to have no
    /// preview, generates one and calls `then` on the main actor.
    func thumbnail(for path: String, mtime: Int64,
                   then: @escaping @MainActor (NSImage) -> Void) -> NSImage? {
        let k = key(path, mtime)
        if let hit = cache[k] { return hit }
        guard !unavailable.contains(k), !inFlight.contains(k) else { return nil }
        inFlight.insert(k)

        let size = Self.renderSize
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: size, height: size),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            // .thumbnail only, deliberately: the other representation types
            // fall back to the very type icon this exists to replace, so a
            // failure would be indistinguishable from a success.
            representationTypes: .thumbnail)

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            // Unwrap to the CGImage here, on QuickLook's own queue.
            // QLThumbnailRepresentation is not Sendable, so it cannot cross to
            // the main actor; the CGImage inside it can.
            let cgImage = rep?.cgImage
            Task { @MainActor in
                self.inFlight.remove(k)
                guard let cgImage else {
                    self.unavailable.insert(k)
                    return
                }
                let image = NSImage(cgImage: cgImage,
                                    size: NSSize(width: size, height: size))
                self.cache[k] = image
                then(image)
            }
        }
        return nil
    }
}
