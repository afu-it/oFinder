// PathCrumbs.swift
// Splitting a filesystem path into the parts a person would name.

import Foundation

public struct PathCrumb: Equatable {
    /// What the segment is called on screen.
    public let title: String
    /// Where clicking it leads.
    public let path: String

    public init(title: String, path: String) {
        self.title = title
        self.path = path
    }
}

public enum PathCrumbs {
    /// Breaks a path into crumbs.
    ///
    /// The boot volume contributes no crumb of its own. Its name is long, it
    /// is the same on every path, and it pushed the parts that differ off the
    /// end of the bar — so `/Users/afwazan` reads as "Users / afwazan". The
    /// root on its own still needs something to stand for it, and "/" is both
    /// short and exactly what it is.
    ///
    /// A mounted volume does keep its name as the leading crumb: there it
    /// carries real information, and "Volumes" is not a folder anyone
    /// navigates through.
    public static func split(path: String) -> [PathCrumb] {
        let parts = path.split(separator: "/").map(String.init)

        if parts.first == "Volumes", parts.count >= 2 {
            var accumulated = "/Volumes/" + parts[1]
            var crumbs = [PathCrumb(title: parts[1], path: accumulated)]
            for part in parts.dropFirst(2) {
                accumulated += "/" + part
                crumbs.append(PathCrumb(title: part, path: accumulated))
            }
            return crumbs
        }

        guard !parts.isEmpty else { return [PathCrumb(title: "/", path: "/")] }

        var accumulated = ""
        var crumbs: [PathCrumb] = []
        for part in parts {
            accumulated += "/" + part
            crumbs.append(PathCrumb(title: part, path: accumulated))
        }
        return crumbs
    }
}
