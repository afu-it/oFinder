// App.swift
// Application entry point + delegate (port of AppDelegate.m and the old
// objc_run_app()/main.swift pair).

import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // NSApplication.delegate is weak — keep the delegate alive for the whole
    // run in a static so ARC can't release it.
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    /// Strong-retain every FinderWindowController so ARC doesn't release it
    /// when openNewWindow's local goes out of scope. NSWindow.windowController
    /// is a non-retaining property, so without this the controller would be
    /// immediately deallocated, turning all weak delegate references into nil
    /// and making sidebar/toolbar clicks silently do nothing.
    private var openControllers: [FinderWindowController] = []

    // ───────────────────────────────────────────────
    // MARK: - App lifecycle
    // ───────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        openNewWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openNewWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // ───────────────────────────────────────────────
    // MARK: - Main menu
    // ───────────────────────────────────────────────

    private func buildMainMenu() {
        let main = NSMenu(title: "")
        NSApp.mainMenu = main

        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }

        // ── R2 Finder ─────────────────────────────────────────────────────────
        let appMenu = submenu("R2 Finder")
        appMenu.addItem(withTitle: L10n.t("menu.about", "About R2 Finder"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        let servicesMenu = NSMenu(title: L10n.t("menu.services", "Services"))
        appMenu.addItem(withTitle: L10n.t("menu.services", "Services"), action: nil, keyEquivalent: "").submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("menu.hide", "Hide R2 Finder"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L10n.t("menu.hideOthers", "Hide Others"),
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L10n.t("menu.showAll", "Show All"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("menu.quit", "Quit R2 Finder"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ── Archivo ───────────────────────────────────────────────────────────
        let fileMenu = submenu(L10n.t("menu.file", "File"))
        let newWin = fileMenu.addItem(withTitle: L10n.t("menu.newWindow", "New Window"),
                                      action: #selector(openNewWindow), keyEquivalent: "n")
        newWin.target = self

        // target = nil → first-responder chain reaches FinderWindowController
        fileMenu.addItem(withTitle: L10n.t("action.newFolder", "New Folder"),
                         action: #selector(FinderWindowController.createNewFolder(_:)),
                         keyEquivalent: "N") // Cmd+Shift+N

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.t("menu.closeWindow", "Close Window"),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // ── Edición ───────────────────────────────────────────────────────────
        let editMenu = submenu(L10n.t("menu.edit", "Edit"))
        // target = nil → validateMenuItem on FileViewController greys this out
        // when there is nothing to put back.
        editMenu.addItem(withTitle: L10n.t("action.undoMove", "Undo Move"),
                         action: #selector(FileViewController.undoLastMove(_:)),
                         keyEquivalent: "z")
        editMenu.addItem(.separator())
        // target = nil → first-responder chain reaches FileViewController
        editMenu.addItem(withTitle: L10n.t("action.copy", "Copy"),
                         action: #selector(FileViewController.copySelected(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t("action.cut", "Cut"),
                         action: #selector(FileViewController.cutSelected(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t("action.paste", "Paste"),
                         action: #selector(FileViewController.pasteHere(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.t("action.selectAll", "Select All"),
                         action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")

        // ── Ventana ───────────────────────────────────────────────────────────
        let windowMenu = submenu(L10n.t("menu.window", "Window"))
        NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: L10n.t("menu.minimize", "Minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L10n.t("menu.bringAllToFront", "Bring All to Front"),
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    }

    // ───────────────────────────────────────────────
    // MARK: - Dock context menu
    // ───────────────────────────────────────────────

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "")

        let newWin = NSMenuItem(title: L10n.t("menu.newWindow", "New Window"),
                                action: #selector(openNewWindow), keyEquivalent: "")
        newWin.target = self
        menu.addItem(newWin)

        let goTo = NSMenuItem(title: L10n.t("menu.goToFolderEllipsis", "Go to Folder…"),
                              action: #selector(goToFolder), keyEquivalent: "")
        goTo.target = self
        menu.addItem(goTo)

        return menu
    }

    // ───────────────────────────────────────────────
    // MARK: - Actions
    // ───────────────────────────────────────────────

    @objc func openNewWindow() {
        let wc = FinderWindowController(path: NSHomeDirectory())
        openControllers.append(wc) // retain so ARC doesn't free it
        if let window = wc.window {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(windowWillClose(_:)),
                                                   name: NSWindow.willCloseNotification,
                                                   object: window)
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func windowWillClose(_ note: Notification) {
        NotificationCenter.default.removeObserver(self,
                                                  name: NSWindow.willCloseNotification,
                                                  object: note.object)
        // Remove the controller whose window just closed; ARC will then free it.
        let closing = note.object as? NSWindow
        openControllers.removeAll { $0.window == closing }
    }

    @objc func goToFolder() {
        var parent = NSApp.mainWindow
        if parent == nil {
            // No window yet – open one first
            openNewWindow()
            parent = NSApp.mainWindow
        }

        GoToFolderPanel.runAsSheet(on: parent) { path in
            guard let path else { return }
            // If a FinderWindowController is front, navigate it; else open a new window.
            if let wc = parent?.windowController as? FinderWindowController {
                wc.navigateToPath(path)
            } else {
                FinderWindowController(path: path).showWindow(nil)
            }
        }
    }
}
