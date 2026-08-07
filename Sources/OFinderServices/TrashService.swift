// TrashService.swift
// Where the Trash is.

import Foundation

public enum TrashService {
    public static var path: String { NSHomeDirectory() + "/.Trash" }

    public static func isTrash(_ candidate: String) -> Bool {
        // Compared after standardizing: the sidebar and a typed path can spell
        // the same place differently.
        (candidate as NSString).standardizingPath == (path as NSString).standardizingPath
    }
}
