//
//  StyledCells.swift
//  paster
//
//  The items of the styles other than basic: list rows and small tiles, and
//  the one wrapper every one of them goes through.
//

import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What an item shows besides its clipping.
struct CellState: Equatable {
    var isSelected: Bool
    var isKey: Bool
    var isHovered: Bool
    var quickPasteDigit: Int?
    var search: ClipSearch?
    /// Carried here rather than read from the clipping by the face, whose
    /// equality check would otherwise hide a pin toggled from a menu.
    var isPinned: Bool = false

    /// Age and actions appear on the row being looked at.
    var isFocused: Bool { isSelected || isHovered }
}

/// The wrapper every item of every style goes through, so none can miss what
/// all of them need: the deleted-clipping guard, click to paste, dragging out,
/// the context menu, and a face compared by value so that moving the
/// selection rebuilds only the two items whose look changed.
///
/// A tap rather than an enclosing `Button`, so the pin button inside an item
/// takes its own clicks. The item is still announced as a button, with the
/// same action, for VoiceOver and Voice Control.
struct ClipCell<Face: View & Equatable>: View {
    let clip: ClipItem
    let model: RowModel
    let presentation: PanelPresentation
    let actions: RowActions
    /// The first click only selects, and a click on the selection pastes —
    /// for the palette, whose preview would otherwise never be seen.
    var selectsBeforePasting = false
    let face: (CellState, @escaping () -> Void) -> Face

    @State private var isHovered = false

    var body: some View {
        if clip.isGone {
            // Replaced as soon as the list catches up; see `ClipItem.isGone`.
            Color.clear
        } else {
            let isSelected = model.flags(for: clip).isSelected
            face(CellState(
                isSelected: isSelected,
                isKey: presentation.isKeyWindow,
                isHovered: isHovered,
                quickPasteDigit: presentation.isCommandHeld ? model.quickPasteDigit(for: clip) : nil,
                search: model.search,
                isPinned: clip.isPinned
            ), { actions.togglePin(clip) })
            .equatable()
            .contentShape(.rect)
            .onTapGesture { activate(isSelected: isSelected) }
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(selectsBeforePasting && !isSelected
                               ? String(localized: "Shows it beside the list") : String(localized: "Pastes into the previous app"))
            .accessibilityAction { activate(isSelected: isSelected) }
            .accessibilityAction(named: clip.isPinned ? String(localized: "Unpin") : String(localized: "Pin")) { actions.togglePin(clip) }
            .onDrag { ClipboardPanelView.itemProvider(for: clip) }
            .contextMenu {
                Button("Paste") { actions.paste(clip, false) }
                Button("Paste as Plain Text") { actions.paste(clip, true) }
                Divider()
                Button(clip.isPinned ? String(localized: "Unpin") : String(localized: "Pin")) { actions.togglePin(clip) }
                Divider()
                Button("Delete", role: .destructive) { actions.delete(clip) }
            }
        }
    }

    private func activate(isSelected: Bool) {
        if selectsBeforePasting && !isSelected {
            model.selected = clip
            return
        }
        model.selected = clip
        actions.paste(clip, false)
    }
}

/// Pins or unpins, drawn on the item being looked at and on every pinned one.
struct PinButton: View {
    let isPinned: Bool
    let size: CGFloat
    var onDark = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: size, weight: .medium))
                .rotationEffect(.degrees(isPinned ? 0 : 45))
                .foregroundStyle(isPinned
                                 ? AnyShapeStyle(PanelPalette.accent)
                                 : onDark ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .frame(width: size * 2, height: size * 2)
                // Glass under the pointer, bare otherwise: a row of glass
                // circles down a list would be noise.
                .glassEffect(isHovered ? .regular.interactive() : .identity, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isPinned ? String(localized: "Unpin (⌘P)") : String(localized: "Pin (⌘P) — kept regardless of the history limits"))
        .accessibilityHidden(true)
    }
}

// MARK: - What a clipping looks like

