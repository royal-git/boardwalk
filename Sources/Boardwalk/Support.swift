import AppKit
import BoardwalkCore
import SwiftUI

extension Color {
    /// `#RRGGBB`; anything unparsable falls back to gray.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x5B6472
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Space {
    var color: Color { Color(hex: colorHex) }
}

/// File icons are slow-ish to fetch and the dock redraws often, so keep them.
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for item: DockItem) -> NSImage? {
        guard item.kind != .url else { return nil }
        let path = (item.location as NSString).expandingTildeInPath
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

/// The rounded colored square with the space's symbol, used everywhere a space appears.
struct SpaceBadge: View {
    let space: Space
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(space.color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: space.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// One tile's icon: the app/folder/file icon from Finder, or a link glyph.
struct ItemIcon: View {
    let item: DockItem
    var size: CGFloat

    var body: some View {
        if let image = IconCache.icon(for: item) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color(white: 0.28))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "link")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                )
        }
    }
}
