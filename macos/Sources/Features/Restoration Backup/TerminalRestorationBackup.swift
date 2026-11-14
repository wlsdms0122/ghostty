import AppKit

/// A second copy of the open windows and tabs, kept in a file of our own.
///
/// AppKit owns the state its window restoration saves, and a launch can find it gone:
/// it is after Gatekeeper kills the first launch of a build that isn't notarized. This
/// copy is read only when AppKit restored nothing.
final class TerminalRestorationBackup {
    private let file: URL
    private var observers: [NSObjectProtocol] = []

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty")

        self.file = directory.appendingPathComponent("restoration-backup.plist")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Restore the backup if AppKit restored no window, then keep it current.
    ///
    /// Called once AppKit's own restoration has run. Nothing is saved before this, so a
    /// launch that ends early leaves the backup as the last one wrote it.
    func start() {
        if keepsWindows, TerminalController.all.isEmpty {
            load().forEach { $0.restore() }
        }

        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.save()
            })
        }
    }

    /// Whether windows are kept across a quit: `window-save-state` when it says so
    /// either way, the system setting when it is `default`.
    private var keepsWindows: Bool {
        UserDefaults.ghostty.bool(forKey: "NSQuitAlwaysKeepsWindows")
    }

    private func load() -> [TerminalWindowBackup] {
        guard let data = try? Data(contentsOf: file) else { return [] }

        return (try? PropertyListDecoder().decode([TerminalWindowBackup].self, from: data)) ?? []
    }

    private func save() {
        // A backup from when windows were kept would otherwise come back the next time
        // they are.
        guard keepsWindows else {
            try? FileManager.default.removeItem(at: file)
            return
        }

        var seen: Set<ObjectIdentifier> = []
        let windows = TerminalController.all.compactMap(\.window).compactMap { window -> TerminalWindowBackup? in
            let tabs = window.tabbedWindows ?? [window]
            guard let first = tabs.first, seen.insert(ObjectIdentifier(first)).inserted else { return nil }

            return TerminalWindowBackup(tabs: tabs)
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(windows) else { return }

        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