/// The one thing that makes a clipping recognisable at a glance.
enum ClipVisual {
    case picture(NSImage, name: String, size: CGSize?)
    case colour(Color, hex: String)
    case file(NSImage, name: String, size: String?)
    case link(host: String, path: String)
    case text(String, monospaced: Bool)

    @MainActor
    init(_ clip: ClipItem) {
        if clip.kind == .image || clip.isImageFile,
           let image = ThumbnailCache.image(fingerprint: clip.fingerprint, data: clip.thumbnailData) {
            self = .picture(image, name: clip.displayName ?? String(localized: "Image"), size: clip.cachedImageSize)
            return
        }
        if clip.kind == .fileURL, let url = clip.fileURL {
            self = .file(FileInfoCache.icon(for: url), name: url.lastPathComponent,
                         size: FileInfoCache.size(of: url))
            return
        }
        if let url = clip.linkURL, let host = url.host {
            let path = url.path.count > 1 ? url.path : ""
            self = .link(host: host, path: path)
            return
        }
        let text = clip.previewText ?? ""
        if let (colour, hex) = ClipVisual.colour(in: text) {
            self = .colour(colour, hex: hex)
            return
        }
        self = .text(text, monospaced: clip.prefersMonospacedPreview || ClipVisual.looksLikeCode(text))
    }

    /// A bare hex colour: `#F2552C`, `F2552C` or `#F52`.
    static func colour(in text: String) -> (Color, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 7 else { return nil }
        var hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6 || hex.count == 3, hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        // Three or six hex digits could be a word ("add", "bead"); require at
        // least one digit or a leading #.
        guard trimmed.hasPrefix("#") || hex.contains(where: \.isNumber) else { return nil }
        let colour = Color(red: Double((value >> 16) & 0xFF) / 255,
                           green: Double((value >> 8) & 0xFF) / 255,
                           blue: Double(value & 0xFF) / 255)
        return (colour, "#" + hex.uppercased())
    }

    /// One line that reads as a command or a statement rather than prose,
    /// so it is set in the monospaced face.
    static func looksLikeCode(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("\n") || line.count < 200 else { return false }
        let first = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let commands: Set<String> = [
            "git", "ssh", "cd", "ls", "npm", "npx", "pnpm", "yarn", "brew", "curl", "wget",
            "docker", "kubectl", "sudo", "python", "python3", "pip", "swift", "xcodebuild",
            "let", "var", "func", "const", "import", "return", "SELECT", "UPDATE", "INSERT",
            "DELETE", "export", "echo", "cat", "grep", "open", "defaults", "make", "go", "cargo",
        ]
        return commands.contains(first) || line.hasPrefix("$ ") || line.hasPrefix("./")
    }

    /// For sorting out the kind glyph and the palette's preview.
    var glyph: String {
        switch self {
        case .picture: "photo"
        case .colour: "paintpalette"
        case .file: "doc"
        case .link: "link"
        case .text(_, let monospaced): monospaced ? "chevron.left.forwardslash.chevron.right" : "text.quote"
        }
    }
}

extension ClipItem {
    /// A file's name, for pictures copied as files.
    var displayName: String? { fileURL?.lastPathComponent }

    /// The picture's size in points, if it has been read already or can be
    /// read from a file's header. Never faults the payload: in a list that
    /// scrolls, that would be a disk read per row.
    @MainActor
    var cachedImageSize: CGSize? {
        guard let url = fileURL else { return ThumbnailCache.cachedImageSize(fingerprint: fingerprint) }
        return ThumbnailCache.imageSize(fingerprint: fingerprint) {
            CGImageSourceCreateWithURL(url as CFURL, nil)
        }
    }

