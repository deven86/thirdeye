import PhotosUI
import SwiftUI
import UIKit

/// Skins, Winamp-style: a wallpaper behind every screen, everything on it Liquid Glass.
/// A skin forces the dark appearance (white text reads on any wallpaper); the dim slider keeps busy photos legible.
enum Skin: String, CaseIterable, Identifiable {
    case none, aurora, ocean, sunset, nebula, forest, graphite, classic, photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Off"
        case .aurora: "Aurora"
        case .ocean: "Ocean"
        case .sunset: "Sunset"
        case .nebula: "Nebula"
        case .forest: "Forest"
        case .graphite: "Graphite"
        case .classic: "Classic Amp"
        case .photo: "My photo"
        }
    }

    /// 3 × 3 mesh colours, top-left to bottom-right.
    var mesh: [UInt32] {
        switch self {
        case .aurora: [0x06142E, 0x0B3B5C, 0x0E2A47, 0x0E7C86, 0x1F9E78, 0x3B2C7A, 0x071A33, 0x2A5C8F, 0x5B2E8C]
        case .ocean: [0x021428, 0x053A66, 0x0A2647, 0x0B5C8F, 0x1D7FB8, 0x0E4F7A, 0x031B33, 0x0A3D66, 0x02223F]
        case .sunset: [0x2B0F3A, 0x7A1F4F, 0x3D1250, 0xC2410C, 0xE0626A, 0x8C2B6B, 0x3A0D2E, 0xB4541E, 0x4A1240]
        case .nebula: [0x0D0726, 0x3A0F6B, 0x150A3D, 0x6B21A8, 0xC2378C, 0x2E1A7A, 0x0A0520, 0x4C1D95, 0x1E0B45]
        case .forest: [0x05170F, 0x0F3D2A, 0x0A2419, 0x1F6B45, 0x3E8E5A, 0x174D33, 0x041209, 0x245C3C, 0x0B2A1C]
        case .graphite: [0x101114, 0x2A2D33, 0x16181C, 0x3A3F47, 0x555B66, 0x2B2F36, 0x0C0D10, 0x23262B, 0x15171A]
        case .classic: [0x0B0C10, 0x1D2128, 0x101216, 0x22303A, 0x2F7D32, 0x1F2A30, 0x08090C, 0x3A4049, 0x111316]
        case .none, .photo: [0x101114, 0x101114, 0x101114, 0x101114, 0x101114, 0x101114, 0x101114, 0x101114, 0x101114]
        }
    }

    static let builtIn: [Skin] = [.aurora, .ocean, .sunset, .nebula, .forest, .graphite, .classic]
}

extension EnvironmentValues {
    @Entry var skinActive: Bool = false
}

/// The user's own wallpaper, saved once (downscaled) in Application Support.
enum SkinPhoto {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("skin-wallpaper.jpg")
    }

    private static var cache: (version: Int, image: UIImage?)?

    static func image(version: Int) -> UIImage? {
        if let cache, cache.version == version { return cache.image }
        let img = UIImage(contentsOfFile: url.path)
        cache = (version, img)
        return img
    }

    /// Downscales to at most 2400 pt on the long side and saves as JPEG.
    static func save(_ data: Data) -> Bool {
        guard let src = UIImage(data: data) else { return false }
        let maxSide: CGFloat = 2400
        let scale = min(1, maxSide / max(src.size.width, src.size.height))
        let size = CGSize(width: src.size.width * scale, height: src.size.height * scale)
        let img = UIGraphicsImageRenderer(size: size).image { _ in src.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpg = img.jpegData(compressionQuality: 0.85) else { return false }
        do { try jpg.write(to: url, options: .atomic) } catch { return false }
        cache = nil
        return true
    }
}

/// The wallpaper itself (no dimming).
struct SkinArt: View {
    let skin: Skin
    var photoVersion = 0

    var body: some View {
        if skin == .photo, let img = SkinPhoto.image(version: photoVersion) {
            GeometryReader { geo in
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
            }
        } else {
            MeshGradient(width: 3, height: 3,
                         points: [[0, 0], [0.5, 0], [1, 0], [0, 0.45], [0.55, 0.5], [1, 0.4], [0, 1], [0.5, 1], [1, 1]],
                         colors: skin.mesh.map { Color(hex: $0) })
        }
    }
}

