import SwiftUI

/// The six themes from the spec. All colours are calm (no pure black text on pure white,
/// softened green/red) to keep long reading sessions easy on the eyes.
enum AppTheme: String, CaseIterable, Identifiable {
    case liquidGlass
    case calmLight
    case calmDark
    case oledNight
    case paper
    case highContrast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .calmLight: "Calm Light"
        case .calmDark: "Calm Dark"
        case .oledNight: "OLED Night"
        case .paper: "Paper"
        case .highContrast: "High Contrast"
        }
    }

    var subtitle: String {
        switch self {
        case .liquidGlass: "System look with glass navigation · follows light/dark"
        case .calmLight: "Off-white, slate text, soft colours"
        case .calmDark: "Deep grey instead of black, low glare"
        case .oledNight: "True black for night use"
        case .paper: "Warm, low-blue tones for long reading"
        case .highContrast: "Maximum legibility"
        }
    }

    /// nil = follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .liquidGlass: nil
        case .calmLight, .paper, .highContrast: .light
        case .calmDark, .oledNight: .dark
        }
    }

    /// Whether floating controls may use Liquid Glass in this theme.
    var allowsGlass: Bool { self != .highContrast }

    func palette(colorBlindSafe: Bool, systemScheme: ColorScheme) -> Palette {
        var p: Palette
        switch self {
        case .liquidGlass:
            p = systemScheme == .dark ? .calmDarkBase : .calmLightBase
            p.background = Color(.systemGroupedBackground)
            p.surface = Color(.secondarySystemGroupedBackground)
            p.textPrimary = .primary
            p.textSecondary = .secondary
        case .calmLight: p = .calmLightBase
        case .calmDark: p = .calmDarkBase
        case .oledNight:
            p = .calmDarkBase
            p.background = .black
            p.surface = Color(hex: 0x111214)
            p.textPrimary = Color(hex: 0xD6D9DD)
            p.up = Color(hex: 0x3E9E6E)
            p.down = Color(hex: 0xC4554F)
        case .paper:
            p = .calmLightBase
            p.background = Color(hex: 0xF4EEE3)
            p.surface = Color(hex: 0xFBF7F0)
            p.textPrimary = Color(hex: 0x3B3226)
            p.textSecondary = Color(hex: 0x7A6E5E)
            p.accent = Color(hex: 0x8A5A2B)
            p.separator = Color(hex: 0xE2D8C6)
        case .highContrast:
            p = .calmLightBase
            p.background = .white
            p.surface = .white
            p.textPrimary = .black
            p.textSecondary = Color(hex: 0x333333)
            p.accent = Color(hex: 0x00515A)
            p.up = Color(hex: 0x006B2E)
            p.down = Color(hex: 0xB00020)
            p.separator = .black
        }
        if colorBlindSafe {
            p.up = Color(hex: 0x2F6FDB)
            p.down = Color(hex: 0xE07B00)
        }
        return p
    }
}

nonisolated struct Palette: Sendable {
    var background: Color
    var surface: Color
    var textPrimary: Color
    var textSecondary: Color
    var accent: Color
    var up: Color
    var down: Color
    var neutral: Color
    var warning: Color
    var separator: Color

    static let calmLightBase = Palette(
        background: Color(hex: 0xF7F7F5),
        surface: .white,
        textPrimary: Color(hex: 0x1B2430),
        textSecondary: Color(hex: 0x5B6573),
        accent: Color(hex: 0x0E7C86),
        up: Color(hex: 0x2E9E6B),
        down: Color(hex: 0xD9534F),
        neutral: Color(hex: 0x8A94A3),
        warning: Color(hex: 0xB4541E),
        separator: Color(hex: 0xE3E6EA)
    )

    static let calmDarkBase = Palette(
        background: Color(hex: 0x121417),
        surface: Color(hex: 0x1B1E23),
        textPrimary: Color(hex: 0xE4E7EB),
        textSecondary: Color(hex: 0x9AA3AE),
        accent: Color(hex: 0x3FB4BE),
        up: Color(hex: 0x4CB782),
        down: Color(hex: 0xE06C66),
        neutral: Color(hex: 0x7D8794),
        warning: Color(hex: 0xE09A5B),
        separator: Color(hex: 0x2A2E35)
    )

    /// Colour for a 10–1000 composite score using the spec's verdict bands.
    func color(forComposite score: Int) -> Color {
        switch score {
        case 620...: up
        case ...380: down
        default: neutral
        }
    }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Environment

extension EnvironmentValues {
    @Entry var palette: Palette = .calmLightBase
    @Entry var glassAllowed: Bool = true
}

/// Applies the selected theme to a view tree.
struct ThemeHost<Content: View>: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: Content

    var body: some View {
        let skin = settings.skin != .none
        var palette = skin
            // A skin is always dark glass: white text over a dimmed wallpaper, whatever the theme.
            ? (settings.theme == .highContrast ? AppTheme.highContrast : AppTheme.liquidGlass)
                .palette(colorBlindSafe: settings.colorBlindSafe, systemScheme: .dark)
            : settings.theme.palette(colorBlindSafe: settings.colorBlindSafe, systemScheme: systemScheme)
        if skin { palette.background = .clear }
        return content
            .environment(\.palette, palette)
            .environment(\.skinActive, skin)
            .environment(\.glassAllowed, settings.theme.allowsGlass && !reduceTransparency)
            .tint(palette.accent)
            .preferredColorScheme(skin ? .dark : settings.theme.colorScheme)
    }
}
