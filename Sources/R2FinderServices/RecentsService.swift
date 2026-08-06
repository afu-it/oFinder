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

        // valueListAttrs is deliberately nil. Naming attributes there looks
        // like a per-result read optimisation, but that list feeds Spotlight's
        // aggregate value lists (the counts behind grouped filters);
        // MDQueryGetAttributeValueOfResultAtIndex returns nil for these
        // attributes regardless, which silently empties the whole result.
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString,
                                        nil, nil) else { return [] }
        MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            return []
        }

        var ranked: [(entry: DirEntry, rank: Date)] = []

        for i in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)

            // Path first: it is the cheapest attribute and rejects most of the
            // result set, so the two date reads run only for keepers.
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  !isExcluded(path) else { continue }

            let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            let changed = MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date
            guard let rank = [used, changed].compactMap({ $0 }).max() else { continue }

            // Spotlight's index lags deletions, so confirm the file is still
            // there before offering it. The same stat also rejects folders:
            // the predicate asks Spotlight to exclude public.folder, but that
            // attribute is not always populated, so plain directories slip
            // through. Finder's Recents lists files only.
            var st = stat()
            guard stat(path, &st) == 0,
                  (st.st_mode & S_IFMT) != S_IFDIR else { continue }

            ranked.append((DirEntry(name: (path as NSString).lastPathComponent,
                                    path: path,
                                    isDir: false,
                                    isSymlink: false,
                                    size: UInt64(max(0, st.st_size)),
                                    mtime: Int64(st.st_mtimespec.tv_sec)),
                           rank))
        }

        ranked.sort { $0.rank > $1.rank }
        return ranked.prefix(limit).map(\.entry)
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
