import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [DocumentWindowController] = []
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.shared.applyAppearance()
        NSApp.mainMenu = MainMenu.build()
        let arguments = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        let urls = pendingURLs + arguments
        pendingURLs = []
        launched = true
        if urls.isEmpty {
            newWindow().showWindow(nil)
        } else {
            urls.forEach(open)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if launched { urls.forEach(open) } else { pendingURLs += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func open(_ url: URL) {
        let controller = reusableWindow() ?? newWindow()
        controller.showWindow(nil)
        controller.open(url: url)
        if let directory = ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_DIR"] {
            controller.runSmokeTest(into: directory)
        }
    }

    private func reusableWindow() -> DocumentWindowController? {
        if let key = NSApp.keyWindow?.windowController as? DocumentWindowController, key.isEmpty { return key }
        return controllers.first { $0.isEmpty && $0.window?.isVisible == true }
    }

    private func newWindow() -> DocumentWindowController {
        let controller = DocumentWindowController()
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        return controller
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }

    // MARK: View settings (shared by all windows)

    @objc func increaseFontSize(_ sender: Any?) { Preferences.shared.fontSize += 1 }
    @objc func decreaseFontSize(_ sender: Any?) { Preferences.shared.fontSize -= 1 }
    @objc func resetFontSize(_ sender: Any?) { Preferences.shared.fontSize = Preferences.defaultFontSize }

    @objc func setAppearanceMode(_ sender: NSMenuItem) {
        Preferences.shared.appearanceMode = AppearanceMode.allCases[sender.tag]
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let preferences = Preferences.shared
        switch menuItem.action {
        case #selector(setAppearanceMode(_:)):
            menuItem.state = AppearanceMode.allCases[menuItem.tag] == preferences.appearanceMode ? .on : .off
        case #selector(increaseFontSize(_:)):
            return preferences.fontSize < Preferences.fontSizeRange.upperBound
        case #selector(decreaseFontSize(_:)):
            return preferences.fontSize > Preferences.fontSizeRange.lowerBound
        case #selector(resetFontSize(_:)):
            return preferences.fontSize != Preferences.defaultFontSize
        default:
            break
        }
        return true
    }

    @objc func openFromClipboard(_ sender: Any?) {
        let controller = reusableWindow() ?? newWindow()
        controller.showWindow(nil)
        controller.openClipboard()
    }
}
