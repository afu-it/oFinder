// RecentsService.swift
// Recently used files, backed by Spotlight.

import Foundation
import CoreServices

public enum RecentsService {
    /// Virtual location token for the Recents list.
    ///
    /// Deliberately not a filesystem path: it carries a scheme so that any
    /// code which hands it to FileManager fails loudly rather than silently
    /// listing some directory that happens to be named "recents". Callers
    /// that touch the disk must check `isRecents` first.
    public static let locationID = "r2finder://recents"

    public static func isRecents(_ path: String) -> Bool { path == locationID }

    /// Directory names that hold generated or vendored files. Spotlight
    /// indexes them, and on a machine with any checked-out project they
    /// otherwise drown out everything the user actually worked on — a single
    /// `npm install` outnumbers a month of real documents.
    private static let excludedDirs: Set<String> = [
        "Library", "node_modules", "Pods", "DerivedData", "__pycache__",
        "venv", "target", "vendor", "dist",
    ]

    /// Recently used files, newest first.
    ///
    /// Ranked by the later of "when the user last opened it" and "when it last
    /// changed", which is what makes a fresh download and a reopened document
    /// both show up. `kMDItemLastUsedDate` alone is too sparse to be useful —
    /// macOS only records it for files opened through certain APIs.
    ///
    /// Returns an empty list when Spotlight is disabled or the volume is not
    /// indexed. There is no sensible fallback: walking the disk would be slow
    /// and would rank by mtime, which is a different thing wearing the same
    /// name.
    public static func list(limit: Int = 100, withinDays: Int = 30) -> [DirEntry] {
        let seconds = -(withinDays * 86_400)
        let predicate = """
            (kMDItemLastUsedDate >= $time.now(\(seconds)) || \
            kMDItemFSContentChangeDate >= $time.now(\(seconds))) && \
            kMDItemContentTypeTree != 'public.folder' && \
            kMDItemContentTypeTree != 'com.apple.application-bundle'
            """

        // Naming the attributes up front makes Spotlight precompute them, so
        // the per-result reads below are cache hits rather than a round trip
        // to the metadata store for every one of thousands of results.
        let wanted = [kMDItemPath, kMDItemLastUsedDate,
                      kMDItemFSContentChangeDate] as CFArray

        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString,
                                        wanted, nil) else { return [] }
        MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            return []
        }

        var ranked: [(entry: DirEntry, rank: Date)] = []

        for i in 0..<MDQueryGetResultCount(query) {
            guard let path = attribute(query, i, kMDItemPath) as? String,
                  !isExcluded(path) else { continue }

            let used = attribute(query, i, kMDItemLastUsedDate) as? Date
            let changed = attribute(query, i, kMDItemFSContentChangeDate) as? Date
            guard let rank = [used, changed].compactMap({ $0 }).max() else { continue }

            // Spotlight's index lags deletions, so confirm the file is still
            // there before offering it.
            var st = stat()
            guard stat(path, &st) == 0 else { continue }

            ranked.append((DirEntry(name: (path as NSString).lastPathComponent,
                                    path: path,
                                    isDir: (st.st_mode & S_IFMT) == S_IFDIR,
                                    isSymlink: false,
                                    size: UInt64(max(0, st.st_size)),
                                    mtime: Int64(st.st_mtimespec.tv_sec)),
                           rank))
        }

        ranked.sort { $0.rank > $1.rank }
        return ranked.prefix(limit).map(\.entry)
    }

    private static func attribute(_ query: MDQuery, _ index: CFIndex,
                                  _ name: CFString) -> Any? {
        guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, name, index)
        else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
    }

    /// Excludes dot-directories, dotfiles and known generated-content folders.
    private static func isExcluded(_ path: String) -> Bool {
        for component in path.split(separator: "/") {
            if component.hasPrefix(".") { return true }
            if excludedDirs.contains(String(component)) { return true }
        }
        return false
    }
}
