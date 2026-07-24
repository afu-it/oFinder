// ProgressParsers.swift
// Pure parsing of rsync --info=progress2 and 7zz -bsp1 progress output.
// Ports of parseRsyncProgress / parseSevenZPercent from the old transfer.zig
// and archive.zig — kept as free-standing pure functions so they can be
// unit-tested against captured fixture output.

import Foundation

/// One parsed rsync `--info=progress2` line.
public struct RsyncProgress: Equatable {
    public var progress: Double // 0.0 … 1.0
    public var bytes: UInt64    // bytes transferred so far
    public var speed: Double    // bytes/second

    public init(progress: Double, bytes: UInt64, speed: Double) {
        self.progress = progress
        self.bytes = bytes
        self.speed = speed
    }
}

public enum RsyncProgressParser {
    /// Parse an rsync --info=progress2 output line.
    /// Format: "  104,857,600  50%  399.88MB/s    0:00:00 (xfr#10, to-chk=10/21)"
    /// The percentage is overall transfer progress. Intermediate lines may omit
    /// the "(xfr…)" part. Returns nil for anything that isn't a progress line.
    public static func parse(line: String) -> RsyncProgress? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2 else { return nil }

        // First token: bytes transferred (may contain thousand separators)
        let bytes = parseSeparatedNumber(tokens[0])

        // Second token: percentage (e.g. "50%") — overall progress
        let pctToken = tokens[1]
        guard let pctPos = pctToken.firstIndex(of: "%"), pctPos != pctToken.startIndex,
              let pct = UInt32(pctToken[pctToken.startIndex..<pctPos])
        else { return nil }

        // Third token: speed (e.g. "352.23MB/s")
        let speed = tokens.count >= 3 ? parseSpeed(tokens[2]) : 0

        return RsyncProgress(progress: Double(pct) / 100.0, bytes: bytes, speed: speed)
    }

    /// Accumulate digits, skipping commas/dots used as thousand separators.
    static func parseSeparatedNumber(_ s: Substring) -> UInt64 {
        var val: UInt64 = 0
        for ch in s.utf8 where ch >= UInt8(ascii: "0") && ch <= UInt8(ascii: "9") {
            val = val &* 10 &+ UInt64(ch - UInt8(ascii: "0"))
        }
        return val
    }

    /// "399.88MB/s" → bytes per second. Units: GB/s, MB/s, kB/s, else B/s.
    static func parseSpeed(_ s: Substring) -> Double {
        var numEnd = s.startIndex
        for i in s.indices {
            if s[i].isNumber || s[i] == "." { numEnd = s.index(after: i) } else { break }
        }
        guard numEnd != s.startIndex, let num = Double(s[s.startIndex..<numEnd]) else { return 0 }
        let unit = s[numEnd...]
        if unit.hasPrefix("GB/s") { return num * 1024 * 1024 * 1024 }
        if unit.hasPrefix("MB/s") { return num * 1024 * 1024 }
        if unit.hasPrefix("kB/s") { return num * 1024 }
        return num // B/s
    }
}

public enum SevenZipProgressParser {
    /// Parse a percentage from 7zz -bsp1 progress lines like " 42%" or
    /// "100% 3 + file.txt". Returns the percentage (0–100), or nil.
    public static func parsePercent(line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let pctIdx = trimmed.firstIndex(of: "%"), pctIdx != trimmed.startIndex else { return nil }
        // Scan backwards from '%' over digits
        var start = pctIdx
        while start != trimmed.startIndex {
            let prev = trimmed.index(before: start)
            guard trimmed[prev].isNumber else { break }
            start = prev
        }
        guard start != pctIdx, let val = UInt32(trimmed[start..<pctIdx]) else { return nil }
        return Double(val)
    }
}
