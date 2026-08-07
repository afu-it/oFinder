// NavigationHistory.swift
// Back/forward stack for one browsing context.

import Foundation

/// A back/forward stack.
///
/// Lives in the service layer with no AppKit in sight because it is pure
/// bookkeeping, and because the off-by-one that breaks a forward stack is
/// invisible until someone navigates in exactly the wrong order — which is
/// far easier to pin down in a test than in a window.
public struct NavigationHistory {
    private(set) var entries: [String] = []
    private(set) var index = -1

    public init(startingAt path: String? = nil) {
        if let path { push(path) }
    }

    public var current: String? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    /// Adds a destination, discarding anything ahead of the current position —
    /// the same rule a browser follows: navigating somewhere new from halfway
    /// back abandons the branch you had gone forward into.
    public mutating func push(_ path: String) {
        // Re-entering the place you are already on is not a navigation; without
        // this, holding a folder open through a refresh fills the stack with
        // duplicates and Back appears to do nothing several times over.
        if current == path { return }

        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(path)
        index = entries.count - 1
    }

    @discardableResult
    public mutating func goBack() -> String? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    @discardableResult
    public mutating func goForward() -> String? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}
