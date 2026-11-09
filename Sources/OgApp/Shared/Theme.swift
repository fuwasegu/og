import AppKit

/// Dark theme close to JetBrains Fleet / GoLand "Dark".
@MainActor
enum Theme {
    static var fontSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "og.fontSize")
        return v > 0 ? CGFloat(v) : 13
    }()
    static var editorFont: NSFont {
        NSFont(name: "JetBrains Mono", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    static var editorBoldFont: NSFont {
        NSFontManager.shared.convert(editorFont, toHaveTrait: .boldFontMask)
    }
    static let uiFont = NSFont.systemFont(ofSize: 12)
    static let smallFont = NSFont.systemFont(ofSize: 11)

    static let background = NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1)      // #1E1F22
    static let panelBackground = NSColor(srgbRed: 0.157, green: 0.161, blue: 0.173, alpha: 1) // #282A2C
    static let sidebarBackground = NSColor(srgbRed: 0.137, green: 0.141, blue: 0.153, alpha: 1)
    static let gutterBackground = background
    static let border = NSColor(srgbRed: 0.24, green: 0.25, blue: 0.27, alpha: 1)
    static let currentLine = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)
    static let selection = NSColor(srgbRed: 0.16, green: 0.27, blue: 0.45, alpha: 1)
    static let text = NSColor(srgbRed: 0.74, green: 0.75, blue: 0.77, alpha: 1)                 // #BCBEC4
    static let secondaryText = NSColor(srgbRed: 0.45, green: 0.47, blue: 0.50, alpha: 1)
    static let lineNumber = NSColor(srgbRed: 0.33, green: 0.35, blue: 0.38, alpha: 1)
    static let accent = NSColor(srgbRed: 0.21, green: 0.45, blue: 0.94, alpha: 1)

    // Syntax
    static let keyword = NSColor(srgbRed: 0.81, green: 0.56, blue: 0.43, alpha: 1)    // #CF8E6D
    static let string = NSColor(srgbRed: 0.42, green: 0.67, blue: 0.45, alpha: 1)     // #6AAB73
    static let number = NSColor(srgbRed: 0.16, green: 0.67, blue: 0.72, alpha: 1)     // #2AACB8
    static let comment = NSColor(srgbRed: 0.48, green: 0.50, blue: 0.52, alpha: 1)    // #7A7E85
    static let function = NSColor(srgbRed: 0.34, green: 0.66, blue: 0.96, alpha: 1)   // #56A8F5
    static let type = NSColor(srgbRed: 0.90, green: 0.72, blue: 0.47, alpha: 1)
    static let builtin = NSColor(srgbRed: 0.70, green: 0.55, blue: 0.85, alpha: 1)

    // Status
    static let error = NSColor(srgbRed: 0.97, green: 0.33, blue: 0.33, alpha: 1)
    static let warning = NSColor(srgbRed: 0.90, green: 0.70, blue: 0.25, alpha: 1)
    static let info = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.85, alpha: 1)
    static let gitAdded = NSColor(srgbRed: 0.38, green: 0.62, blue: 0.40, alpha: 1)
    static let gitModified = NSColor(srgbRed: 0.33, green: 0.55, blue: 0.85, alpha: 1)
    static let gitDeleted = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.58, alpha: 1)
    static let gitUntracked = NSColor(srgbRed: 0.80, green: 0.45, blue: 0.40, alpha: 1)
    static let breakpoint = NSColor(srgbRed: 0.85, green: 0.25, blue: 0.25, alpha: 1)
    static let debugLine = NSColor(srgbRed: 0.18, green: 0.28, blue: 0.48, alpha: 1)
}
