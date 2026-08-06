// Localization.swift
// Localized-string lookup for the service layer.
//
// Separate from the UI target's copy because each SwiftPM target carries its
// own resource bundle, so `Bundle.module` resolves per-module.

import Foundation

enum L10n {
    static func t(_ key: String, _ value: String) -> String {
        Bundle.module.localizedString(forKey: key, value: value, table: nil)
    }

    static func f(_ key: String, _ value: String, _ args: CVarArg...) -> String {
        String(format: t(key, value), locale: .current, arguments: args)
    }
}
