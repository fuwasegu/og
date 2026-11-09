import AppKit
import OgCore

/// Appearance the user picked: follow macOS, or force dark / light.
enum ThemeMode: String, CaseIterable {
    case system, dark, light
    var title: String {
        switch self {
        case .system: return "Match System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

extension Notification.Name {
    /// The effective theme (dark/light) or the editor font changed.
    static let ogThemeChanged = Notification.Name("og.themeChanged")
}

/// Colors and fonts. Every color is dynamic (dark / light pair) and resolves against the current
/// appearance, so AppKit redraws pick it up; layer colors are re-applied through `paint(_:)`.
/// Dark is close to GoLand "Dark", light to GoLand "Light".
@MainActor
enum Theme {
    // MARK: Fonts

    static var fontSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "og.fontSize")
        return v > 0 ? CGFloat(v) : 13
    }()
    /// Editor font family; nil = the system monospaced font (SF Mono).
    /// Stored as "" for the system font, so "unset" can still default to JetBrains Mono.
    static var fontFamily: String? = {
        let v = UserDefaults.standard.string(forKey: "og.fontFamily") ?? "JetBrains Mono"
        return v.isEmpty ? nil : v
    }()
    static var editorFont: NSFont {
        if let fam = fontFamily, let f = NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: fontSize) { return f }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    static var editorBoldFont: NSFont {
        NSFontManager.shared.convert(editorFont, toHaveTrait: .boldFontMask)
    }
    static let uiFont = NSFont.systemFont(ofSize: 12)
    static let smallFont = NSFont.systemFont(ofSize: 11)

    /// Installed fixed-pitch families, for the font picker.
    static func monospacedFamilies() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { fam in
            guard let f = fm.font(withFamily: fam, traits: [], weight: 5, size: 13) else { return false }
            return f.isFixedPitch || fm.traits(of: f).contains(.fixedPitchFontMask)
        }.sorted()
    }

    static func setFont(family: String?, size: CGFloat) {
        fontFamily = family
        fontSize = size
        UserDefaults.standard.set(family ?? "", forKey: "og.fontFamily")
        UserDefaults.standard.set(Double(size), forKey: "og.fontSize")
        NotificationCenter.default.post(name: .ogThemeChanged, object: nil)
    }

    // MARK: Mode

    static var mode: ThemeMode {
        get { ThemeMode(rawValue: UserDefaults.standard.string(forKey: "og.theme") ?? "") ?? .dark }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "og.theme")
            applyMode()
        }
    }

    static func applyMode() {
        switch mode {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: Layer colors (CGColor does not follow the appearance by itself)

    private final class Painted {
        weak var view: NSView?
        var background: NSColor?
        var border: NSColor?
        init(_ v: NSView, _ b: NSColor?, _ r: NSColor?) { view = v; background = b; border = r }
    }
    private static var painted: [ObjectIdentifier: Painted] = [:]
    private static var appearanceObservation: NSKeyValueObservation?

    /// Sets a layer-backed view's background / border and keeps them in sync with the theme.
    static func paint(_ view: NSView, background: NSColor? = nil, border: NSColor? = nil) {
        view.wantsLayer = true
        let id = ObjectIdentifier(view)
        let entry: Painted
        if let e = painted[id], e.view === view {
            if let background { e.background = background }
            if let border { e.border = border }
            entry = e
        } else {
            entry = Painted(view, background, border)
            painted[id] = entry
        }
        apply(entry)
    }

    private static func apply(_ e: Painted) {
        guard let v = e.view else { return }
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let b = e.background { v.layer?.backgroundColor = b.cgColor }
            if let r = e.border { v.layer?.borderColor = r.cgColor }
        }
    }

    /// Call once at launch: applies the saved mode and repaints layers when the appearance flips.
    static func start() {
        applyMode()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    painted = painted.filter { $0.value.view != nil }
                    for e in painted.values { apply(e) }
                    NotificationCenter.default.post(name: .ogThemeChanged, object: nil)
                }
            }
        }
    }

    // MARK: Palette

    nonisolated private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    nonisolated private static func dyn(_ dark: UInt32, _ light: UInt32) -> NSColor {
        let d = rgb(dark), l = rgb(light)
        return NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
    }

    static let background = dyn(0x1E1F22, 0xFFFFFF)
    static let panelBackground = dyn(0x282A2C, 0xF7F8FA)
    static let sidebarBackground = dyn(0x232427, 0xF2F3F5)
    static let gutterBackground = background
    static let border = dyn(0x3D4045, 0xDFE1E5)
    static let currentLine = dyn(0x292B30, 0xF5F8FE)
    static let selection = dyn(0x294574, 0xA6D2FF)
    static let text = dyn(0xBCBEC4, 0x080808)
    static let secondaryText = dyn(0x737880, 0x6C707E)
    static let lineNumber = dyn(0x545961, 0xAEB3C2)
    static let accent = dyn(0x3574F0, 0x3574F0)
    static let caret = dyn(0xFFFFFF, 0x000000)

    // Syntax
    static let keyword = dyn(0xCF8E6D, 0x0033B3)
    static let string = dyn(0x6AAB73, 0x067D17)
    static let number = dyn(0x2AACB8, 0x1750EB)
    static let comment = dyn(0x7A7E85, 0x8C8C8C)
    static let function = dyn(0x56A8F5, 0x00627A)
    static let type = dyn(0xE6B878, 0x1D6C8C)
    static let builtin = dyn(0xB28CD9, 0x871094)

    // Status
    static let error = dyn(0xF75454, 0xE55757)
    static let warning = dyn(0xE6B340, 0xB07A00)
    static let info = dyn(0x739ED9, 0x3574F0)
    static let gitAdded = dyn(0x619E66, 0x2F8F3E)
    static let gitModified = dyn(0x548CD9, 0x0A71C9)
    static let gitDeleted = dyn(0x8C8C94, 0x868A91)
    static let gitUntracked = dyn(0xCC7366, 0xC24E3A)
    static let breakpoint = dyn(0xD94040, 0xE55757)
    static let debugLine = dyn(0x2E477A, 0xDCE7FB)
    static let bannerWarning = dyn(0x73591A, 0xF5E3A8)
    static let bannerError = dyn(0x802626, 0xF7C6C6)
    static let bannerText = dyn(0xFFFFFF, 0x1A1A1A)

    /// Foreground color for a lexer token; nil keeps the default text color.
    static func color(for kind: GoTokenKind) -> NSColor? {
        switch kind {
        case .keyword, .constant: return keyword
        case .type, .typeDecl: return type
        case .builtin: return builtin
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .funcDecl: return function
        case .function: return nil
        }
    }
}
