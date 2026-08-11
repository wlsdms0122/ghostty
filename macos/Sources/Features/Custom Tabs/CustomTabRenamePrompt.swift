import AppKit

/// Asks for a group's new name.
///
/// Built to match how Ghostty prompts for a tab title, so renaming a group and renaming
/// a tab feel like the same act rather than two features that landed separately.
enum CustomTabRenamePrompt {
    static func present(
        name: String,
        over window: NSWindow,
        onCommit: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = name
        alert.accessoryView = textField
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            onCommit(textField.stringValue)
        }
    }
}
