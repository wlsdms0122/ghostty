import AppKit

/// One window and its tabs, as `TerminalRestorationBackup` keeps them.
///
/// A tab is the archive its controller writes for AppKit's window restoration and it
/// comes back through `TerminalWindowRestoration`, so what returns from here is what
/// AppKit would have restored: splits, working directories, title, color and group.
struct TerminalWindowBackup: Codable {
    let frame: NSRect

    /// In tab bar order.
    let tabs: [Data]

    let selectedTab: Int

    /// `windows` are the tabs of one window, in tab bar order.
    init?(tabs windows: [NSWindow]) {
        let restorable = windows.filter(\.isRestorable)
        let tabs = restorable.compactMap { window -> Data? in
            guard let controller = window.windowController as? TerminalController else { return nil }

            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            controller.window(window, willEncodeRestorableState: archiver)

            return archiver.encodedData
        }
        guard let first = restorable.first, tabs.count == restorable.count else { return nil }

        self.frame = first.frame
        self.tabs = tabs
        self.selectedTab = restorable.firstIndex { $0 === first.tabGroup?.selectedWindow } ?? 0
    }

    func restore() {
        let windows = tabs.compactMap(restoreTab)
        guard let first = windows.first else { return }

        first.setFrame(frame, display: false)

        // Tabbed before any of them is on screen. The tabs share a scope, and a scope
        // seen in two windows at once is read as a tab pulled out of its window.
        for (previous, tab) in zip(windows, windows.dropFirst()) {
            // Not an arrival: the tab already has the group it belongs to, and for an
            // ungrouped one that is no group.
            CustomTabsTerminalWindow.withTabReorder(tab) {
                _ = previous.addTabbedWindowSafely(tab, ordered: .above)
            }
        }

        let selected = windows.indices.contains(selectedTab) ? windows[selectedTab] : first
        selected.makeKeyAndOrderFront(nil)
    }

    private func restoreTab(_ archive: Data) -> NSWindow? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }

        var restored: NSWindow?
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: unarchiver
        ) { window, _ in
            restored = window
        }

        return restored
    }
}