/// Behind a screen: the wallpaper, dimmed — or the theme's background when no skin is on.
struct SkinBackdrop: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    var body: some View {
        if settings.skin != .none {
            SkinArt(skin: settings.skin, photoVersion: settings.skinPhotoVersion)
                .overlay(Color.black.opacity(settings.skinDim))
                .ignoresSafeArea()
        } else {
            palette.background.ignoresSafeArea()
        }
    }
}

extension View {
    /// A screen: list/scroll backgrounds hidden and the wallpaper behind, when a skin is on.
    func skinScreen() -> some View { modifier(SkinScreenModifier()) }

    /// List/Form rows: frosted glass instead of solid cells, when a skin is on.
    func skinRows() -> some View { modifier(SkinRowsModifier()) }
}

private struct SkinScreenModifier: ViewModifier {
    @Environment(\.skinActive) private var skinActive

    func body(content: Content) -> some View {
        if skinActive {
            content
                .scrollContentBackground(.hidden)
                .background { SkinBackdrop() }
        } else {
            content
        }
    }
}

private struct SkinRowsModifier: ViewModifier {
    @Environment(\.skinActive) private var skinActive

    func body(content: Content) -> some View {
        if skinActive {
            content.listRowBackground(SkinRowGlass())
        } else {
            content
        }
    }
}

/// One row of glass. Rows are separate cells, so they use the same frosted material Apple's glass is made of
/// (one continuous pane per row, no seams); cards and buttons use Liquid Glass itself.
struct SkinRowGlass: View {
    @Environment(\.glassAllowed) private var glassAllowed

    var body: some View {
        if glassAllowed {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.white.opacity(0.06))
        } else {
            Rectangle().fill(Color(UIColor.secondarySystemBackground))
        }
    }
}

// MARK: - Picker

struct SkinPickerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @State private var pick: PhotosPickerItem?
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 12) {
                    tile(.none)
                    ForEach(Skin.builtIn) { tile($0) }
                    if SkinPhoto.image(version: settings.skinPhotoVersion) != nil { tile(.photo) }
                }
                .padding(.vertical, 6)
                PhotosPicker(selection: $pick, matching: .images) {
                    Label("Use a photo from my library", systemImage: "photo.on.rectangle")
                }
                if let error { Text(error).font(.caption).foregroundStyle(palette.warning) }
            } footer: {
                Text("Like Winamp skins: the wallpaper sits behind every screen and everything on top is glass. A skin switches Third Eye to the dark look so text stays readable.")
            }

            if settings.skin != .none {
                Section {
                    HStack {
                        Image(systemName: "sun.max")
                        Slider(value: $settings.skinDim, in: 0...0.7)
                        Image(systemName: "moon.fill")
                    }
                } header: {
                    Text("Dim the wallpaper")
                } footer: {
                    Text("Darker makes numbers easier to read on bright or busy wallpapers.")
                }
            }
        }
        .navigationTitle("Skin")
        .skinScreen()
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), SkinPhoto.save(data) {
                    settings.skinPhotoVersion += 1
                    settings.skin = .photo
                    error = nil
                } else {
                    error = "Couldn't use that photo — try another."
                }
                pick = nil
            }
        }
    }

    private func tile(_ s: Skin) -> some View {
        let selected = settings.skin == s
        return Button { settings.skin = s } label: {
            VStack(spacing: 6) {
                ZStack {
                    if s == .none {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(UIColor.secondarySystemBackground))
                        Image(systemName: "nosign").foregroundStyle(palette.textSecondary)
                    } else {
                        SkinArt(skin: s, photoVersion: settings.skinPhotoVersion)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        // A glass chip on the preview, as it will look.
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.ultraThinMaterial)
                            .frame(width: 56, height: 18)
                    }
                }
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? palette.accent : Color.white.opacity(0.15), lineWidth: selected ? 3 : 1))
                Text(s.title).font(.caption.weight(selected ? .semibold : .regular)).foregroundStyle(palette.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
