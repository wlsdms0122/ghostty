import AppKit

/// What a closed tab was, kept for undo. Upstream's undo brings back the terminal and
/// its place in the tab group, but not the tab's group or the title it was renamed to.
///
/// Found again by the tab's surfaces: undo brings a tab back with the same surface
/// objects, which is how it can be told apart from a new one.
final class CustomTabClosedTab {
    /// nil is the default section.
    let groupID: UUID?

    let titleOverride: String?

    /// Weak keys: undo holds a closed tab's surfaces until it expires, and the record
    /// goes when they do.
    private static let records = NSMapTable<Ghostty.SurfaceView, CustomTabClosedTab>
        .weakToStrongObjects()

    init(groupID: UUID?, titleOverride: String?) {
        self.groupID = groupID
        self.titleOverride = titleOverride
    }

    func record(for surfaces: [Ghostty.SurfaceView]) {
        for surface in surfaces {
            Self.records.setObject(self, forKey: surface)
        }
    }

    /// The record of a tab that undo is bringing back, or nil for a new tab.
    static func returning(_ surfaces: [Ghostty.SurfaceView]) -> CustomTabClosedTab? {
        surfaces.lazy.compactMap { records.object(forKey: $0) }.first
    }
}
