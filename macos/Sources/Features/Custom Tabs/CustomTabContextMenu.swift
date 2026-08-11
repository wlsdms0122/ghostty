import AppKit
import SwiftUI

/// Builds the tab context menu for the custom tab bar.
///
/// Upstream doesn't build this menu — AppKit supplies it when you right-click a native
/// tab, and Ghostty only appends to it. Hiding the native tab bar takes that menu away
/// with it, so we assemble the same list ourselves and point each item at the same
/// action AppKit's version used.
enum CustomTabContextMenu {
    static func menu(
        for window: NSWindow,
        model: CustomTabBarModel,
        tab: CustomTabItem
    ) -> NSMenu {
        let menu = NSMenu()
        let controller = window.windowController as? TerminalController

        add(to: menu, title: "Close Tab", symbol: "xmark", target: controller,
            action: #selector(TerminalController.closeTab(_:)))
        add(to: menu, title: "Close Other Tabs", symbol: "xmark", target: controller,
            action: #selector(TerminalController.closeOtherTabs(_:)))
        add(to: menu, title: "Close Tabs to the Right", symbol: "xmark", target: controller,
            action: #selector(TerminalController.closeTabsOnTheRight(_:)))

        // These two are AppKit's own window actions, so they target the window.
        add(to: menu, title: "Move Tab to New Window", symbol: "rectangle.badge.plus",
            target: window, action: #selector(NSWindow.moveTabToNewWindow(_:)))
        add(to: menu, title: "Show All Tabs", symbol: nil,
            target: window, action: #selector(NSWindow.toggleTabOverview(_:)))

        menu.addItem(.separator())

        add(to: menu, title: "Rename Tab...", symbol: "pencil.line", target: nil, action: nil) {
            model.promptRenameTab(tab.id)
        }

        menu.addItem(groupItem(model: model, tab: tab))
        menu.addItem(.separator())

        // The color palette is a hosted view, matching the native menu's swatch grid.
        let paletteItem = NSMenuItem()
        paletteItem.view = paletteView(selected: tab.color) { color in
            model.setColor(tab.id, to: color)
        }
        menu.addItem(paletteItem)

        return menu
    }

    /// The group header's menu. The default section has no metadata, so it gets nothing.
    static func groupMenu(for section: CustomTabSection, model: CustomTabBarModel) -> NSMenu? {
        guard let group = section.group else { return nil }

        let menu = NSMenu()
        add(to: menu, title: "Rename Group", symbol: "pencil.line", target: nil, action: nil) {
            model.promptRenameGroup(group.id)
        }

        let colorItem = NSMenuItem(title: "Group Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        let paletteItem = NSMenuItem()
        paletteItem.view = paletteView(selected: group.color) { color in
            model.setGroupColor(group.id, to: color)
        }
        colorMenu.addItem(paletteItem)
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        menu.addItem(.separator())
        add(to: menu, title: "Delete Group", symbol: "trash", target: nil, action: nil) {
            model.deleteGroup(group.id)
        }

        return menu
    }

    // MARK: Items

    private static func groupItem(model: CustomTabBarModel, tab: CustomTabItem) -> NSMenuItem {
        let item = NSMenuItem(title: "Tab Group", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        add(to: submenu, title: "New Group", symbol: "plus", target: nil, action: nil) {
            model.createGroup(from: tab.id)
        }
        submenu.addItem(.separator())

        for group in model.availableGroups {
            let groupItem = add(
                to: submenu, title: group.name, symbol: nil, target: nil, action: nil
            ) {
                model.assign(tab.id, to: group.id)
            }
            groupItem.state = group.id == tab.groupID ? .on : .off
        }

        if tab.groupID != nil {
            submenu.addItem(.separator())
            add(to: submenu, title: "Remove from Group", symbol: nil, target: nil, action: nil) {
                model.assign(tab.id, to: nil)
            }
        }

        item.submenu = submenu
        return item
    }

    @discardableResult
    private static func add(
        to menu: NSMenu,
        title: String,
        symbol: String?,
        target: AnyObject?,
        action: Selector?,
        handler: (() -> Void)? = nil
    ) -> NSMenuItem {
        let item: NSMenuItem
        if let handler {
            item = ClosureMenuItem(title: title, handler: handler)
        } else {
            item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
        }

        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }

        menu.addItem(item)
        return item
    }

    private static func paletteView(
        selected: TerminalTabColor,
        onSelect: @escaping (TerminalTabColor) -> Void
    ) -> NSView {
        let hostingView = NSHostingView(rootView: TabColorMenuView(
            selectedColor: selected,
            onSelect: onSelect))
        hostingView.frame.size = hostingView.intrinsicContentSize
        return hostingView
    }
}

/// A menu item that runs a closure, so items backed by our own model don't each need
/// an `@objc` selector on some controller.
private class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler()
    }
}
