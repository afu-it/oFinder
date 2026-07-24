// GoToFolderPanel.swift
// Port of GoToFolderPanel.m: a "Go to Folder" sheet (or standalone modal
// when there is no parent window) that resolves and validates the entered
// path before handing it back.

import AppKit

@MainActor
enum GoToFolderPanel {

    /// Present the sheet on `window` (or run modally when nil). Calls
    /// `handler` with the entered path (tilde-expanded, symlinks resolved),
    /// or nil if the user cancelled or the path doesn't exist.
    static func runAsSheet(on window: NSWindow?,
                           completionHandler handler: @escaping @MainActor (String?) -> Void) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "~/Documentos  o  /usr/local/bin"
        field.font = .systemFont(ofSize: 13)
        (field.cell as? NSTextFieldCell)?.isScrollable = true
        field.stringValue = NSHomeDirectory()

        let alert = NSAlert()
        alert.messageText = "Ir a la carpeta"
        alert.informativeText = "Escribe la ruta a la que deseas navegar:"
        alert.addButton(withTitle: "Ir")
        alert.addButton(withTitle: "Cancelar")
        alert.accessoryView = field

        func finish(_ response: NSApplication.ModalResponse) {
            guard response == .alertFirstButtonReturn else { handler(nil); return }
            let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            handler(resolvePath(entered))
        }

        if let window {
            alert.beginSheetModal(for: window) { finish($0) }
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(field)
            }
        } else {
            finish(alert.runModal())
        }
    }

    private static func resolvePath(_ input: String) -> String? {
        guard !input.isEmpty else { return nil }
        let resolved = ((input as NSString).expandingTildeInPath as NSString)
            .resolvingSymlinksInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            let err = NSAlert()
            err.messageText = "Carpeta no encontrada"
            err.informativeText = "La ruta '\(resolved)' no existe o no es una carpeta."
            err.alertStyle = .critical
            err.runModal()
            return nil
        }
        return resolved
    }
}
