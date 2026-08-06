// FullDiskAccess.swift
// Detecting the Full Disk Access grant, and pointing at where to give it.

import AppKit

/// Full Disk Access cannot be requested.
///
/// There is no `requestAccess` for it the way there is for the camera or the
/// photo library: the grant covers nearly everything on the disk, so macOS
/// only accepts it from System Settings, never from a dialog an app raised
/// itself. All an app can do is notice it is missing, say why it matters, and
/// open the right pane so nobody has to go hunting.
@MainActor
enum FullDiskAccess {

    /// A directory that exists on every Mac and that only an app with Full
    /// Disk Access can open. Reading it is the standard way to test the grant,
    /// because there is no API that reports it.
    private static var probePath: String {
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC"
    }

    static var isGranted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: probePath)) != nil
    }

    /// Shown at most once per launch. A folder that cannot be read is often
    /// hit several times in a row — navigating in, refreshing, coming back —
    /// and a dialog on each would be worse than the silence it replaces.
    private static var hasAsked = false

    static func explain(blockedPath: String, in window: NSWindow?) {
        guard !hasAsked, !isGranted else { return }
        hasAsked = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.f("fda.title", "“%@” can't be opened",
                                   (blockedPath as NSString).lastPathComponent)
        alert.informativeText = L10n.t(
            "fda.body",
            """
            macOS protects the Trash and a few other folders. Reading them \
            needs Full Disk Access, which only you can grant in System \
            Settings — an app cannot ask for it directly.

            Add R2 Finder to the list, then quit and reopen it.
            """)
        alert.addButton(withTitle: L10n.t("fda.openSettings", "Open Settings"))
        alert.addButton(withTitle: L10n.t("button.cancel", "Cancel"))

        let response = window.map { alert.beginSheetModal(for: $0, completionHandler: { response in
            if response == .alertFirstButtonReturn { openSettings() }
        }) }
        if response == nil, alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }

    static func openSettings() {
        // Deep link straight to the Full Disk Access list. The pane moved in
        // Ventura, but this identifier still resolves.
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
