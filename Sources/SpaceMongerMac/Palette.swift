import AppKit

/// The original's color schemes, taken verbatim from `FolderView.cpp`.
///
/// `BoxColors[]` holds 27 colors:
///   - 0…7    normal fill for depth 0…7 (cycled via `depth & 7`)
///   - 8…15   the "bright" bevel variant of each
///   - 16…23  the "dark" bevel variant of each
///   - 24,25  black / white
///
/// `FixedColors[]` holds the single-color schemes chosen in Settings:
/// fill at `i`, bright at `i + 10`, dark at `i + 20`.
enum Palette {
    static let box: [NSColor] = [
        // normal (depth 0-7)
        ns(0xFF, 0x7F, 0x7F), ns(0xFF, 0xBF, 0x7F), ns(0xFF, 0xFF, 0x00),
        ns(0x7F, 0xFF, 0x7F), ns(0x7F, 0xFF, 0xFF), ns(0xBF, 0xBF, 0xFF),
        ns(0xBF, 0xBF, 0xBF), ns(0xFF, 0x7F, 0xFF),
        // bright (depth 0-7)
        ns(0xFF, 0xBF, 0xBF), ns(0xFF, 0xDF, 0xBF), ns(0xFF, 0xFF, 0xBF),
        ns(0xBF, 0xFF, 0xBF), ns(0xDF, 0xFF, 0xFF), ns(0xDF, 0xDF, 0xFF),
        ns(0xDF, 0xDF, 0xDF), ns(0xFF, 0xBF, 0xFF),
        // dark (depth 0-7)
        ns(0xBF, 0x7F, 0x7F), ns(0xBF, 0x9F, 0x5F), ns(0xBF, 0xBF, 0x3F),
        ns(0x7F, 0xBF, 0x7F), ns(0x7F, 0xBF, 0xBF), ns(0x9F, 0x9F, 0xFF),
        ns(0x9F, 0x9F, 0x9F), ns(0xBF, 0x7F, 0xBF),
        // black, white
        ns(0x00, 0x00, 0x00), ns(0xFF, 0xFF, 0xFF),
    ]

    static let fixed: [NSColor] = [
        // fill: white, light gray, dark gray, red, orange, yellow, green, aqua, blue, violet
        ns(0xFF, 0xFF, 0xFF), ns(0xBF, 0xBF, 0xBF), ns(0x7F, 0x7F, 0x7F),
        ns(0xFF, 0x7F, 0x7F), ns(0xFF, 0xBF, 0x7F), ns(0xFF, 0xFF, 0x00),
        ns(0x7F, 0xFF, 0x7F), ns(0x7F, 0xFF, 0xFF), ns(0xBF, 0xBF, 0xFF),
        ns(0xFF, 0x7F, 0xFF),
        // bright
        ns(0xFF, 0xFF, 0xFF), ns(0xFF, 0xFF, 0xFF), ns(0xBF, 0xBF, 0xBF),
        ns(0xFF, 0x9F, 0x9F), ns(0xFF, 0xDF, 0xBF), ns(0xFF, 0xFF, 0xBF),
        ns(0xBF, 0xFF, 0xBF), ns(0xDF, 0xFF, 0xFF), ns(0xDF, 0xDF, 0xFF),
        ns(0xFF, 0xBF, 0xFF),
        // dark
        ns(0xBF, 0xBF, 0xBF), ns(0x7F, 0x7F, 0x7F), ns(0x3F, 0x3F, 0x3F),
        ns(0xBF, 0x7F, 0x7F), ns(0xBF, 0x9F, 0x9F), ns(0xBF, 0xBF, 0x3F),
        ns(0x7F, 0xBF, 0x7F), ns(0x7F, 0xBF, 0xBF), ns(0x9F, 0x9F, 0xFF),
        ns(0xBF, 0x7F, 0xBF),
    ]

    /// Scheme names for the Settings pop-ups (original `uscolornames`).
    static let schemeNames = [
        "Rainbow", "Windows Colors", "White", "Light Gray", "Dark Gray",
        "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Violet",
    ]

    /// The fill color for a given nesting depth (cycles every 8 levels).
    static func color(_ depth: Int) -> NSColor { box[depth & 7] }
    /// The bright bevel color for a depth.
    static func bright(_ depth: Int) -> NSColor { box[(depth & 7) + 8] }
    /// The dark bevel color for a depth.
    static func dark(_ depth: Int) -> NSColor { box[(depth & 7) + 16] }

    /// Fill / bright / dark for a tile, after `MinimalDrawDisplayFolder`:
    /// scheme 0 cycles by depth, 1 is the Windows 3D-face gray (fixed at its
    /// classic values — the macOS system grays go dark in Dark Mode, where
    /// the black tile text would vanish), 2… is one fixed color.
    static func colors(scheme: Int, depth: Int) -> (fill: NSColor, bright: NSColor, dark: NSColor) {
        switch scheme {
        case 0:
            return (color(depth), bright(depth), dark(depth))
        case 1:
            return (ns(0xC0, 0xC0, 0xC0), ns(0xFF, 0xFF, 0xFF), ns(0x80, 0x80, 0x80))
        default:
            let i = min(max(scheme - 2, 0), 9)
            return (fixed[i], fixed[i + 10], fixed[i + 20])
        }
    }

    private static func ns(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(calibratedRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0)
    }
}