    /// "2m", "3h", "1d": short enough for the edge of a row.
    var shortAge: String {
        let seconds = max(0, Date().timeIntervalSince(copiedAt))
        switch seconds {
        case ..<60: return String(localized: "now")
        case ..<3600: return String(localized: "\(Int(seconds / 60))m", comment: "Minutes ago, as short as possible")
        case ..<86_400: return String(localized: "\(Int(seconds / 3600))h", comment: "Hours ago, as short as possible")
        case ..<604_800: return String(localized: "\(Int(seconds / 86_400))d", comment: "Days ago, as short as possible")
        default: return String(localized: "\(Int(seconds / 604_800))w", comment: "Weeks ago, as short as possible")
        }
    }
}

/// File icons and sizes, looked up once per file rather than per redraw.
@MainActor
enum FileInfoCache {
    private static var icons: [String: NSImage] = [:]
    private static var sizes: [String: String?] = [:]

    static func icon(for url: URL) -> NSImage {
        if let cached = icons[url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        if icons.count > 400 { icons.removeAll(keepingCapacity: true) }
        icons[url.path] = icon
        return icon
    }

    static func size(of url: URL) -> String? {
        if let cached = sizes[url.path] { return cached }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let size = bytes.map { Int64($0).formatted(.byteCount(style: .file)) }
        if sizes.count > 400 { sizes.removeAll(keepingCapacity: true) }
        sizes[url.path] = size
        return size
    }
}

/// Text with each search match marked.
func highlighted(_ text: String, search: ClipSearch?, scheme: ColorScheme) -> AttributedString {
    guard let search, !search.terms.isEmpty else { return AttributedString(text) }
    let shown = search.snippet(of: text)
    var result = AttributedString()
    var cursor = shown.startIndex
    for range in search.ranges(in: shown) {
        result += AttributedString(shown[cursor ..< range.lowerBound])
        var match = AttributedString(shown[range])
        match.backgroundColor = PanelPalette.highlight(scheme)
        result += match
        cursor = range.upperBound
    }
    result += AttributedString(shown[cursor...])
    return result
}

/// Whitespace, newlines included, collapsed to single spaces: a one-line row
/// of text that starts with a newline would otherwise show nothing.
func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

// MARK: - Source app

/// The source app's icon, small, or a device glyph for a clipping that came
/// from another device.
struct AppBadge: View {
    let clip: ClipItem
    let side: CGFloat

    var body: some View {
        if clip.isFromRemoteDevice {
            Image(systemName: "iphone.gen3")
                .font(.system(size: side * 0.75))
                .foregroundStyle(.secondary)
                .frame(width: side, height: side)
        } else if let icon = AppAccent.icon(for: clip.sourceBundleID) {
            // An app icon's canvas has a margin around its tile; drawn a
            // little larger so the tile itself is `side` across.
            Image(nsImage: icon)
                .resizable()
                .frame(width: side / PanelMetrics.appIconTileRatio,
                       height: side / PanelMetrics.appIconTileRatio)
                .frame(width: side, height: side)
        } else {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: side * 0.7))
                .foregroundStyle(.secondary)
                .frame(width: side, height: side)
        }
    }
}

// MARK: - Recognisable at a glance

/// The one-glance summary of a clipping: what kind of thing it is, drawn as
/// a small tile — a picture's thumbnail, a colour's swatch, a file's icon, a
/// link's globe, code on a dark ground, or prose's first character on the
/// source app's colour. Rows in a list mostly differ here, not in their text.
struct KindTile: View {
    let clip: ClipItem
    let visual: ClipVisual
    let side: CGFloat
    /// The source app's icon, small, on the tile's corner.
    var showsAppBadge = true

    @Environment(\.colorScheme) private var scheme

    private var radius: CGFloat { side * 0.24 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        face
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay { shape.strokeBorder(PanelPalette.hairline(scheme), lineWidth: 0.5) }
            .overlay(alignment: .bottomTrailing) {
                if showsAppBadge, side >= 26 {
                    AppBadge(clip: clip, side: side * 0.42)
                        .background(Circle().fill(.background).padding(-1))
                        .offset(x: side * 0.14, y: side * 0.14)
                }
            }
    }

