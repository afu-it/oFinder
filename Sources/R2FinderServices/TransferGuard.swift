// TransferGuard.swift
// Pre-flight validation for copy/move, kept free of UI so the rules can be
// reasoned about (and tested) on their own.

import Foundation

public enum TransferGuard {
    public enum Rejection: Equatable {
        /// Destination sits inside the thing being transferred. For a move
        /// this is the dangerous one: rsync happily copies the tree down a
        /// level, then `--remove-source-files` empties the original, leaving
        /// a skeleton of empty directories and everything nested one deeper.
        case destinationInsideSource(source: String)
        /// Destination is the source itself.
        case destinationIsSource(source: String)
        /// Moving items into the directory they already live in.
        case alreadyThere
    }

    /// Returns the reason the transfer must not run, or nil if it is safe.
    ///
    /// Paths are standardized and symlink-resolved first, so `~/a/../a/b` and
    /// a symlinked home cannot smuggle a destination past the containment
    /// check.
    public static func check(sources: [String], dstDir: String,
                             isMove: Bool) -> Rejection? {
        let dst = normalize(dstDir)

        for src in sources {
            let s = normalize(src)
            if dst == s { return .destinationIsSource(source: src) }
            if dst.hasPrefix(s + "/") { return .destinationInsideSource(source: src) }
        }

        // A move whose every item already sits in the destination is a no-op
        // worth catching: rsync would still run, and with --remove-source-files
        // an interrupted run could delete originals it had "already copied".
        if isMove, !sources.isEmpty,
           sources.allSatisfy({ normalize(($0 as NSString).deletingLastPathComponent) == dst }) {
            return .alreadyThere
        }

        return nil
    }

    private static func normalize(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: (path as NSString).standardizingPath)
            .resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/")
            ? String(resolved.dropLast()) : resolved
    }
}
