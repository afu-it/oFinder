// VolumeService.swift
// Mounted volumes and special directories — port of volumes.zig.

import Foundation

public struct VolumeEntry {
    /// Display name. For special directories this is the untranslated English
    /// label; callers showing it to the user should localize via `key`.
    public var name: String
    public var path: String
    /// Stable identifier for well-known directories ("home", "desktop", …).
    /// nil for mounted volumes, whose name comes from the filesystem.
    public var key: String?

    public init(name: String, path: String, key: String? = nil) {
        self.name = name
        self.path = path
        self.key = key
    }
}

public enum VolumeService {
    /// Mounted volumes under /Volumes (DMGs, network shares, external drives).
    /// Uses mountedVolumeURLs so volume display names are correct, filtered to
    /// /Volumes/ so the boot volume ("/") and hidden system volumes don't
    /// clutter the sidebar (which adds "Macintosh HD" → "/" itself).
    public static func volumes() -> [VolumeEntry] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let path = url.path
            guard path.hasPrefix("/Volumes/") else { return nil }
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
                ?? url.lastPathComponent
            return VolumeEntry(name: name, path: path)
        }
    }

    /// Well-known user directories, only those that exist.
    /// Each carries a stable `key` so the UI can localize the label without
    /// the identifier shifting language with it.
    public static func specialDirs() -> [VolumeEntry] {
        let home = NSHomeDirectory()
        let dirs: [(key: String, name: String, rel: String)] = [
            ("home", "Home", ""),
            ("desktop", "Desktop", "/Desktop"),
            ("documents", "Documents", "/Documents"),
            ("downloads", "Downloads", "/Downloads"),
            ("music", "Music", "/Music"),
            ("pictures", "Pictures", "/Pictures"),
            ("movies", "Movies", "/Movies"),
            ("applications", "Applications", "/Applications"),
        ]
        var result: [VolumeEntry] = []
        for d in dirs {
            let full = home + d.rel
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            result.append(VolumeEntry(name: d.name, path: full, key: d.key))
        }
        return result
    }
}
