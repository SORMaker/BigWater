import AppKit
import BigWaterCore

/// The colours behind each `Ink`. Clay and cream stay the same; the accent
/// follows the theme.
public enum Palette {
    public static let cream = NSColor(srgbRed: 0.98, green: 0.96, blue: 0.92, alpha: 1)
    public static let ink = NSColor(srgbRed: 0.24, green: 0.19, blue: 0.16, alpha: 1)
    public static let clay = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    public static let clayLight = NSColor(srgbRed: 0.94, green: 0.61, blue: 0.45, alpha: 1)
    public static let clayShadow = NSColor(srgbRed: 0.68, green: 0.33, blue: 0.24, alpha: 1)
    public static let glint = NSColor(srgbRed: 0.86, green: 0.97, blue: 1, alpha: 1)
    public static let rope = NSColor(srgbRed: 0.48, green: 0.37, blue: 0.27, alpha: 1)
    public static let ropeLight = NSColor(srgbRed: 0.79, green: 0.65, blue: 0.46, alpha: 1)
    public static let labelShade = NSColor(srgbRed: 0.82, green: 0.87, blue: 0.86, alpha: 1)
    public static let leaf = NSColor(srgbRed: 0.36, green: 0.62, blue: 0.33, alpha: 1)
    public static let leafLight = NSColor(srgbRed: 0.56, green: 0.79, blue: 0.43, alpha: 1)
    public static let leafDark = NSColor(srgbRed: 0.19, green: 0.40, blue: 0.22, alpha: 1)
    public static let gold = NSColor(srgbRed: 0.98, green: 0.79, blue: 0.29, alpha: 1)

    public struct Accent {
        public let base: NSColor
        public let light: NSColor
        public let dark: NSColor
    }

    public static func accent(_ theme: Theme) -> Accent {
        switch theme {
        case .blue:
            return Accent(base: NSColor(srgbRed: 0.26, green: 0.59, blue: 0.86, alpha: 1),
                          light: NSColor(srgbRed: 0.58, green: 0.85, blue: 0.97, alpha: 1),
                          dark: NSColor(srgbRed: 0.13, green: 0.35, blue: 0.55, alpha: 1))
        case .mint:
            return Accent(base: NSColor(srgbRed: 0.25, green: 0.67, blue: 0.57, alpha: 1),
                          light: NSColor(srgbRed: 0.62, green: 0.91, blue: 0.77, alpha: 1),
                          dark: NSColor(srgbRed: 0.12, green: 0.43, blue: 0.37, alpha: 1))
        case .peach:
            return Accent(base: NSColor(srgbRed: 0.94, green: 0.55, blue: 0.39, alpha: 1),
                          light: NSColor(srgbRed: 1.0, green: 0.77, blue: 0.59, alpha: 1),
                          dark: NSColor(srgbRed: 0.66, green: 0.30, blue: 0.23, alpha: 1))
        }
    }

    public static func color(_ ink: Ink, theme: Theme) -> NSColor {
        switch ink {
        case .cream: return cream
        case .ink: return self.ink
        case .clay: return clay
        case .clayLight: return clayLight
        case .clayShadow: return clayShadow
        case .accent: return accent(theme).base
        case .accentLight: return accent(theme).light
        case .accentDark: return accent(theme).dark
        case .glint: return glint
        case .rope: return rope
        case .ropeLight: return ropeLight
        case .labelShade: return labelShade
        case .leaf: return leaf
        case .leafLight: return leafLight
        case .leafDark: return leafDark
        case .gold: return gold
        }
    }
}
