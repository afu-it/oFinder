// Localization.swift
// Localized-string lookup for the UI target.

import Foundation

/// Thin wrapper over `Bundle.module`'s `Localizable.strings`.
///
/// The English text is passed at the call site as the fallback `value`, so a
/// reader can see what a line says without opening the `.strings` file, and a
/// missing key degrades to readable English instead of showing the raw key.
enum L10n {
    /// Plain lookup.
    static func t(_ key: String, _ value: String) -> String {
        Bundle.module.localizedString(forKey: key, value: value, table: nil)
    }

    /// Lookup + `String(format:)`. Use for strings carrying `%@` / `%d`.
    static func f(_ key: String, _ value: String, _ args: CVarArg...) -> String {
        String(format: t(key, value), locale: .current, arguments: args)
    }
}
