// MoveUndo.swift
// One level of undo for moves.

import Foundation

/// Records the last completed move so it can be put back.
///
/// Only moves are recorded. Undoing a copy would mean deleting files the user
/// can see at the destination, and getting that wrong destroys data — the
/// asymmetry is deliberate, not an oversight. A move has an unambiguous
/// inverse: put each item back where it came from.
///
/// Single level, because the honest alternative is a full journal and a
/// stack of half-true entries is worse than one entry the user can trust.
@MainActor
enum MoveUndo {
    struct Record {
        /// Absolute paths as they were *before* the move.
        let originalPaths: [String]
        let dstDir: String

        /// Where each item lives now, paired with the directory to restore it
        /// to. Items are grouped by target directory so a multi-source move
        /// can be reversed with one rsync per original parent.
        var restoreGroups: [String: [String]] {
            var groups: [String: [String]] = [:]
            for original in originalPaths {
                let name = (original as NSString).lastPathComponent
                let parent = (original as NSString).deletingLastPathComponent
                groups[parent, default: []].append((dstDir as NSString)
                    .appendingPathComponent(name))
            }
            return groups
        }

        /// True while every moved item is still sitting at the destination.
        /// If the user has since renamed, deleted or moved them again, undo
        /// would restore a partial set — better to drop the offer entirely.
        var isStillValid: Bool {
            let fm = FileManager.default
            return originalPaths.allSatisfy { original in
                let moved = (dstDir as NSString)
                    .appendingPathComponent((original as NSString).lastPathComponent)
                return fm.fileExists(atPath: moved) && !fm.fileExists(atPath: original)
            }
        }
    }

    private(set) static var last: Record?

    static func record(originalPaths: [String], dstDir: String) {
        last = Record(originalPaths: originalPaths, dstDir: dstDir)
    }

    static func clear() { last = nil }

    /// The record only if it can still be applied.
    static var available: Record? {
        guard let last, last.isStillValid else { return nil }
        return last
    }
}
