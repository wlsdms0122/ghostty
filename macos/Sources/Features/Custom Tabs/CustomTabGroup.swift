import AppKit

/// A user-defined grouping of tabs, drawn as a labeled cluster in the custom tab bar.
///
/// Groups exist purely in our UI layer. AppKit's tab group knows nothing about them:
/// membership is a property on the window, and the ordering that keeps a group's tabs
/// adjacent is expressed through the same reordering calls `move_tab` makes.
struct CustomTabGroup: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var color: TerminalTabColor

    init(id: UUID = UUID(), name: String, color: TerminalTabColor = .none) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// Group metadata and selection memory for one window's tabs.
///
/// Scoped to a window rather than the app. Groups organize the tabs in front of you, so
/// a second window listing the first one's groups — and following it into an empty one —
/// is two windows sharing one state, not two windows doing the same thing. It also gave
/// ⌘N a way to open onto a group it had nothing to do with.
///
/// State lives here rather than on the window because a group spans several of them and
/// any one member can close at any time. Windows hold only their group's id, and their
/// scope id says which store that id means.
class CustomTabGroupRegistry {
    /// Posted when group metadata changes so open tab bars can redraw.
    ///
    /// Sent app-wide rather than per scope: a bar refreshing when a different window's
    /// groups changed costs one comparison and publishes nothing, and scoping the
    /// notification would mean every observer having to re-derive its scope to filter.
    static let didChange = Notification.Name("CustomTabGroupRegistryDidChange")

    private static var stores: [UUID: CustomTabGroupRegistry] = [:]

    /// The store for a scope, created on first use.
    ///
    /// Keyed by the scope itself, not by a window. A window is only ever a way of naming
    /// one, and it stops naming the right one the moment it changes tab groups — which
    /// is how a model came to read its groups out of the store belonging to a scope it
    /// had left.
    static func store(for scope: UUID) -> CustomTabGroupRegistry {
        if let existing = stores[scope] { return existing }
        let store = CustomTabGroupRegistry()
        stores[scope] = store
        return store
    }

    /// Drop stores whose windows have all gone.
    ///
    /// Scope ids are ours, so nothing reclaims them for us — without this a session that
    /// opens and closes windows keeps every group it ever made.
    static func discardStoresWithoutWindows() {
        let live = Set(NSApp.windows.compactMap { ($0 as? CustomTabsTerminalWindow)?.tabScopeID })
        stores = stores.filter { live.contains($0.key) }
    }

    private var groups: [UUID: CustomTabGroup] = [:]

    /// Bar order of the groups. Kept explicitly rather than derived from window order,
    /// so a group can be dragged somewhere without dragging all of its tabs there.
    private var groupOrder: [UUID] = []

    /// The tab last looked at in each group. Selecting a group returns here rather
    /// than to its first tab, so switching back and forth keeps its place.
    private var lastSelected: [UUID: ObjectIdentifier] = [:]

    /// Same memory, for the default (ungrouped) section.
    private var defaultLastSelected: ObjectIdentifier?

    /// A group the user selected that has no tabs to focus.
    ///
    /// Normally the active group is derived from the focused tab, which can't lie. An
    /// empty group has no tab to focus, so it needs to be held explicitly — otherwise
    /// selecting one would do nothing visible and there'd be no way to open a tab into
    /// it. Cleared as soon as focus moves to a real tab.
    ///
    /// This is a struct rather than a bare `UUID?` because the default section *is* a
    /// nil group id: with one optional, "hold the default section open" and "nothing is
    /// being held open" are the same value, and an empty default section could never be
    /// selected while an empty named group could.
    struct PendingActive {
        /// nil means the default section.
        let groupID: UUID?

        /// The tab that was focused when this was set, used to notice when focus has
        /// moved on.
        let anchor: ObjectIdentifier?
    }

    var pendingActive: PendingActive?

    // MARK: Groups

    func group(_ id: UUID?) -> CustomTabGroup? {
        guard let id else { return nil }
        return groups[id]
    }

    /// Every group in this scope, in bar order.
    ///
    /// Empty groups are included. A group is a place the user made to put tabs in, so
    /// it has to exist before it has any — hiding it until it's populated would make
    /// "create a group, then move tabs into it" impossible.
    var orderedGroups: [CustomTabGroup] {
        groupOrder.compactMap { groups[$0] }
    }

    func removeGroup(_ id: UUID) {
        groups.removeValue(forKey: id)
        groupOrder.removeAll { $0 == id }
        lastSelected.removeValue(forKey: id)
        if pendingActive?.groupID == id { pendingActive = nil }
        notify()
    }

    @discardableResult
    func createGroup(name: String, color: TerminalTabColor = .none) -> CustomTabGroup {
        let group = CustomTabGroup(name: name, color: color)
        groups[group.id] = group
        groupOrder.append(group.id)
        notify()
        return group
    }

    /// Move a group so it sits just before `target`, or to the end when target is nil.
    func moveGroup(_ id: UUID, before target: UUID?) {
        guard id != target else { return }
        guard let from = groupOrder.firstIndex(of: id) else { return }

        groupOrder.remove(at: from)

        if let target, let to = groupOrder.firstIndex(of: target) {
            groupOrder.insert(id, at: to)
        } else {
            groupOrder.append(id)
        }

        notify()
    }

