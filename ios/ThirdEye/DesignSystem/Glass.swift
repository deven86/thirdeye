import SwiftUI

// Liquid Glass rules for Third Eye:
//  • System bars, tab bars, toolbars and sheets get glass automatically (Xcode 26 / iOS 26).
//  • Custom glass only on floating controls — never behind numbers, tables or candles.
//  • When Reduce Transparency is on, or the High Contrast theme is selected, fall back to solid surfaces.

extension View {
    /// Glass for a floating control, with a solid fallback.
    func floatingGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(FloatingGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    /// Solid card for data. Data never sits on glass.
    func dataCard(padding: CGFloat = 16) -> some View {
        modifier(DataCardModifier(padding: padding))
    }
}

private struct FloatingGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.glassAllowed) private var glassAllowed
    @Environment(\.palette) private var palette
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if glassAllowed {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(palette.surface, in: shape)
                .overlay(shape.stroke(palette.separator, lineWidth: 1))
        }
    }

    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.35)) }
        if interactive { g = g.interactive() }
        return g
    }
}

private struct DataCardModifier: ViewModifier {
    @Environment(\.palette) private var palette
    @Environment(\.skinActive) private var skinActive
    @Environment(\.glassAllowed) private var glassAllowed
    let padding: CGFloat

    func body(content: Content) -> some View {
        if skinActive && glassAllowed {
            // Skin on: the card is Liquid Glass over the wallpaper.
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            solid(content)
        }
    }

    private func solid(_ content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(palette.separator, lineWidth: 0.5)
            )
    }
}

/// Primary and secondary button styles that respect the glass rules.
struct AdaptiveButton: View {
    enum Kind { case primary, secondary }
    @Environment(\.glassAllowed) private var glassAllowed
    let title: String
    var systemImage: String?
    var kind: Kind = .primary
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .controlSize(.large)

        if glassAllowed {
            if kind == .primary {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.glass)
            }
        } else {
            if kind == .primary {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }
}
