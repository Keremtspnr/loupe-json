import AppKit

/// Colors for both appearances. Every color is dynamic, so views redraw correctly
/// when the system or the user switches between light and dark.
///
/// Dark: warm keys, teal strings, mint numbers, lavender literals on charcoal.
/// Light: deeper tones of the same hues.
enum Palette {
    static let background = dynamic(light: 0xFBFBFA, dark: 0x212225)
    static let barBackground = dynamic(light: 0xF1F2F4, dark: 0x2B2E35)
    static let separator = dynamic(light: 0xDDE0E4, dark: 0x17181B)
    static let selection = dynamic(light: 0xDCE7F6, dark: 0x2F3B4C)
    static let guide = dynamic(light: 0xD0D4DA, dark: 0x45494F)

    static let key = dynamic(light: 0x7A4B0F, dark: 0xE4DBC3)
    static let index = dynamic(light: 0x9A6300, dark: 0xE8D19B)
    static let string = dynamic(light: 0x0E6A74, dark: 0xB4D6DA)
    static let number = dynamic(light: 0x18784A, dark: 0xA7DABD)
    static let literal = dynamic(light: 0x6A4CB8, dark: 0xBCAEE2)
    static let brace = dynamic(light: 0x56617A, dark: 0xAAB1C4)
    static let punctuation = dynamic(light: 0x8A9099, dark: 0x8F969D)
    static let dim = dynamic(light: 0xA2A8B0, dark: 0x6C7279)
    static let invalid = dynamic(light: 0xC62828, dark: 0xF07178)

    static let match = dynamic(light: 0xFFE89A, dark: 0x5C4B12)
    static let currentMatch = dynamic(light: 0xFF9E1B, dark: 0xF2A91E)
    static let currentMatchText = dynamic(light: 0x1A1A1A, dark: 0x1A1A1A)

    static let statusBackground = dynamic(light: 0x2F6AA3, dark: 0x27547B)
    static let statusText = dynamic(light: 0xFFFFFF, dark: 0xDCEAF6)
    static let emptyText = dynamic(light: 0x9AA0A8, dark: 0x6C7279)

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        }
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// App-wide view settings, persisted in UserDefaults. Posts `changed` on every update.
@MainActor
final class Preferences {
    static let shared = Preferences()
    static let changed = Notification.Name("LoupePreferencesChanged")

    static let defaultFontSize: CGFloat = 13
    static let fontSizeRange: ClosedRange<CGFloat> = 9...32

    private let defaults = UserDefaults.standard

    var fontSize: CGFloat {
        didSet {
            fontSize = min(max(fontSize.rounded(), Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            guard fontSize != oldValue else { return }
            defaults.set(Double(fontSize), forKey: "fontSize")
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "appearance")
            applyAppearance()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    private init() {
        let stored = defaults.double(forKey: "fontSize")
        fontSize = stored > 0 ? CGFloat(stored) : Self.defaultFontSize
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    }

    func applyAppearance() {
        NSApp.appearance = appearanceMode.appearance
    }

    // Derived metrics.
    var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    var rowHeight: CGFloat { (fontSize * 1.85).rounded() }
    var indentation: CGFloat { (fontSize * 1.6).rounded() }
}

/// A plain view filled with a (dynamic) color.
final class ColorView: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}
