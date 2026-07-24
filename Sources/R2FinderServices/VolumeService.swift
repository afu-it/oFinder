// VolumeService.swift
// Mounted volumes and special directories — port of volumes.zig.

import Foundation

public struct VolumeEntry {
    public var name: String
    public var path: String
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
    /// Display names stay in Spanish to match the rest of the UI.
    public static func specialDirs() -> [VolumeEntry] {
        let home = NSHomeDirectory()
        let dirs: [(name: String, rel: String)] = [
            ("Inicio", ""),
            ("Escritorio", "/Desktop"),
            ("Documentos", "/Documents"),
            ("Descargas", "/Downloads"),
            ("Música", "/Music"),
            ("Imágenes", "/Pictures"),
            ("Películas", "/Movies"),
            ("Aplicaciones", "/Applications"),
        ]
        var result: [VolumeEntry] = []
        for d in dirs {
            let full = home + d.rel
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            result.append(VolumeEntry(name: d.name, path: full))
        }
        return result
    }
}
