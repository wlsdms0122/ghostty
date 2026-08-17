import AppKit
import Combine

/// A snapshot of a single tab, as rendered by the custom tab bar.
struct CustomTabItem: Identifiable, Equatable {
    /// Identity is the window itself, since a tab *is* a window in AppKit's tab group.
    let id: ObjectIdentifier
    let title: String
    let color: TerminalTabColor
    let groupID: UUID?
    let isSelected: Bool
}

/// A run of tabs sharing a group, as rendered by the bar.
///
/// Ungrouped tabs form the default section — a group in every respect except that it
/// has no metadata and can't be removed. Modeling them that way avoids a second set of
/// rules for "tabs that aren't in a group".
struct CustomTabSection: Identifiable, Equatable {
    /// The default section has no group, so the group id can't be the identity here.
    var id: UUID { group?.id ?? Self.defaultID }

    let group: CustomTabGroup?
    let tabs: [CustomTabItem]

    /// Whether this is the section being worked in — the one drawn lit, the one a new
    /// tab lands in, and the one every tab action counts through. Every section shows
    /// its tabs either way.
    let isActive: Bool

    var name: String { group?.name ?? "Default" }
    var color: TerminalTabColor { group?.color ?? .none }

    static let defaultID = UUID()
}

/// Reads the native tab group and republishes it for the custom tab bar to render.
///
/// The native `NSWindowTabGroup` remains the source of truth. This model never owns
/// tab state: it observes the group, and every action it exposes forwards to the same
/// AppKit call the native tab bar would have made. That keeps `new_tab`, state
/// restoration, AppleScript and undo working untouched.
class CustomTabBarModel: ObservableObject {
    /// Posted when something the tab bar renders (title, color) changes on a window.
    static let tabsDidChange = Notification.Name("CustomTabBarTabsDidChange")

    @Published private(set) var tabs: [CustomTabItem] = []

    /// Tabs clustered by group, in bar order. Ungrouped tabs come first as a section
    /// with no group.
    @Published private(set) var sections: [CustomTabSection] = []

    /// Which tab of the scope to read the selection through.
    ///
    /// A hint, not the model's identity — that is `scopeID`, and the membership follows
    /// from it. Any member gives the same window list; the front one also gives the
    /// right selection, so this says which one is in front. It is allowed to be stale or
    /// nil: `members` is what decides whether it still counts.
    weak var selectionHint: NSWindow?

    /// The scope this model serves. Everything it reads is derived from this.
    private(set) var scopeID = UUID()

    /// The windows whose tabs this model describes.
    ///
    /// Derived from the scope rather than reached through one window. A window can leave
    /// the scope while the model is still holding it — that's what "Move Tab to New
    /// Window" does — and reading the tab group through it then describes the window it
    /// left for, not this one.
    var members: [CustomTabsTerminalWindow] {
        NSApp.windows.compactMap { $0 as? CustomTabsTerminalWindow }
            .filter { $0.tabScopeID == scopeID }
    }

    /// The member to read the tab group and selection from.
    private var reference: NSWindow? {
        if let hint = selectionHint as? CustomTabsTerminalWindow, hint.tabScopeID == scopeID {
            return hint
        }
        return members.first
    }

    private static var models: [UUID: CustomTabBarModel] = [:]

    /// The model for a scope, created on first use.
    static func model(for scopeID: UUID) -> CustomTabBarModel {
        if let existing = models[scopeID] { return existing }
        let model = CustomTabBarModel()
        model.scopeID = scopeID
        models[scopeID] = model
        return model
    }

    /// Drop models whose windows have all gone. See
    /// `CustomTabGroupRegistry.discardStoresWithoutWindows`.
    static func discardModelsWithoutWindows() {
        let live = Set(NSApp.windows.compactMap { ($0 as? CustomTabsTerminalWindow)?.tabScopeID })
        models = models.filter { live.contains($0.key) }
    }

