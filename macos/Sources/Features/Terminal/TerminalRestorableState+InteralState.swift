import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Version 8 (fork: custom tab groups)
        let customTabScopeID: UUID?
        let customTabGroupID: UUID?

        /// Every group of the window's scope, in bar order.
        ///
        /// Carried by each tab rather than stored once for the window: restoration hands
        /// tabs back one at a time with no say in the order, so there's no "first" tab to
        /// put it on. Each one restores the same list into the same scope, and the ones
        /// after the first are no-ops.
        let customTabGroups: [CustomTabGroup]?
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            customTabScopeID: (controller.window as? CustomTabsTerminalWindow)?.tabScopeID,
            customTabGroupID: (controller.window as? CustomTabsTerminalWindow)?.customTabGroupID,
            customTabGroups: (controller.window as? CustomTabsTerminalWindow)?
                .groupRegistry.orderedGroups,
        )
    }
}
