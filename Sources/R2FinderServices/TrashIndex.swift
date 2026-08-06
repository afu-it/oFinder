// TrashIndex.swift
// Reading where trashed items came from.

import Foundation

/// Maps items in the Trash back to where they were.
///
/// macOS records nothing on the file itself — a trashed item carries no
/// extended attribute naming its origin. Finder keeps that information in
/// `~/.Trash/.DS_Store`, under the keys `ptbL` (the folder it came from) and
/// `ptbN` (what it was called), and exposes no API for reading it. Finder's
/// own scripting dictionary has no "put back" command either, so restoring
/// means reading those records directly.
///
/// The format is Apple's undocumented Buddy allocator. Only the record stream
/// is walked here, not the B-tree that indexes it: every record is present in
/// the file, and a scan finds them all without having to reimplement the
/// allocator.
public enum TrashIndex {

    /// Trash entry name → the full path it should be restored to.
    public static func origins(trashPath: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: trashPath + "/.DS_Store")
        else { return [:] }
        return origins(dsStore: data)
    }

    /// Split from the path version so the parsing can be exercised without a
    /// Trash to read — the real file is unreadable without Full Disk Access,
    /// which no test should require.
    public static func origins(dsStore data: Data) -> [String: String] {

        var folders: [String: String] = [:]   // entry name → original folder
        var names: [String: String] = [:]     // entry name → original file name

        for record in records(in: [UInt8](data)) {
            switch record.key {
            case "ptbL": folders[record.owner] = record.value
            case "ptbN": names[record.owner] = record.value
            default: break
            }
        }

        var result: [String: String] = [:]
        for (entry, folder) in folders {
            // ptbN is the name it had before being trashed, which differs from
            // the entry name whenever the Trash already held something with
            // that name and macOS appended a number.
            let name = names[entry] ?? entry
            result[entry] = normalize(folder) + "/" + name
        }
        return result
    }

    /// `ptbL` is stored without a leading slash and behind the firmlink that
    /// makes the Data volume appear at the root, so the recorded path is
    /// `System/Volumes/Data/Users/…` where the user sees `/Users/…`.
    private static func normalize(_ folder: String) -> String {
        var path = folder
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasPrefix("/") { path = "/" + path }
        let firmlink = "/System/Volumes/Data"
        if path.hasPrefix(firmlink) {
            path = String(path.dropFirst(firmlink.count))
        }
        return path.isEmpty ? "/" : path
    }

    private struct Record {
        let owner: String   // the file the record is about
        let key: String     // ptbL, ptbN, …
        let value: String
    }

    /// Walks the file looking for well-formed records.
    ///
    /// Each is a UTF-16BE name with a length prefix, a four-character key, a
    /// four-character type, and a value whose size the type decides. A
    /// position that does not parse as all of those is not a record, so the
    /// scan advances a byte and tries again.
    private static func records(in bytes: [UInt8]) -> [Record] {
        var result: [Record] = []
        var i = 0

        func be32(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            return (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                 | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        }

        func utf16(_ at: Int, units: Int) -> String? {
            guard units >= 0, at + units * 2 <= bytes.count else { return nil }
            var text = String.UnicodeScalarView()
            for k in 0..<units {
                let scalar = UInt16(bytes[at + k * 2]) << 8 | UInt16(bytes[at + k * 2 + 1])
                guard let unicode = Unicode.Scalar(scalar) else { return nil }
                text.append(unicode)
            }
            return String(text)
        }

        func ascii(_ at: Int) -> String? {
            guard at + 4 <= bytes.count else { return nil }
            let chars = bytes[at..<(at + 4)]
            guard chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
            return String(decoding: chars, as: UTF8.self)
        }

        while i + 12 < bytes.count {
            guard let nameLength = be32(i), nameLength > 0, nameLength < 1024,
                  let owner = utf16(i + 4, units: nameLength),
                  let key = ascii(i + 4 + nameLength * 2),
                  let type = ascii(i + 8 + nameLength * 2)
            else { i += 1; continue }

            let valueStart = i + 12 + nameLength * 2
            let size: Int
            var value = ""
            switch type {
            case "bool": size = 1
            case "long", "shor", "type": size = 4
            case "comp", "dutc": size = 8
            case "blob":
                guard let n = be32(valueStart) else { i += 1; continue }
                size = 4 + n
            case "ustr":
                guard let n = be32(valueStart), let s = utf16(valueStart + 4, units: n)
                else { i += 1; continue }
                size = 4 + n * 2
                value = s
            default:
                i += 1; continue
            }

            result.append(Record(owner: owner, key: key, value: value))
            i = valueStart + size
        }
        return result
    }
}
