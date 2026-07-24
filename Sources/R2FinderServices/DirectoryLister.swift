// DirectoryLister.swift
// Directory listing — port of dir_listing.zig.

import Foundation

public struct DirEntry {
    public var name: String
    public var path: String
    public var isDir: Bool
    public var isSymlink: Bool
    public var size: UInt64  // bytes
    public var mtime: Int64  // unix timestamp seconds
}

public enum DirectoryLister {
    /// List a directory. Returns nil if the directory cannot be opened
    /// (matching the old NULL return). Entries are sorted directories-first,
    /// then ASCII-case-insensitive by name. Hidden files are included — the
    /// UI layer filters them.
    public static func list(path: String) -> [DirEntry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return nil
        }

        var entries: [DirEntry] = []
        entries.reserveCapacity(names.count)

        for name in names {
            let fullPath = path + "/" + name

            var lst = stat()
            guard lstat(fullPath, &lst) == 0 else { continue }
            let isSymlink = (lst.st_mode & S_IFMT) == S_IFLNK

            // size/mtime follow symlinks (stat), 0 on failure (e.g. broken link)
            var size: UInt64 = 0
            var mtime: Int64 = 0
            var isDir = (lst.st_mode & S_IFMT) == S_IFDIR
            var st = stat()
            if isSymlink {
                if stat(fullPath, &st) == 0 {
                    size = UInt64(max(0, st.st_size))
                    mtime = Int64(st.st_mtimespec.tv_sec)
                    // symlink pointing at a directory counts as a directory
                    isDir = isDir || (st.st_mode & S_IFMT) == S_IFDIR
                }
            } else {
                size = UInt64(max(0, lst.st_size))
                mtime = Int64(lst.st_mtimespec.tv_sec)
            }

            entries.append(DirEntry(name: name, path: fullPath, isDir: isDir,
                                    isSymlink: isSymlink, size: size, mtime: mtime))
        }

        // Sort: directories first, then ASCII-case-insensitive alphabetical
        entries.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return asciiCaseInsensitiveLess(a.name, b.name)
        }
        return entries
    }

    /// Byte-wise ASCII-case-insensitive ordering (port of std.ascii.orderIgnoreCase):
    /// only A–Z are lowered, ties broken by length.
    static func asciiCaseInsensitiveLess(_ a: String, _ b: String) -> Bool {
        var ai = a.utf8.makeIterator()
        var bi = b.utf8.makeIterator()
        while true {
            switch (ai.next(), bi.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (ca?, cb?):
                let la = (ca >= UInt8(ascii: "A") && ca <= UInt8(ascii: "Z")) ? ca + 32 : ca
                let lb = (cb >= UInt8(ascii: "A") && cb <= UInt8(ascii: "Z")) ? cb + 32 : cb
                if la != lb { return la < lb }
            }
        }
    }
}
