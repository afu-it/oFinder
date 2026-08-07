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

            Add oFinder to the list, then quit and reopen it.
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

    /// Writes a report on whether the protected directories can actually be
    /// read, when ~/Library/Caches/ofinder-probe-me exists.
    ///
    /// Worth keeping, because the obvious ways to check are both wrong. System
    /// Settings shows what was granted, not what applies — a stale entry keeps
    /// its switch on after the bundle it named is gone. And running the binary
    /// from a terminal reports the terminal's access, not the app's, because
    /// TCC attributes a request to the responsible process, which for a
    /// shell-launched executable is the shell.
    ///
    /// So the check has to run inside the app, launched by LaunchServices, and
    /// leave its answer somewhere a terminal can read it afterwards. A marker
    /// file rather than an environment variable, since `open` does not pass
    /// the environment through.
    static func runDiagnosticIfRequested() {
        let marker = NSHomeDirectory() + "/Library/Caches/ofinder-probe-me"
        guard FileManager.default.fileExists(atPath: marker) else { return }
        try? FileManager.default.removeItem(atPath: marker)

        var report = ""
        for path in [probePath, NSHomeDirectory() + "/.Trash"] {
            do {
                let count = try FileManager.default.contentsOfDirectory(atPath: path).count
                report += "OK    \(count) item  \(path)\n"
            } catch let error as NSError {
                report += "DENY  code=\(error.code)  \(path)\n"
            }
        }
        report += "bundle: \(Bundle.main.bundlePath)\n"
        // Written before exiting, never from a defer: exit() ends the process
        // outright and defers do not run.
        try? report.write(toFile: NSHomeDirectory() + "/Library/Caches/ofinder-fda.txt",
                          atomically: true, encoding: .utf8)
        exit(0)
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
