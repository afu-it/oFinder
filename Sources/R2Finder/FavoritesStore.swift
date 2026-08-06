// FavoritesStore.swift
// The order and contents of the Favorites section, persisted across launches.

import Foundation
import R2FinderServices

/// Favorites are stored as an ordered list of identifiers rather than as
/// resolved rows.
///
/// The rows themselves are rebuilt from the live system on every launch —
/// Recents is a query, and the special directories only appear if they exist —
/// so persisting rendered rows would mean persisting stale ones. An identifier
/// says *which* entry, and resolution stays a runtime concern.
@MainActor
enum FavoritesStore {
    private static let defaultsKey = "sidebarFavoriteOrder"

    enum Entry: Equatable {
        /// A well-known directory, keyed by VolumeService's stable key.
        case special(key: String)
        /// A folder the user added, keyed by absolute path.
        case custom(path: String)

        var id: String {
            switch self {
            case .special(let key):   return "special:" + key
            case .custom(let path):   return "custom:" + path
            }
        }

        init?(id: String) {
            // "recents" was persisted here in an earlier version; it is its
            // own sidebar section now, so old entries are simply dropped.
            if id.hasPrefix("special:") {
                self = .special(key: String(id.dropFirst("special:".count)))
                return
            }
            if id.hasPrefix("custom:") {
                self = .custom(path: String(id.dropFirst("custom:".count)))
                return
            }
            return nil
        }
    }

    private static let removedKey = "sidebarFavoritesRemovedBuiltIns"

    /// Built-in entries the user deliberately removed.
    ///
    /// Needed because reconciliation appends any built-in missing from the
    /// saved order. Without a record of the intent, "removed" and "not seen
    /// yet" look identical, and a removed Desktop would quietly come back on
    /// the next launch.
    private static func removedBuiltIns() -> Set<String> {
        Set(UserDefaults.standard.array(forKey: removedKey) as? [String] ?? [])
    }

    private static func setRemovedBuiltIns(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: removedKey)
    }

    /// The saved order, reconciled against what actually exists right now.
    ///
    /// Reconciliation runs in both directions: entries that no longer resolve
    /// are dropped, and anything the system offers that isn't in the saved
    /// order is appended. Without the second half, a user who reordered their
    /// favorites once would never see a directory they created later.
    static func entries() -> [Entry] {
        let saved = (UserDefaults.standard.array(forKey: defaultsKey) as? [String] ?? [])
            .compactMap(Entry.init(id:))

        let liveSpecialKeys = VolumeService.specialDirs().compactMap(\.key)
        let fm = FileManager.default

        var result = saved.filter { entry in
            switch entry {
            case .special(let key):
                return liveSpecialKeys.contains(key)
            case .custom(let path):
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
        }

        let removed = removedBuiltIns()
        for key in liveSpecialKeys
        where !result.contains(.special(key: key))
            && !removed.contains(Entry.special(key: key).id) {
            result.append(.special(key: key))
        }
        return result
    }

    static func save(_ entries: [Entry]) {
        UserDefaults.standard.set(entries.map(\.id), forKey: defaultsKey)
    }

    /// Adds a folder. Returns false if it was already there, so the caller can
    /// avoid a pointless sidebar rebuild.
    ///
    /// Adding back a folder that is one of the built-ins restores the built-in
    /// rather than creating a second, custom row pointing at the same place.
    /// That makes Remove reversible through the same gesture that adds
    /// anything else, which is the only undo this list has.
    @discardableResult
    static func add(path: String) -> Bool {
        if let key = VolumeService.specialDirs().first(where: { $0.path == path })?.key {
            let builtIn = Entry.special(key: key)
            var removed = removedBuiltIns()
            if removed.contains(builtIn.id) {
                removed.remove(builtIn.id)
                setRemovedBuiltIns(removed)
                return true
            }
            // Present already, under its built-in identity.
            return false
        }

        var current = entries()
        guard !current.contains(.custom(path: path)) else { return false }
        current.append(.custom(path: path))
        save(current)
        return true
    }

    static func remove(_ entry: Entry) {
        if case .special = entry {
            setRemovedBuiltIns(removedBuiltIns().union([entry.id]))
        }
        save(entries().filter { $0 != entry })
    }

    /// Moves the entry to `index` in the current order.
    static func move(_ entry: Entry, to index: Int) {
        save(reorder(entries(), moving: entry, to: index))
    }

    /// Pure reorder, split out from `move` so the index arithmetic can be
    /// tested without UserDefaults or a live filesystem.
    ///
    /// `index` is an NSOutlineView drop index: a position in the list *as the
    /// user currently sees it*, before the dragged row is taken out. Removing
    /// the row first shifts every later position down by one, so a drop below
    /// the original spot has to come back by one to land where the insertion
    /// line was drawn. Getting this wrong is invisible for a drop upward and
    /// off-by-one for every drop downward.
    static func reorder(_ entries: [Entry], moving entry: Entry,
                        to index: Int) -> [Entry] {
        var result = entries
        guard let from = result.firstIndex(of: entry) else { return entries }
        result.remove(at: from)
        let target = min(max(0, from < index ? index - 1 : index), result.count)
        result.insert(entry, at: target)
        return result
    }
}
