import AppKit

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        main.addSubmenu("Loupe", [
            item("About Loupe", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Loupe", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Loupe", #selector(NSApplication.terminate(_:)), "q"),
        ])

        main.addSubmenu("File", [
            item("Open…", #selector(AppDelegate.openDocument(_:)), "o"),
            item("Open from Clipboard", #selector(AppDelegate.openFromClipboard(_:)), "v", [.command, .shift]),
            item("Reload", #selector(DocumentWindowController.reloadDocument(_:)), "r"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])

        main.addSubmenu("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy Value", #selector(NSText.copy(_:)), "c"),
            item("Copy Key", #selector(DocumentWindowController.copyKey(_:)), "c", [.command, .option]),
            item("Copy Path", #selector(DocumentWindowController.copyPath(_:)), "c", [.command, .shift]),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(DocumentWindowController.focusSearch(_:)), "f"),
            item("Find Next", #selector(DocumentWindowController.findNextMatch(_:)), "g"),
            item("Find Previous", #selector(DocumentWindowController.findPreviousMatch(_:)), "g", [.command, .shift]),
        ])

        let biggerAlias = item("Increase Font Size", #selector(AppDelegate.increaseFontSize(_:)), "=")
        biggerAlias.isHidden = true
        biggerAlias.allowsKeyEquivalentWhenHidden = true
        let appearance = NSMenu(title: "Appearance")
        for (index, mode) in AppearanceMode.allCases.enumerated() {
            let entry = item(mode.title, #selector(AppDelegate.setAppearanceMode(_:)))
            entry.tag = index
            appearance.addItem(entry)
        }
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance

        main.addSubmenu("View", [
            item("Increase Font Size", #selector(AppDelegate.increaseFontSize(_:)), "+"),
            biggerAlias,
            item("Decrease Font Size", #selector(AppDelegate.decreaseFontSize(_:)), "-"),
            item("Actual Size", #selector(AppDelegate.resetFontSize(_:)), "0"),
            .separator(),
            appearanceItem,
            .separator(),
            item("Expand Selection", #selector(DocumentWindowController.expandSelected(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            item("Collapse All", #selector(DocumentWindowController.collapseAll(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
        ])

        let window = main.addSubmenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = window
        return main
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

private extension NSMenu {
    @discardableResult
    func addSubmenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        addItem(holder)
        return menu
    }
}
