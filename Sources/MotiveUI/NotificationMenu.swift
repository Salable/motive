import AppKit
import MotiveCore

/// The menu-bar component: a status-item icon with a menu for further
/// interaction (show/hide the sprite, open settings, quit — whatever items
/// the host app supplies).
@MainActor
public final class NotificationMenu: NSObject, NSMenuDelegate {
    public struct Item {
        public let title: String
        public let keyEquivalent: String
        public let handler: () -> Void

        public init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
            self.title = title
            self.keyEquivalent = keyEquivalent
            self.handler = handler
        }

        /// A separator line.
        public static let separator = Item(title: "-", handler: {})
    }

    private let statusItem: NSStatusItem
    private var items: [Item]

    public init(symbolName: String = "pawprint.fill", accessibilityLabel: String = "Motive", items: [Item]) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.items = items
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: accessibilityLabel
            )
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    public func setItems(_ items: [Item]) {
        self.items = items
    }

    public func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // Rebuild on open so item titles reflect current state (e.g. "Hide …").
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in items {
            if item.title == "-" {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: item.keyEquivalent)
            menuItem.target = self
            menuItem.representedObject = ItemBox(handler: item.handler)
            menu.addItem(menuItem)
        }
    }

    private final class ItemBox {
        let handler: () -> Void
        init(handler: @escaping () -> Void) { self.handler = handler }
    }

    @objc private func run(_ sender: NSMenuItem) {
        (sender.representedObject as? ItemBox)?.handler()
    }
}
