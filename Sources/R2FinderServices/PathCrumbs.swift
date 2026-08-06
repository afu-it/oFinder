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
    /// Breaks a path into crumbs, leading with the volume rather than with an
    /// empty segment.
    ///
    /// `/Users/afwazan` is three components to the filesystem — "", "Users",
    /// "afwazan" — and two places plus a disk to a person. The root becomes
    /// the volume's name, and a path on a mounted volume starts at that
    /// volume instead of showing "Volumes" as a folder anyone navigates
    /// through.
    ///
    /// `rootVolumeName` is passed in rather than looked up so this stays pure;
    /// the caller reads it from the filesystem once.
    public static func split(path: String, rootVolumeName: String) -> [PathCrumb] {
        var crumbs: [PathCrumb] = []
        var rootPath = "/"
        var remainder = path

        let parts = path.split(separator: "/").map(String.init)

        // "/Volumes" itself is a real directory, so it only collapses into a
        // volume crumb when there is a volume named after it.
        if parts.first == "Volumes", parts.count >= 2 {
            rootPath = "/Volumes/" + parts[1]
            crumbs.append(PathCrumb(title: parts[1], path: rootPath))
            remainder = parts.dropFirst(2).joined(separator: "/")
        } else {
            crumbs.append(PathCrumb(title: rootVolumeName, path: "/"))
            remainder = parts.joined(separator: "/")
        }

        var accumulated = rootPath == "/" ? "" : rootPath
        for part in remainder.split(separator: "/") {
            accumulated += "/" + part
            crumbs.append(PathCrumb(title: String(part), path: accumulated))
        }
        return crumbs
    }
}
