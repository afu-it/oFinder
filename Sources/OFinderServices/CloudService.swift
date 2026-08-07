// CloudService.swift
// Cloud storage locations that exist on this Mac.

import Foundation

public enum CloudService {

    /// Where iCloud Drive actually lives. The name is an escaped bundle
    /// identifier and the folder sits inside Library, so it is invisible in
    /// every normal listing — which is exactly why it needs a sidebar entry.
    private static var iCloudDrivePath: String {
        NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
    }

    /// Where macOS mounts third-party providers — Dropbox, Google Drive,
    /// OneDrive — since Big Sur's File Provider move. Each is a subdirectory,
    /// named by the provider.
    private static var cloudStoragePath: String {
        NSHomeDirectory() + "/Library/CloudStorage"
    }

    /// Cloud locations present right now, iCloud Drive first.
    ///
    /// Discovered rather than hardcoded past iCloud: providers appear and
    /// disappear as apps are installed, and a list baked into the binary would
    /// be wrong the day after someone installs Dropbox.
    public static func locations() -> [VolumeEntry] {
        let fm = FileManager.default
        var result: [VolumeEntry] = []

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: iCloudDrivePath, isDirectory: &isDir), isDir.boolValue {
            result.append(VolumeEntry(name: "iCloud Drive",
                                      path: iCloudDrivePath,
                                      key: "icloud"))
        }

        let providers = (try? fm.contentsOfDirectory(atPath: cloudStoragePath)) ?? []
        for provider in providers.sorted() where !provider.hasPrefix(".") {
            let path = cloudStoragePath + "/" + provider
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            // Directories are named "Dropbox-Personal", "GoogleDrive-<account>".
            // The part before the dash is the service; the rest is which
            // account, which the sidebar has no room for.
            let name = provider.split(separator: "-").first.map(String.init) ?? provider
            result.append(VolumeEntry(name: name, path: path, key: "cloud:" + provider))
        }

        return result
    }
}
