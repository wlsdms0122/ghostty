import AppKit
import SwiftUI

/// `macos-titlebar-style = custom`.
///
/// Hides the native tab bar and draws our own below the titlebar. The native
/// `NSWindowTabGroup` is untouched and remains the source of truth for tab state —
/// this class only swaps what the user sees and forwards interactions back down.
///
/// Inherits the transparent titlebar so the bar sits on the terminal background color.
class CustomTabsTerminalWindow: TransparentTitlebarTerminalWindow {
    /// Identifies our own tab bar accessory. The base class sniffs bottom-layout
    /// accessories to find the *native* tab bar, and ours looks enough like one to be
    /// mistaken for it — tagging it takes us out of that guess entirely.
    private static let accessoryIdentifier = NSUserInterfaceItemIdentifier("_customTabBar")

    /// The bar's state, shared with every other tab in this window.
    ///
    /// One model per scope rather than one per window. Each tab hosts its own copy of
    /// the *view* — a titlebar accessory belongs to exactly one window and there's no
    /// way around that — so opening a tab replaces the bar you're looking at with a
    /// different instance. Two instances reading two models take their snapshots at
    /// their own moments, and any disagreement between them shows up as the bar
    /// lurching at the swap. Sharing the model makes the swap invisible: whatever the
    /// old bar was drawing, the new one is drawing the same thing.
    private lazy var tabBarModel = CustomTabBarModel.model(for: tabScopeID)
    private let tabBarAccessory = NSTitlebarAccessoryViewController()
    private var tabBarHostingView: NonDraggableHostingView<CustomTabBarView>?
    private var groupsObservation: NSObjectProtocol?

    deinit {
        if let groupsObservation {
            NotificationCenter.default.removeObserver(groupsObservation)
        }
    }

    /// Which set of tabs this window belongs to, for the purpose of group state.
    ///
    /// Derived from the tab group, never assigned by hand: `CustomTabScope.reconcile`
    /// partitions the windows by tab group and makes each partition agree. A scope
    /// handed out at the one entry point we can hook is only a guess — merging windows
    /// and the tab overview change tab groups without going through it.
    ///
    /// Ours rather than `NSWindowTabGroup`'s identity because a window has no tab group
    /// until it's tabbed, and a scope keyed on that would move the moment a second tab
    /// appeared, taking the window's groups with it.
    private(set) var tabScopeID = UUID() {
        didSet {
            guard tabScopeID != oldValue else { return }
            invalidateRestorableState()

            // The bar was built against the old scope. Joining another one means a
            // different model, and the view has to be pointed at it — otherwise this tab
            // keeps drawing the groups of the scope it left.
            tabBarModel = CustomTabBarModel.model(for: tabScopeID)
            tabBarModel.selectionHint = self
            tabBarHostingView?.rootView = CustomTabBarView(model: tabBarModel)
            tabBarModel.setNeedsRefresh()
        }
    }

    func setTabScope(_ id: UUID) {
        tabScopeID = id
    }

    /// Group state for this window's tabs.
    var groupRegistry: CustomTabGroupRegistry { .store(for: tabScopeID) }

    /// Rejoin the scope this window had before the app quit.
    ///
    /// Restoration brings tabs back one at a time, each with the scope id it was saved
    /// with, which is how they find each other again — AppKit re-tabs them but nothing
    /// tells us they were ever together.
    func adoptRestoredScope(_ id: UUID) {
        tabScopeID = id
    }

    /// The custom tab group this tab belongs to, if any.
    ///
    /// Membership lives on the window because a tab *is* a window. The group's name and
    /// color live in the scope's `CustomTabGroupRegistry`, since those are shared by
    /// every member.
    var customTabGroupID: UUID? {
        didSet {
            guard customTabGroupID != oldValue else { return }
            NotificationCenter.default.post(name: CustomTabBarModel.tabsDidChange, object: self)
            invalidateRestorableState()
        }
    }

    // MARK: NSWindow

    override var title: String {
        didSet {
            guard title != oldValue else { return }
            NotificationCenter.default.post(name: CustomTabBarModel.tabsDidChange, object: self)
        }
    }

