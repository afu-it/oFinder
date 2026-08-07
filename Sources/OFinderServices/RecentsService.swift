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
    public static let locationID = "ofinder://recents"

    public static func isRecents(_ path: String) -> Bool { path == locationID }

    /// Hard ceiling on how many matches the walk inspects. A home directory
    /// that is mostly generated content could otherwise send it through every
    /// match looking for keepers that are not there.
    private static let maxScan = 4_000

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
    /// Runs the query once and discards the result.
    ///
    /// Spotlight caches per query *shape*: the first run of this predicate in
    /// a process costs about 1.1s, every later one about 0.12s. A different
    /// predicate does not warm it — measured. Calling this at launch moves the
    /// one expensive run off the first click on Recents, where someone is
    /// waiting for it.
    public static func prewarm(withinDays: Int = 30) {
        _ = makeQuery(withinDays: withinDays)
    }

    private static func makeQuery(withinDays: Int) -> MDQuery? {
        let seconds = -(withinDays * 86_400)
        let predicate = """
            (kMDItemLastUsedDate >= $time.now(\(seconds)) || \
            kMDItemFSContentChangeDate >= $time.now(\(seconds))) && \
            kMDItemContentTypeTree != 'public.folder' && \
            kMDItemContentTypeTree != 'com.apple.application-bundle'
            """

        // valueListAttrs (3rd) is deliberately nil. Naming attributes there
        // looks like a per-result read optimisation, but that list feeds
        // Spotlight's aggregate value lists (the counts behind grouped
        // filters); MDQueryGetAttributeValueOfResultAtIndex returns nil for
        // these attributes regardless, which silently empties the result.
        //
        // sortingAttrs (4th) is what makes this fast. Spotlight orders the
        // matches itself, so the newest are at one end and the walk below can
        // stop after a few hundred instead of reading an attribute off all
        // twenty thousand.
        let sortingAttrs = [kMDItemFSContentChangeDate] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString,
                                        nil, sortingAttrs) else { return nil }
        MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            return nil
        }
        return query
    }

    public static func list(limit: Int = 100, withinDays: Int = 30) -> [DirEntry] {
        guard let query = makeQuery(withinDays: withinDays) else { return [] }

        var ranked: [(entry: DirEntry, rank: Date)] = []

        // Walk from the newest end. Collect a surplus rather than exactly
        // `limit`: the final order is by the later of last-used and changed,
        // so a few items further down can still outrank ones already taken.
        let total = MDQueryGetResultCount(query)
        let wanted = limit * 3
        var scanned = 0

        for offset in 0..<total where ranked.count < wanted && scanned < Self.maxScan {
            let i = total - 1 - offset
            scanned += 1
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)

            // Path first: it is the cheapest attribute and rejects most of
            // what is scanned, so the date reads run only for keepers.
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