    /// Take in a group defined in another scope, keeping its id.
    ///
    /// Used when a tab leaves for a window of its own: membership is on the window and
    /// travels with it, so without the definition following, the tab would arrive
    /// pointing at a group this scope has never heard of and show up ungrouped.
    func adopt(_ group: CustomTabGroup) {
        guard groups[group.id] == nil else { return }
        groups[group.id] = group
        groupOrder.append(group.id)
        notify()
    }

    func rename(_ id: UUID, to name: String) {
        guard var group = groups[id] else { return }
        group.name = name
        groups[id] = group
        notify()
    }

    func setColor(_ id: UUID, to color: TerminalTabColor) {
        guard var group = groups[id] else { return }
        group.color = color
        groups[id] = group
        notify()
    }

    // MARK: Selection Memory

    func recordSelection(_ window: NSWindow) {
        guard let id = (window as? CustomTabsTerminalWindow)?.customTabGroupID,
              groups[id] != nil else {
            defaultLastSelected = ObjectIdentifier(window)
            return
        }
        lastSelected[id] = ObjectIdentifier(window)
    }

    /// The window to activate when the group is selected: the one last looked at, or
    /// the group's first tab if that one is gone.
    func windowToActivate(for id: UUID, among windows: [NSWindow]) -> NSWindow? {
        let members = windows.filter {
            ($0 as? CustomTabsTerminalWindow)?.customTabGroupID == id
        }

        if let remembered = lastSelected[id],
           let window = members.first(where: { ObjectIdentifier($0) == remembered }) {
            return window
        }

        return members.first
    }

    /// Same as `windowToActivate(for:among:)` but for the default section, whose
    /// members are the windows without a live group.
    func defaultWindowToActivate(among windows: [NSWindow]) -> NSWindow? {
        let members = windows.filter { window in
            guard let id = (window as? CustomTabsTerminalWindow)?.customTabGroupID else { return true }
            return groups[id] == nil
        }

        if let remembered = defaultLastSelected {
            if let window = members.first(where: { ObjectIdentifier($0) == remembered }) {
                return window
            }
            // The remembered tab is gone. Drop it rather than leave the value to be
            // matched by whatever the allocator hands out that address next.
            defaultLastSelected = nil
        }

        return members.first
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// Keeps scope membership true to what AppKit actually did with the windows.
///
/// A scope is "the tabs of one window", and the only fact that decides it is which tab
/// group a window is in. That fact changes by paths we don't own — merging all windows,
/// the tab overview, restoration — so a scope that is *assigned* at the one entry point
/// we can hook (`addTabbedWindow`) is only ever a guess, and every path that misses the
/// hook leaves two scopes inside one tab group, or one scope spread across two windows.
///
/// This derives it instead: partition the windows by tab group, then make each partition
/// agree on one scope. Nothing has to be told that a tab was pulled out or merged in —
/// the partitioning already says so.
enum CustomTabScope {
    /// Bring every window's scope back in line with its tab group.
    ///
    /// Cheap and idempotent: with nothing moved it assigns nothing.
    static func reconcile() {
        let windows = NSApp.windows.compactMap { $0 as? CustomTabsTerminalWindow }
        guard !windows.isEmpty else { return }

        // A window with no tab group is a partition of one — it shares its tabs with
        // nobody, which is exactly what a scope of its own means.
        var partitions: [ObjectIdentifier: [CustomTabsTerminalWindow]] = [:]
        for window in windows {
            let key = window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
            partitions[key, default: []].append(window)
        }

        for partition in partitions.values {
            unify(partition)
        }

        // A scope left standing in more than one partition means a tab was taken out of
        // its window. The larger side keeps the scope — it's the one that still holds
        // most of what the scope described — and the rest start fresh.
        var seen: [UUID: [CustomTabsTerminalWindow]] = [:]
        for partition in partitions.values {
            guard let scope = partition.first?.tabScopeID else { continue }
            seen[scope, default: []].append(contentsOf: partition)
        }

        for (scope, members) in seen {
            let sides = Dictionary(grouping: members) {
                $0.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier($0)
            }
            guard sides.count > 1 else { continue }

            let keeping = sides.max { $0.value.count < $1.value.count }?.key
            for (key, side) in sides where key != keeping {
                split(side, from: scope)
            }
        }
    }

    /// Make one tab group's windows share a scope, taking the group definitions of the
    /// ones that arrive from elsewhere with them.
    private static func unify(_ partition: [CustomTabsTerminalWindow]) {
        guard let canonical = partition.first?.tabScopeID else { return }
        guard partition.contains(where: { $0.tabScopeID != canonical }) else { return }

        let destination = CustomTabGroupRegistry.store(for: canonical)
        for window in partition where window.tabScopeID != canonical {
            let source = CustomTabGroupRegistry.store(for: window.tabScopeID)
            for group in source.orderedGroups { destination.adopt(group) }
            window.setTabScope(canonical)
        }
    }

    /// Give windows that have left a scope one of their own, carrying over only the
    /// group definitions their tabs still point at.
    private static func split(_ windows: [CustomTabsTerminalWindow], from scope: UUID) {
        let source = CustomTabGroupRegistry.store(for: scope)
        let carried = windows.compactMap { $0.customTabGroupID }.compactMap { source.group($0) }

        let fresh = UUID()
        let destination = CustomTabGroupRegistry.store(for: fresh)
        for group in carried { destination.adopt(group) }
        for window in windows { window.setTabScope(fresh) }
    }
}