    override var tabColor: TerminalTabColor {
        didSet {
            guard tabColor != oldValue else { return }
            NotificationCenter.default.post(name: CustomTabBarModel.tabsDidChange, object: self)
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        // Note there's deliberately no group assignment here. A window being created is
        // not yet a tab: ⌘N produces one too, and a held-open empty group would be
        // claimed by that new window even though it opens in a tab group of its own —
        // taking the group with it and leaving the window that's holding it open
        // showing a group that has moved elsewhere. A new *tab* gets its group in
        // `addTabbedWindow`, which is the call that makes it one.
        tabBarModel.selectionHint = self

        // A titled window is required for titlebar accessories, the same constraint the
        // base class works under for its own accessories.
        guard styleMask.contains(.titled) else { return }

        // Group definitions live in the scope's store, not on the window, so nothing
        // marks this window's saved state stale when one is renamed, recolored or
        // reordered. Without that mark AppKit has no reason to encode again and the
        // groups come back as they were at the last save — or not at all.
        groupsObservation = NotificationCenter.default.addObserver(
            forName: CustomTabGroupRegistry.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateRestorableState()
        }

        tabBarAccessory.identifier = Self.accessoryIdentifier
        tabBarAccessory.layoutAttribute = .bottom
        // Must be non-draggable: this sits in the titlebar, where AppKit otherwise
        // treats a mouse-down as the start of a window drag and swallows it. That
        // takes clicks, right-clicks and drags away from the bar entirely.
        let hostingView = NonDraggableHostingView(rootView: CustomTabBarView(model: tabBarModel))
        hostingView.frame.size.height = CustomTabBarView.height
        tabBarAccessory.view = hostingView
        tabBarHostingView = hostingView
        addTitlebarAccessoryViewController(tabBarAccessory)
    }

    override func becomeMain() {
        super.becomeMain()
        hideNativeTabBar()
        CustomTabScope.reconcile()

        // The model serves every tab in the scope; tell it which one is in front so its
        // idea of the selection is the one on screen.
        tabBarModel.selectionHint = self
        tabBarModel.refresh()
    }

    override func addTabbedWindow(_ window: NSWindow, ordered: NSWindow.OrderingMode) {
        // Work out the destination group *before* the add: afterwards the new tab is
        // itself in the group and may already be the selected one.
        //
        // The group to join is the one on screen, not this window's. `self` is whatever
        // upstream picked to attach to, which is the current tab under the default
        // setting but the group's *last* tab under `window-new-tab-position = end` —
        // and that one can belong to a different group entirely.
        let destination = groupRegistry.pendingActive.map(\.groupID)
            ?? (tabGroup?.selectedWindow as? CustomTabsTerminalWindow)?.customTabGroupID
            ?? customTabGroupID

        // The add *and* the assignment are bracketed together, so no bar can publish a
        // snapshot from between them. In that window the new tab is already in the tab
        // group but still has no group of its own, which reads as ungrouped — the
        // default section takes over the bar for a frame and its badge ticks up and
        // straight back down on every ⌘T.
        //
        // Suppressing the mid-insert snapshot rather than assigning the group first:
        // AppKit is partway through rewiring the tab group while `super` runs, and doing
        // the assignment ahead of it changes what it sees.
        Self.insertionDepth += 1
        defer { Self.insertionDepth -= 1 }

        super.addTabbedWindow(window, ordered: ordered)

        guard let child = window as? CustomTabsTerminalWindow else { return }

        // A head start, not the authority: the reconciler would work this out from the
        // tab group anyway, but not before the new tab has drawn once from a scope of
        // its own.
        child.setTabScope(tabScopeID)

        // Only fill in a group that isn't already set, so moving an existing tab in
        // here doesn't reassign it.
        guard child.customTabGroupID == nil else { return }

        child.customTabGroupID = destination
    }

    override func close() {
        super.close()

        // After the window is really gone, so the scope it held isn't still counted as
        // in use and the tab left behind isn't read as having been pulled out of it.
        DispatchQueue.main.async {
            CustomTabScope.reconcile()
            CustomTabGroupRegistry.discardStoresWithoutWindows()
            CustomTabBarModel.discardModelsWithoutWindows()
        }
    }

    /// Whether a tab is being inserted into *some* tab group right now.
    ///
    /// Shared rather than per-window because the window that would draw the
    /// half-finished state isn't the one performing the insert: the tab being added
    /// becomes main partway through and publishes from its own bar. AppKit also turns
    /// the runloop during the insert, so a refresh queued earlier can land in the middle
    /// of it — which is why the check lives in the model's `refresh`, not only in the
    /// hooks here.
    static var isInsertingTab: Bool { insertionDepth > 0 }
    private static var insertionDepth = 0

    /// Run a change to the tab group with the bar held still until it's done.
    ///
    /// Reordering is a remove followed by an add, and in between the tab is in no tab
    /// group at all. A snapshot from that gap is missing it, so everything to its right
    /// slides over by its width and back again — worst at the far end of the bar, where
    /// the shift is the whole width of the tab.
    static func withTabGroupHeld<T>(_ body: () -> T) -> T {
        insertionDepth += 1
        defer { insertionDepth -= 1 }
        return body()
    }

    /// Tabs the user can actually see right now: the ones in the active group.
    ///
    /// Read off the bar's model rather than worked out again here. "Which group is
    /// showing" and "which group ids this scope still defines" are the model's to
    /// answer; a second copy of that reasoning drifted from it, and a tab pointing at a
    /// group the scope no longer defines was drawn in the default section while counting
    /// as a scope of one for every action.
    fileprivate var visibleTabbedWindows: [NSWindow]? {
        guard let windows = tabGroup?.windows else { return nil }

        let active = tabBarModel.activeGroupID
        return windows.filter { window in
            guard let tab = window as? CustomTabsTerminalWindow else { return false }
            return groupRegistry.group(tab.customTabGroupID)?.id == active
        }
    }

    /// AppKit's own tab cycling, held to the active group.
    ///
    /// `⌘⇧[` / `⌘⇧]` are Ghostty keybinds *and* system shortcuts for a window with tabs.
    /// Ghostty normally consumes them first, but on key repeat an event can arrive while
    /// focus is still moving and fall through to AppKit — which walks the whole tab
    /// group, straight through the tabs our bar is hiding. That's why holding the key
    /// leaves the group and a single press never does.
    override func selectNextTab(_ sender: Any?) {
        selectTab(offsetBy: 1)
    }

    override func selectPreviousTab(_ sender: Any?) {
        selectTab(offsetBy: -1)
    }

    private func selectTab(offsetBy delta: Int) {
        let windows = tabScope
        guard windows.count > 1 else { return }
        guard let index = windows.firstIndex(of: self)
            ?? tabGroup?.selectedWindow.flatMap({ windows.firstIndex(of: $0) })
        else { return }

        let next = (index + delta + windows.count) % windows.count
        windows[next].makeKeyAndOrderFront(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Group switching. Ghostty's own keybinds are defined in the Zig core and
        // routed through its action system; adding one there would mean changing the
        // core, the C API and the Swift bridge for a macOS-only feature. Handling it
        // at the window keeps the whole feature on our side of the fence.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .control] {
            switch event.charactersIgnoringModifiers {
            case "]":
                tabBarModel.cycleGroup(by: 1)
                return true
            case "[":
                tabBarModel.cycleGroup(by: -1)
                return true
            default:
                break
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)

        // Tab changes rebuild the titlebar, which is also when a fresh tab bar
        // accessory can appear.
        hideNativeTabBar()
        tabBarModel.refresh()
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)

        // AppKit adds the native tab bar as an accessory whenever a second tab shows
        // up. Hide it the moment it arrives so it never flashes.
        if isTabBar(childViewController) {
            childViewController.isHidden = true
        }
    }

    // MARK: Native Tab Bar

    /// Hide the native tab bar by hiding its accessory view controller.
    ///
    /// Note this deliberately does *not* use `toggleTabBar`. AppKit owns tab bar
    /// visibility and forces it back on whenever the group has more than one tab, so
    /// toggling it from an observer spins: we hide, AppKit shows, we hide. Hiding the
    /// accessory instead leaves AppKit's state alone — as far as the tab group is
    /// concerned the bar is still visible, it just has no pixels.
    ///
    /// Idempotent, so it's safe to call from any hook that might have missed one.
    private func hideNativeTabBar() {
        for accessory in titlebarAccessoryViewControllers where isTabBar(accessory) {
            guard !accessory.isHidden else { continue }
            accessory.isHidden = true
        }
    }
}

extension NSWindow {
    /// The tabs a *tab-level* action on this window applies to.
    ///
    /// This is the whole tab group everywhere except the custom titlebar style, where
    /// only the active group's tabs are on screen. Anything that counts, indexes or
    /// sweeps tabs as tabs — go to tab N, move tab, close the others, close the ones to
    /// the right, and the menu validation that decides whether those are available —
    /// reads the set through here, so it acts on the set the user can see.
    ///
    /// *Window-level* actions are not in that list and should not use it: closing the
    /// window, collecting its state for undo, and deciding whether ⌘W closes a tab or
    /// the window all concern every tab the window holds, hidden or not.
    ///
    /// One entry point rather than a substitution at each call site: the two are
    /// interchangeable under the stock styles, so a call site that keeps reading
    /// `tabGroup.windows` looks correct and stays correct until someone collapses a
    /// group. "Close Other Tabs" reaching into a collapsed group and killing terminals
    /// the user couldn't see was exactly that.
    ///
    /// Falls back to `[self]` for a lone window so callers get the same "just me" answer
    /// whether or not a tab group exists.
    var tabScope: [NSWindow] {
        (self as? CustomTabsTerminalWindow)?.visibleTabbedWindows ?? tabGroup?.windows ?? [self]
    }
}