    /// Group state for this scope. Two windows don't list each other's groups or follow
    /// each other into one.
    var registry: CustomTabGroupRegistry { .store(for: scopeID) }

    private weak var observedTabGroup: NSWindowTabGroup?
    private var windowsObservation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var refreshScheduled = false

    init() {
        let center = NotificationCenter.default
        for name: Notification.Name in [
            NSWindow.didBecomeMainNotification,
            NSWindow.didBecomeKeyNotification,
            TerminalWindow.terminalWillCloseNotification,
            Self.tabsDidChange,
            CustomTabGroupRegistry.didChange,
        ] {
            tokens.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setNeedsRefresh()
            })
        }
    }

    deinit {
        windowsObservation?.invalidate()
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Reading

    /// Ask for a refresh at the end of the current runloop turn.
    ///
    /// One user action fires several notifications — opening a tab changes the window
    /// list, the key window, the title and the group assignment — and refreshing on each
    /// starts a separate layout animation, so the bar visibly stutters through the
    /// intermediate states. Coalescing them means one settled snapshot and one
    /// animation.
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// Rebuild the published snapshot from the tab group. Cheap and idempotent: the
    /// snapshot is Equatable so an unchanged group publishes nothing.
    func refresh() {
        // Never publish from inside a tab insert. Halfway through one the new tab is in
        // the window list but hasn't been given its group yet, so a snapshot taken there
        // shows it — and with it the whole bar — as belonging to the default section.
        // Every caller reaching this point is followed by a settled refresh, so dropping
        // back to the coalesced one loses nothing.
        guard !CustomTabsTerminalWindow.isInsertingTab else {
            setNeedsRefresh()
            return
        }

        guard let window = reference else {
            if !tabs.isEmpty { tabs = [] }
            if !sections.isEmpty { sections = [] }
            return
        }

        rebindObservationIfNeeded()

        // A window with no tab group is a lone window, which is still a single tab
        // as far as the bar is concerned.
        let windows = window.tabGroup?.windows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window

        let next = windows.map { w in
            CustomTabItem(
                id: ObjectIdentifier(w),
                // A tab exists before its shell has said anything, so the title can be
                // empty for a moment. Showing a blank tab that then fills in reads as a
                // glitch; a placeholder is replaced by the real title instead.
                title: w.title.isEmpty ? "Terminal" : w.title,
                color: (w as? TerminalWindow)?.tabColor ?? .none,
                groupID: (w as? CustomTabsTerminalWindow)?.customTabGroupID,
                isSelected: w === selected)
        }

        if next != tabs { tabs = next }

        // Remember where we are in the group we're looking at, so coming back to it
        // returns here instead of to its first tab.
        registry.recordSelection(selected)

        // An empty group stays "active" only until focus lands on a real tab.
        //
        // Judged against the key window, not this model's idea of what's selected:
        // every window runs its own model and refreshes on the same notifications, and
        // one whose window isn't in a tab group answers this question about itself —
        // which would drop the pending group on someone else's behalf.
        //
        // Only a *tab* can answer it, though. A menu, a sheet or a panel takes key away
        // without focus having gone anywhere — so reading key at that moment says the
        // user left the group when all they did was open a context menu, and the bar
        // jumps to whichever group the focused tab belongs to.
        let registry = self.registry
        if let pending = registry.pendingActive,
           let anchor = pending.anchor,
           let key = NSApp.keyWindow as? CustomTabsTerminalWindow,
           key.tabScopeID == scopeID,
           ObjectIdentifier(key) != anchor {
            registry.pendingActive = nil
        }

        let nextSections = sections(
            for: next,
            among: windows,
            activeGroupID: activeGroupID)
        if nextSections != sections { sections = nextSections }
    }

    /// The group showing in the bar right now.
    ///
    /// One definition, shared with every action that has to agree with what's drawn —
    /// see `CustomTabsTerminalWindow.visibleTabbedWindows`. Derived from the focused
    /// tab, which can't disagree with the screen; the exception is an empty group, which
    /// has no tab to derive from and so is held explicitly.
    var activeGroupID: UUID? {
        if let pending = registry.pendingActive { return pending.groupID }
        guard let selected = reference?.tabGroup?.selectedWindow ?? reference else { return nil }
        return groupID(of: selected)
    }

    private func groupID(of window: NSWindow) -> UUID? {
        guard let id = (window as? CustomTabsTerminalWindow)?.customTabGroupID else { return nil }
        // A group whose metadata is gone is treated as no group at all.
        return registry.group(id) == nil ? nil : id
    }

    /// Cluster tabs into their groups, preserving bar order.
    ///
    /// Group members are kept adjacent when they're assigned, but a window can still
    /// land between them (dragged in from elsewhere, restored). We cluster by group id
    /// rather than assuming adjacency, so the bar can't render one group as two.
    private func sections(
        for tabs: [CustomTabItem],
        among windows: [NSWindow],
        activeGroupID: UUID?
    ) -> [CustomTabSection] {
        var result: [CustomTabSection] = []

        // The default section is always present, even with nothing in it, so there's
        // always somewhere to drop a tab back to.
        result.append(CustomTabSection(
            group: nil,
            tabs: tabs.filter { groupID(ofItem: $0) == nil },
            isActive: activeGroupID == nil))

        for group in registry.orderedGroups {
            result.append(CustomTabSection(
                group: group,
                tabs: tabs.filter { $0.groupID == group.id },
                isActive: activeGroupID == group.id))
        }

        return result
    }

    private func groupID(ofItem item: CustomTabItem) -> UUID? {
        guard let id = item.groupID else { return nil }
        return registry.group(id) == nil ? nil : id
    }

    /// The tab group hands us a new `windows` array on every tab add/remove/reorder.
    private func rebindObservationIfNeeded() {
        let group = reference?.tabGroup
        guard observedTabGroup !== group else { return }

        windowsObservation?.invalidate()
        observedTabGroup = group

        windowsObservation = group?.observe(\.windows, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                // Membership changed, which is the only fact a scope is made of. Settle
                // that before drawing, so a tab that arrived from another window is
                // already in this scope by the time the bar reads it.
                CustomTabScope.reconcile()
                self?.setNeedsRefresh()
            }
        }
    }

    // MARK: Actions

    /// Select a tab. This is the same call the native tab bar makes, so everything
    /// downstream (focus, restoration, appearance sync) behaves identically.
    func select(_ id: ObjectIdentifier) {
        guard let target = windowFor(id) else { return }
        activate(target)
    }

    /// Bring a tab to the front *and* hand focus back to its terminal.
    ///
    /// Clicking the bar makes our view the first responder, and Ghostty routes actions
    /// like `new_tab` from whichever surface has focus — so without this, switching tabs
    /// leaves keystrokes and new tabs attached to the tab we just left.
    private func activate(_ target: NSWindow) {
        target.makeKeyAndOrderFront(nil)

        guard let controller = target.windowController as? BaseTerminalController,
              let surface = controller.focusedSurface else { return }
        target.makeFirstResponder(surface)
    }

    /// Close a tab through its controller so Ghostty's confirmation and undo apply.
    func close(_ id: ObjectIdentifier) {
        guard let target = windowFor(id) else { return }
        guard let controller = target.windowController as? TerminalController else {
            target.performClose(nil)
            return
        }
        controller.closeTab(self)
    }

    /// Assign a tab color. This is the same assignment the native tab bar's color
    /// palette menu item makes, so restoration and undo behave the same.
    ///
    /// We need our own entry point for it because that palette lives in the native
    /// tab bar's context menu, which the custom style hides.
    func setColor(_ id: ObjectIdentifier, to color: TerminalTabColor) {
        guard let target = windowFor(id) as? TerminalWindow else { return }
        target.tabColor = color
    }

    // MARK: Groups

    /// Groups that can be assigned to from this window's tabs.
    var availableGroups: [CustomTabGroup] {
        registry.orderedGroups
    }

    /// Assign a tab to a group (or to none), then move it next to that group's other
    /// tabs so the cluster stays contiguous.
    func assign(_ id: ObjectIdentifier, to groupID: UUID?) {
        guard let target = windowFor(id) as? CustomTabsTerminalWindow else { return }
        target.customTabGroupID = groupID
        moveAdjacentToGroup(target)
        refresh()
    }

    /// Create a group from a tab. The tab becomes its first member.
    func createGroup(from id: ObjectIdentifier) {
        let existing = registry.orderedGroups.count
        let group = registry.createGroup(name: "Group \(existing + 1)")
        assign(id, to: group.id)
    }

    /// Select a group: activate the tab we were last on within it. Passing nil selects
    /// the default (ungrouped) section.
    func selectGroup(_ groupID: UUID?) {
        let registry = self.registry
        let windows = reference?.tabGroup?.windows ?? []

        let target: NSWindow?
        if let groupID {
            target = registry.windowToActivate(for: groupID, among: windows)
        } else {
            target = registry.defaultWindowToActivate(among: windows)
        }

        guard let target else {
            // An empty group: nothing to focus, so hold it open. The terminal keeps
            // showing the tab it was showing — ⌘T is what fills the group.
            registry.pendingActive = .init(
                groupID: groupID,
                anchor: (reference?.tabGroup?.selectedWindow ?? reference)
                    .map { ObjectIdentifier($0) })
            refresh()
            return
        }

        registry.pendingActive = nil
        activate(target)

        // Focus may not actually move: leaving an empty group returns to the tab that
        // still had focus the whole time, and a window that's already key posts no
        // notification. Nothing would redraw the bar, so the group we just left would
        // stay lit. Refresh directly rather than waiting to be told.
        refresh()
    }

    /// Create a group with nothing in it, ready to receive tabs.
    func createEmptyGroup() {
        let group = registry.createGroup(
            name: "Group \(registry.orderedGroups.count + 1)")
        selectGroup(group.id)
    }

    /// Delete a group. Its tabs fall back to the default section rather than closing —
    /// removing a label shouldn't destroy terminals.
    func deleteGroup(_ groupID: UUID) {
        for window in reference?.tabGroup?.windows ?? [] {
            guard let window = window as? CustomTabsTerminalWindow else { continue }
            if window.customTabGroupID == groupID { window.customTabGroupID = nil }
        }
        registry.removeGroup(groupID)
        refresh()
    }

    /// Move to the next or previous group in bar order, wrapping around.
    func cycleGroup(by delta: Int) {
        // Work from the freshest snapshot: this runs from a key handler, which can fire
        // before an observation has refreshed us.
        refresh()

        guard sections.count > 1 else { return }

        // Take the current position from the section that's actually drawn as active,
        // rather than re-deriving it. Re-deriving could fail to match and silently fall
        // back to the first section, which looked like "the key did nothing" whenever
        // the fallback happened to be where we already were.
        guard let index = sections.firstIndex(where: \.isActive) else { return }

        let next = (index + delta + sections.count) % sections.count
        selectGroup(sections[next].group?.id)
    }

    /// Rename a group. The sheet itself is `CustomTabRenamePrompt`'s — the model owns
    /// what a rename *is*, not what asking for one looks like.
    func promptRenameGroup(_ groupID: UUID) {
        guard let window = reference else { return }
        guard let group = registry.group(groupID) else { return }

        CustomTabRenamePrompt.present(name: group.name, over: window) { [weak self] name in
            self?.renameGroup(groupID, to: name)
        }
    }

    /// Rename a tab. Forwards to Ghostty's own title prompt, which owns the override
    /// title and its restoration.
    func promptRenameTab(_ id: ObjectIdentifier) {
        guard let controller = windowFor(id)?.windowController as? TerminalController else { return }
        controller.promptTabTitle()
    }

    func renameGroup(_ groupID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        registry.rename(groupID, to: trimmed)
        refresh()
    }

    func setGroupColor(_ groupID: UUID, to color: TerminalTabColor) {
        registry.setColor(groupID, to: color)
        refresh()
    }

    // MARK: Reordering

    /// Move a tab so it sits just before `target`.
    func moveTab(_ id: ObjectIdentifier, before target: ObjectIdentifier) {
        move(id, relativeTo: target, ordered: .below)
    }

    /// Move a tab so it sits just after `target`. Needed for dropping at the very end,
    /// where there's no following tab to sit before.
    func moveTab(_ id: ObjectIdentifier, after target: ObjectIdentifier) {
        move(id, relativeTo: target, ordered: .above)
    }

    private func move(
        _ id: ObjectIdentifier,
        relativeTo target: ObjectIdentifier,
        ordered: NSWindow.OrderingMode
    ) {
        guard id != target else { return }
        guard let moved = windowFor(id), let anchor = windowFor(target) else { return }
        guard let tabGroup = moved.tabGroup else { return }
        guard let movedIndex = tabGroup.windows.firstIndex(of: moved),
              let anchorIndex = tabGroup.windows.firstIndex(of: anchor) else { return }

        // Already where it's being asked to go.
        if ordered == .below && movedIndex + 1 == anchorIndex { return }
        if ordered == .above && anchorIndex + 1 == movedIndex { return }

        // A tab dragged onto another tab joins that tab's group. Without this, dropping
        // across a group boundary would leave the bar showing a tab inside a cluster it
        // doesn't belong to.
        if let moved = moved as? CustomTabsTerminalWindow,
           let anchor = anchor as? CustomTabsTerminalWindow {
            moved.customTabGroupID = anchor.customTabGroupID
        }

        let wasSelected = tabGroup.selectedWindow === moved

        CustomTabsTerminalWindow.withTabReorder(moved) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tabGroup.removeWindow(moved)
            anchor.addTabbedWindowSafely(moved, ordered: ordered)
            if wasSelected { moved.makeKey() }
            NSAnimationContext.endGrouping()
        }

        refresh()
    }

    /// Move a group so it sits just before `target` in the bar.
    func moveGroup(_ id: UUID, before target: UUID?) {
        registry.moveGroup(id, before: target)
        refresh()
    }

    /// Move a window so it sits directly after the last other member of its group.
    ///
    /// This is the same remove/re-add dance `move_tab` performs, which is why the tab
    /// group stays consistent: we're reordering through AppKit, not around it.
    private func moveAdjacentToGroup(_ moved: CustomTabsTerminalWindow) {
        guard let groupID = moved.customTabGroupID else { return }
        guard let tabGroup = moved.tabGroup else { return }

        let members = tabGroup.windows.filter {
            $0 !== moved && ($0 as? CustomTabsTerminalWindow)?.customTabGroupID == groupID
        }
        guard let anchor = members.last else { return }

        // Already in place.
        if let movedIndex = tabGroup.windows.firstIndex(of: moved),
           let anchorIndex = tabGroup.windows.firstIndex(of: anchor),
           movedIndex == anchorIndex + 1 {
            return
        }

        let wasSelected = tabGroup.selectedWindow === moved

        CustomTabsTerminalWindow.withTabReorder(moved) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tabGroup.removeWindow(moved)
            anchor.addTabbedWindowSafely(moved, ordered: .above)
            if wasSelected { moved.makeKey() }
            NSAnimationContext.endGrouping()
        }
    }

    /// The window backing a rendered tab. The context menu needs it to target the same
    /// controller AppKit's own tab menu would have.
    func window(for id: ObjectIdentifier) -> NSWindow? {
        windowFor(id)
    }

    private func windowFor(_ id: ObjectIdentifier) -> NSWindow? {
        let windows = reference?.tabGroup?.windows ?? [reference].compactMap { $0 }
        return windows.first { ObjectIdentifier($0) == id }
    }
}