    @ViewBuilder
    private var face: some View {
        switch visual {
        case .picture(let image, _, _):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        case .colour(let colour, _):
            colour
        case .file(let icon, _, _):
            ZStack {
                accent.opacity(0.12)
                Image(nsImage: icon).resizable().frame(width: side * 0.78, height: side * 0.78)
            }
        case .link:
            ZStack {
                accent.opacity(scheme == .dark ? 0.28 : 0.16)
                Image(systemName: "link")
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(accent)
            }
        case .text(let text, let monospaced):
            if monospaced {
                ZStack {
                    Color(white: 0.13)
                    Text(ClipVisual.codeGlyph(text))
                        .font(.system(size: side * 0.34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.55, green: 0.9, blue: 0.6))
                }
            } else {
                ZStack {
                    accent.opacity(scheme == .dark ? 0.3 : 0.16)
                    Text(ClipVisual.initial(of: text))
                        .font(.system(size: side * 0.46, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
        }
    }

    /// The source app's colour, so a column of tiles also sorts by app.
    private var accent: Color {
        AppAccent.color(forBundleID: clip.isFromRemoteDevice ? nil : clip.sourceBundleID) ?? .gray
    }
}

extension ClipVisual {
    /// Prose's first character, capitalised: "明", "C".
    static func initial(of text: String) -> String {
        guard let first = text.first(where: { !$0.isWhitespace && !$0.isPunctuation }) else { return "¶" }
        return String(first).uppercased()
    }

    /// What a code tile shows: a prompt for a command, braces for the rest.
    static func codeGlyph(_ text: String) -> String {
        let first = text.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let shell: Set<String> = ["git", "ssh", "cd", "ls", "npm", "brew", "curl", "docker", "kubectl",
                                  "sudo", "open", "defaults", "make", "echo", "cat", "grep", "python3"]
        if shell.contains(first) || text.hasPrefix("$") { return "$_" }
        if first.uppercased() == first, first.count > 2 { return "SQL" }
        return "{ }"
    }

    /// The detail a row's second line ends with.
    func detail(for clip: ClipItem) -> String? {
        switch self {
        case .picture(_, _, let size):
            if let size { return "\(Int(size.width)) × \(Int(size.height))" }
            return clip.lengthSummary
        case .colour(_, let hex): return hex
        case .file(_, _, let size): return size
        case .link(let host, _): return host
        case .text: return clip.lengthSummary
        }
    }

    /// What the row's first line reads.
    func title(for clip: ClipItem) -> String {
        switch self {
        case .picture(_, let name, _): return name
        case .colour(_, let hex): return hex
        case .file(_, let name, _): return name
        case .link(let host, let path): return host + path
        case .text(let text, _): return text
        }
    }
}

extension ClipItem {
    /// The source, as a row's second line names it.
    @MainActor
    var sourceName: String {
        if isFromRemoteDevice { return String(localized: "Another device") }
        return AppAccent.displayName(forBundleID: sourceBundleID) ?? kindLabel
    }
}

// MARK: - List row

/// A row of the minimal, top-drop, sidebar and palette lists.
struct ListRowFace: View, Equatable {
    let clip: ClipItem
    let state: CellState
    let metrics: ListMetrics
    var onPin: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    static func == (lhs: ListRowFace, rhs: ListRowFace) -> Bool {
        lhs.clip === rhs.clip && lhs.state == rhs.state
            && lhs.metrics.rowHeight == rhs.metrics.rowHeight
    }

    var body: some View {
        let visual = ClipVisual(clip)
        HStack(spacing: metrics.iconGap) {
            KindTile(clip: clip, visual: visual, side: metrics.iconSide,
                     showsAppBadge: metrics.twoLine)
            VStack(alignment: .leading, spacing: 3) {
                title(visual)
                if metrics.twoLine {
                    meta(visual)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, metrics.rowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background, in: .rect(cornerRadius: metrics.rowRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClipboardPanelView.spokenDescription(of: clip))
    }

    private var background: Color {
        if state.isSelected {
            return state.isKey ? PanelPalette.selection(scheme) : PanelPalette.hover(scheme).opacity(2)
        }
        return state.isHovered ? PanelPalette.hover(scheme) : .clear
    }

    @ViewBuilder
    private func title(_ visual: ClipVisual) -> some View {
        Group {
            switch visual {
            case .link(let host, let path):
                (Text(host).fontWeight(.medium) + Text(path).foregroundStyle(.secondary))
                    .font(.system(size: PanelType.body))
            case .text(let text, let monospaced):
                Text(highlighted(oneLine(text), search: state.search, scheme: scheme))
                    .font(monospaced
                          ? .system(size: PanelType.mono, design: .monospaced)
                          : .system(size: PanelType.body))
            case .colour(_, let hex):
                Text(hex).font(.system(size: PanelType.mono, weight: .medium, design: .monospaced))
            default:
                Text(visual.title(for: clip)).font(.system(size: PanelType.body))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.primary)
    }

    /// "Safari · 5m · developer.apple.com": where, when, and one fact.
    private func meta(_ visual: ClipVisual) -> some View {
        var parts = [clip.sourceName, clip.shortAge]
        if let detail = visual.detail(for: clip) { parts.append(detail) }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: PanelType.meta))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            if state.isPinned || state.isFocused {
                PinButton(isPinned: state.isPinned, size: 13, action: onPin)
            }
            if let digit = state.quickPasteDigit {
                Text("⌘\(digit)")
                    .font(.system(size: PanelType.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !metrics.twoLine, state.isFocused {
                // One-line rows have nowhere else to say when.
                Text(clip.shortAge)
                    .font(.system(size: PanelType.caption).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if state.isSelected {
                Image(systemName: "return")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state.isKey ? AnyShapeStyle(PanelPalette.accent) : AnyShapeStyle(.tertiary))
            }
        }
    }
}

// MARK: - Tile

/// A tile of the light strip and the grid: where it came from along the top,
/// the content itself filling the rest. Pictures run edge to edge and code
/// sits on a dark ground, so the kinds stand apart across a row.
struct TileFace: View, Equatable {
    let clip: ClipItem
    let state: CellState
    let size: CGSize
    let padding: CGFloat
    let radius: CGFloat
    /// Lines of text the tile has room for.
    let textLines: Int
    var onPin: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    static func == (lhs: TileFace, rhs: TileFace) -> Bool {
        lhs.clip === rhs.clip && lhs.state == rhs.state && lhs.size == rhs.size
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var isLarge: Bool { size.width >= 180 }

    var body: some View {
        let visual = ClipVisual(clip)
        let dark = isDark(visual)
        ZStack(alignment: .topLeading) {
            if case .picture(let image, _, _) = visual {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .center)
            }
            VStack(alignment: .leading, spacing: 8) {
                header(onDark: dark || isPicture(visual))
                content(visual)
                Spacer(minLength: 0)
            }
            .padding(padding)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .background(fill(visual), in: shape)
        .clipShape(shape)
        .overlay {
            if state.isSelected {
                shape.strokeBorder(state.isKey ? PanelPalette.accent : Color.secondary.opacity(0.5),
                                   lineWidth: 2)
            } else {
                shape.strokeBorder(PanelPalette.hairline(scheme), lineWidth: 0.5)
            }
        }
        .environment(\.colorScheme, dark ? .dark : scheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClipboardPanelView.spokenDescription(of: clip))
    }

    private func isPicture(_ visual: ClipVisual) -> Bool {
        if case .picture = visual { return true }
        return false
    }

    private func isDark(_ visual: ClipVisual) -> Bool {
        if case .text(_, true) = visual { return true }
        return false
    }

    private func fill(_ visual: ClipVisual) -> Color {
        if isDark(visual) { return Color(white: 0.14) }
        if state.isSelected && state.isKey { return PanelPalette.selection(scheme) }
        return state.isHovered ? PanelPalette.tileHover(scheme) : PanelPalette.tile(scheme)
    }

    /// App icon and name, and the age or the quick-paste key.
    private func header(onDark: Bool) -> some View {
        HStack(spacing: 6) {
            AppBadge(clip: clip, side: isLarge ? 18 : 16)
            Text(clip.sourceName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 2)
            if let digit = state.quickPasteDigit {
                Text("⌘\(digit)").font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            } else if state.isFocused {
                Text(clip.shortAge).font(.system(size: 12.5).monospacedDigit())
            }
            if state.isPinned || state.isFocused {
                PinButton(isPinned: state.isPinned, size: 11.5, onDark: onDark, action: onPin)
                    .padding(-5)
            }
        }
        .foregroundStyle(onDark ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
    }

    @ViewBuilder
    private func content(_ visual: ClipVisual) -> some View {
        switch visual {
        case .picture(_, let name, let pictureSize):
            Spacer(minLength: 0)
            if let pictureSize, isLarge {
                Text("\(Int(pictureSize.width)) × \(Int(pictureSize.height))")
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: .capsule)
            } else if clip.fileURL != nil {
                Text(name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }
        case .colour(let colour, let hex):
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colour)
                .frame(maxHeight: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PanelPalette.hairline(scheme), lineWidth: 0.5)
                }
            Text(hex).font(.system(size: PanelType.caption, weight: .semibold, design: .monospaced))
        case .file(let icon, let name, let fileSize):
            HStack(alignment: .top, spacing: 8) {
                Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: PanelType.caption, weight: .medium)).lineLimit(3)
                    if let fileSize {
                        Text(fileSize).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
            }
        case .link(let host, let path):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "link")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PanelPalette.accent)
                    Text(host).font(.system(size: isLarge ? PanelType.body : PanelType.caption, weight: .semibold))
                        .lineLimit(1)
                }
                if !path.isEmpty {
                    Text(path)
                        .font(.system(size: PanelType.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(textLines - 2)
                }
            }
        case .text(let text, let monospaced):
            Text(highlighted(text, search: state.search, scheme: scheme))
                .font(monospaced
                      ? .system(size: isLarge ? PanelType.caption : 11.5, design: .monospaced)
                      : .system(size: isLarge ? PanelType.body : PanelType.caption))
                .foregroundStyle(monospaced ? AnyShapeStyle(Color(red: 0.62, green: 0.92, blue: 0.66)) : AnyShapeStyle(.primary))
                .lineLimit(textLines - 1)
                .lineSpacing(1)
        }
    }
}

// MARK: - Section heading

struct SectionHeading: View {
    let section: RowSection
    /// Upper-case with a count, as in the palette; otherwise a quiet label.
    let emphasised: Bool

    var body: some View {
        HStack {
            Text(emphasised ? (section.title ?? "").uppercased() : (section.title ?? ""))
                .font(.system(size: PanelType.sectionLabel, weight: emphasised ? .semibold : .medium))
                .tracking(emphasised ? 0.4 : 0)
            Spacer()
            if emphasised, let count = section.count {
                Text("\(count)")
                    .font(.system(size: PanelType.sectionLabel).monospacedDigit())
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, emphasised ? 22 : 20)
        .padding(.top, emphasised ? 12 : 10)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, emphasised ? 4 : 3)
    }
}

// MARK: - Attention

/// A permission problem, as a row or a tile at the head of the list: the
/// same place, and the same wording, as the basic style's attention card.
struct AttentionItem: View {
    let title: String
    let detail: String
    let action: AnyView
    let compact: Bool

    var body: some View {
        if compact {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.system(size: PanelType.body, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                action.controlSize(.small)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 9, style: .continuous))
            .help(detail)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.system(size: PanelType.caption, weight: .semibold))
                    .lineLimit(3)
                Spacer(minLength: 0)
                action.controlSize(.mini)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
            .help(detail)
        }
    }
}
