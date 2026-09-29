//
//  StyleSettings.swift
//  paster
//

import SwiftUI

/// The Style pane: every panel style as a card with a drawing of the screen
/// it opens on, so the choice is made by looking rather than by reading.
struct StyleSettings: View {
    var settings: AppSettings
    /// Opens the panel at once, in the style just chosen.
    var onTry: () -> Void = {}

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(PanelStyle.allCases) { style in
                        StyleCard(style: style, isSelected: settings.panelStyle == style) {
                            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                                settings.panelStyle = style
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.never)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Panel style")
                    .font(.system(size: 15, weight: .semibold))
                Text("Takes effect the next time the panel opens.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(action: onTry) {
                Label("Try \(settings.panelStyle.title)", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(PanelPalette.accent)
            .help("Open the panel now, in this style")
        }
    }
}

/// One style: its miniature, its name and what it is for.
private struct StyleCard: View {
    let style: PanelStyle
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                StyleMiniature(style: style, isSelected: isSelected)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
                    }
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(style.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(style.summary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3, reservesSpace: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? AnyShapeStyle(PanelPalette.accent) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(7)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected
                     ? Glass.regular.tint(PanelPalette.accent.opacity(0.18)).interactive()
                     : Glass.regular.interactive(),
                     in: shape)
        .overlay {
            if isSelected {
                shape.strokeBorder(PanelPalette.accent, lineWidth: 1.5)
            }
        }
        .scaleEffect(isHovered && !isSelected ? 1.015 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
        // On the button itself: wrapping it in a new accessibility element
        // swallowed its press action, so VoiceOver could not choose a style.
        .accessibilityLabel(style.title)
        .accessibilityHint(style.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A screen, drawn small, with the panel where the style puts it.
private struct StyleMiniature: View {
    let style: PanelStyle
    let isSelected: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                wallpaper
                // The menu bar.
                Rectangle()
                    .fill(.white.opacity(scheme == .dark ? 0.12 : 0.55))
                    .frame(width: size.width, height: size.height * 0.055)
                // A document window behind, so the panel reads as floating
                // over work.
                window(in: size)
                panel(in: size)
            }
        }
    }

    private var wallpaper: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.14, green: 0.16, blue: 0.3), Color(red: 0.25, green: 0.14, blue: 0.3)]
                : [Color(red: 0.76, green: 0.83, blue: 1.0), Color(red: 0.95, green: 0.82, blue: 0.9),
                   Color(red: 1.0, green: 0.9, blue: 0.8)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private var panelFill: Color { scheme == .dark ? Color(white: 0.2).opacity(0.92) : .white.opacity(0.9) }
    private var ink: Color { scheme == .dark ? .white.opacity(0.35) : .black.opacity(0.18) }
    private var accent: Color { PanelPalette.accent }

    private func window(in size: CGSize) -> some View {
        box(CGRect(x: 0.14, y: 0.13, width: 0.6, height: 0.62), in: size, radius: 4,
            fill: scheme == .dark ? Color(white: 0.16) : .white.opacity(0.75))
    }

    // MARK: Panels

    @ViewBuilder
    private func panel(in size: CGSize) -> some View {
        switch style {
        case .basic:
            let frame = CGRect(x: 0.015, y: 0.6, width: 0.97, height: 0.385)
            floating(frame, in: size, radius: 6)
            ForEach(0 ..< 5, id: \.self) { index in
                let card = CGRect(x: 0.04 + Double(index) * 0.19, y: 0.7, width: 0.165, height: 0.26)
                box(card, in: size, radius: 3, fill: .white)
                box(CGRect(x: card.minX, y: card.minY, width: card.width, height: card.height * 0.26),
                    in: size, radius: 3, fill: Self.bands[index])
                if index == 0 { ring(card, in: size, radius: 3) }
            }
        case .lightStrip:
            let frame = CGRect(x: 0.015, y: 0.8, width: 0.97, height: 0.185)
            floating(frame, in: size, radius: 6)
            ForEach(0 ..< 8, id: \.self) { index in
                let tile = CGRect(x: 0.035 + Double(index) * 0.118, y: 0.835, width: 0.105, height: 0.12)
                box(tile, in: size, radius: 2.5, fill: index == 3 ? Self.bands[1] : index == 1 ? Color(white: 0.2) : .white)
                if index == 0 { ring(tile, in: size, radius: 2.5) }
            }
        case .topDrop:
            let frame = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.52)
            floating(frame, in: size, radius: 6)
            rows(in: frame, count: 8, size: size, twoLine: true)
        case .minimal:
            let frame = CGRect(x: 0.35, y: 0.18, width: 0.3, height: 0.62)
            floating(frame, in: size, radius: 6)
            rows(in: frame, count: 9, size: size, twoLine: true)
        case .sidebar:
            let frame = CGRect(x: 0.73, y: 0.075, width: 0.255, height: 0.905)
            floating(frame, in: size, radius: 6)
            rows(in: frame, count: 15, size: size, twoLine: false)
        case .grid:
            let frame = CGRect(x: 0.3, y: 0.17, width: 0.4, height: 0.66)
            floating(frame, in: size, radius: 6)
            ForEach(0 ..< 20, id: \.self) { index in
                let column = Double(index % 5), row = Double(index / 5)
                let tile = CGRect(x: frame.minX + 0.015 + column * 0.075, y: frame.minY + 0.11 + row * 0.13,
                                  width: 0.066, height: 0.11)
                box(tile, in: size, radius: 2,
                    fill: [2, 8, 13].contains(index) ? Color(white: 0.2)
                        : [3, 11, 17].contains(index) ? Self.bands[index % 5] : .white)
                if index == 0 { ring(tile, in: size, radius: 2) }
            }
            searchBar(in: frame, size: size)
        case .palette:
            let frame = CGRect(x: 0.14, y: 0.14, width: 0.72, height: 0.72)
            floating(frame, in: size, radius: 7)
            searchBar(in: frame, size: size)
            let list = CGRect(x: frame.minX, y: frame.minY + 0.08, width: frame.width * 0.38, height: frame.height - 0.08)
            rows(in: list, count: 8, size: size, twoLine: true, top: 0.015)
            // The preview.
            box(CGRect(x: list.maxX + 0.02, y: list.minY + 0.03, width: frame.maxX - list.maxX - 0.04,
                       height: list.height * 0.62),
                in: size, radius: 3, fill: scheme == .dark ? Color(white: 0.26) : Color(white: 0.97))
            box(CGRect(x: list.maxX + 0.02, y: frame.maxY - 0.09, width: 0.1, height: 0.045),
                in: size, radius: 20, fill: accent)
            box(CGRect(x: list.maxX + 0.13, y: frame.maxY - 0.09, width: 0.07, height: 0.045),
                in: size, radius: 20, fill: ink)
        }
    }

    private static let bands: [Color] = [
        Color(red: 0.2, green: 0.52, blue: 0.97), Color(red: 0.97, green: 0.53, blue: 0.16),
        Color(red: 0.1, green: 0.68, blue: 0.66), Color(red: 0.63, green: 0.38, blue: 0.93),
        Color(red: 0.94, green: 0.33, blue: 0.56),
    ]

    /// Rows of a list: a coloured square and a line or two of "text", the
    /// first row selected.
    @ViewBuilder
    private func rows(in frame: CGRect, count: Int, size: CGSize, twoLine: Bool, top: Double = 0.03) -> some View {
        let pitch = (frame.height - top * 2) / Double(count)
        ForEach(0 ..< count, id: \.self) { index in
            let y = frame.minY + top + Double(index) * pitch
            let row = CGRect(x: frame.minX + 0.01, y: y + pitch * 0.08, width: frame.width - 0.02, height: pitch * 0.84)
            if index == 0 {
                box(row, in: size, radius: 3, fill: accent.opacity(isSelected ? 0.3 : 0.18))
            }
            let icon = min(row.height * 0.7 * size.height, frame.width * size.width * 0.14) / size.width
            let iconHeight = icon * size.width / size.height
            box(CGRect(x: row.minX + 0.008, y: row.midY - iconHeight / 2, width: icon, height: iconHeight),
                in: size, radius: 2, fill: Self.bands[index % 5].opacity(index % 3 == 1 ? 1 : 0.55))
            let textX = row.minX + 0.016 + icon
            let widths = [0.78, 0.62, 0.7, 0.5, 0.74, 0.58]
            let textWidth = (row.maxX - textX - 0.01) * widths[index % widths.count]
            if twoLine {
                box(CGRect(x: textX, y: row.midY - row.height * 0.22, width: textWidth, height: row.height * 0.16),
                    in: size, radius: 1, fill: ink.opacity(1.6))
                box(CGRect(x: textX, y: row.midY + row.height * 0.08, width: textWidth * 0.55, height: row.height * 0.12),
                    in: size, radius: 1, fill: ink)
            } else {
                box(CGRect(x: textX, y: row.midY - row.height * 0.1, width: textWidth, height: row.height * 0.2),
                    in: size, radius: 1, fill: ink.opacity(1.6))
            }
        }
    }

    private func searchBar(in frame: CGRect, size: CGSize) -> some View {
        box(CGRect(x: frame.minX + 0.015, y: frame.minY + 0.02, width: frame.width * 0.45, height: 0.035),
            in: size, radius: 20, fill: ink)
    }

    // MARK: Primitives, in fractions of the screen

    private func floating(_ frame: CGRect, in size: CGSize, radius: CGFloat) -> some View {
        box(frame, in: size, radius: radius, fill: panelFill)
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    private func ring(_ frame: CGRect, in size: CGSize, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(accent, lineWidth: 1.5)
            .frame(width: frame.width * size.width + 3, height: frame.height * size.height + 3)
            .position(x: frame.midX * size.width, y: frame.midY * size.height)
    }

    private func box(_ frame: CGRect, in size: CGSize, radius: CGFloat, fill: Color) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .frame(width: max(0, frame.width * size.width), height: max(0, frame.height * size.height))
            .position(x: frame.midX * size.width, y: frame.midY * size.height)
    }
}
