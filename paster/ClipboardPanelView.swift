//
//  ClipboardPanelView.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import SwiftData
import SwiftUI

/// Panel geometry, shared with `PanelController` so the two cannot drift.
enum PanelMetrics {
    static let cornerRadius: CGFloat = 24
    /// The window is larger than the visible panel by this much on every side.
    /// A window cannot draw outside its own frame, and two things here need to
    /// exceed the panel: the ambient shadow's falloff, and the appear
    /// animation's enlarged start state. Both get clipped square at the window
    /// edge without the room.
    ///
    /// This does cost something — the transparent margin still swallows mouse
    /// events, since a borderless window hit-tests its whole frame — so it is
    /// sized to what the animation actually shows rather than to `appearScale`
    /// in full. See `appearScale`.
    static let windowMargin: CGFloat = 110
    /// Scale the panel starts at when appearing, then settles to 1.
    ///
    /// Measured off macOS 26 Spotlight, which starts near 1.2. The overshoot
    /// past `windowMargin` clips, but only during the frames where opacity is
    /// still near zero — the enlarged state is invisible while it is largest,
    /// which is why this can exceed what the margin strictly covers.
    static let appearScale: CGFloat = 1.15
}

/// Drives the panel's appear and dismiss animation.
///
/// Owned by `PanelController`. The panel's SwiftUI tree is built once and then
/// reused across every show/hide, so `onAppear` fires only for the first
/// presentation — the animation has to be driven from outside instead.
@Observable
final class PanelPresentation {
    var isVisible: Bool

    init(isVisible: Bool = false) {
        self.isVisible = isVisible
    }
}

/// The single glass surface in the app: a frosted sheet that blurs whatever
/// sits behind the window, and the caster of the panel's shadow.
///
/// AppKit's own window shadow is switched off in `PanelController`. That
/// shadow is inferred from the window's alpha, and `NSHostingView` paints an
/// opaque backing across the whole content rect — so AppKit saw a rectangle
/// and drew a rectangular shadow around the rounded glass. Casting the shadow
/// here instead means it comes from the very shape it belongs to.
private struct GlassBackdrop: View {
    var body: some View {
        RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
            .fill(.clear)
            .glassEffect(.regular, in: .rect(cornerRadius: PanelMetrics.cornerRadius,
                                             style: .continuous))
            // Two layers, because a macOS window shadow is two things: a wide
            // ambient falloff and a tight contact line at the edge. A single
            // shadow cannot be both, and tuning one to cover both is what made
            // this read heavier than Xcode's — the weight was concentration,
            // not darkness.
            .shadow(color: .black.opacity(0.16), radius: 40, y: 14)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

// MARK: - Card surface

/// Flat translucent card. Deliberately not another `.glassEffect()` — the
/// panel background is already glass, and glass stacked on glass loses contrast
/// and stops reading as blur.
private extension View {
    func cardSurface<S: Shape>(in shape: S) -> some View {
        background(.background.opacity(0.5), in: shape)
            .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Root

struct ClipboardPanelView: View {
    var onClose: () -> Void = {}
    /// The panel does not paste itself — that needs the previously-frontmost
    /// app, which only `PanelController` knows.
    var onPaste: (ClipItem, Bool) -> Void = { _, _ in }

    var presentation = PanelPresentation(isVisible: true)
    var permissions = PermissionsService()
    var launchAtLogin = LaunchAtLogin()

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipItem.copiedAt, order: .reverse) private var clips: [ClipItem]

    @State private var search = ""
    @State private var selection: PersistentIdentifier?
    @FocusState private var searchFocused: Bool

    private var visible: [ClipItem] {
        // In memory rather than a dynamic @Query predicate: the history is
        // capped at 500 rows, so filtering here costs nothing and keeps the
        // query static.
        guard !search.isEmpty else { return clips }
        return clips.filter {
            $0.previewText?.localizedCaseInsensitiveContains(search) ?? false
        }
    }

    var body: some View {
        ZStack {
            GlassBackdrop()
            content
        }
        .frame(minWidth: 1040, minHeight: 720)
        .padding(PanelMetrics.windowMargin)
        // Scale and fade only — the window's own frame never moves, so the
        // layout is never recomputed and nothing reflows mid-animation.
        .scaleEffect(presentation.isVisible ? 1 : PanelMetrics.appearScale)
        .opacity(presentation.isVisible ? 1 : 0)
        .onChange(of: presentation.isVisible) { _, isVisible in
            if isVisible {
                searchFocused = true
                selection = self.visible.first?.persistentModelID
            } else {
                search = ""
            }
        }
        // Keeps the highlight on a row that exists. Return then always has a
        // target the user can actually see, instead of the previous behaviour
        // of falling back to "the newest clip" and pasting something they never
        // selected into their document.
        .onChange(of: search) { _, _ in
            selection = visible.first?.persistentModelID
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if needsAttention { attentionBanner }
            if visible.isEmpty { emptyState } else { grid }
        }
        .padding(20)
        // Up/down only. Left/right belong to the focused search field's editor,
        // and Return is handled by the field itself via .onSubmit — routing it
        // here would fight the editor for a key it already implements. Delete
        // is a real button with a shortcut rather than a raw key handler, so an
        // unmodified Delete while typing can never destroy a clipping.
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        // Quick Paste. Command-digit rather than a bare digit, because a bare
        // digit belongs to whatever you are typing in the search field.
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard press.modifiers.contains(.command),
                  let digit = press.characters.first.flatMap({ Int(String($0)) }),
                  digit >= 1
            else { return .ignored }
            let index = digit - 1
            guard visible.indices.contains(index) else { return .ignored }
            onPaste(visible[index], press.modifiers.contains(.shift))
            return .handled
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(.background.opacity(0.5), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Close panel")

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { pasteSelected() }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: 360)
            .cardSurface(in: .capsule)

            Text("\(visible.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button(role: .destructive, action: deleteSelected) {
                Image(systemName: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selection == nil)
            .help("Delete selected clipping (Command-Delete)")

            Menu {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let error = launchAtLogin.lastError {
                    Text(error).font(.caption)
                }
                Divider()
                Button("Accessibility settings…") { permissions.openAccessibilitySettings() }
                Button("Clipboard access settings…") { permissions.openPasteboardSettings() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Permission banner

    private var needsAttention: Bool {
        permissions.hotKeyConflict
            || permissions.needsPasteboardAttention
            || !permissions.canPasteDirectly
    }

    /// One banner, most-blocking first: losing history beats a dead shortcut,
    /// and a dead shortcut beats a paste that merely degrades to a copy.
    private var attentionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                if permissions.needsPasteboardAttention {
                    Text("Allow clipboard access to keep saving copies")
                        .font(.callout.weight(.medium))
                    Text("macOS asks before an app may read the clipboard. Set this app to Allow.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if permissions.hotKeyConflict {
                    Text("Command-Shift-V is already taken by another app")
                        .font(.callout.weight(.medium))
                    Text("Click this app's Dock icon to reopen the panel until the conflict is resolved.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Grant accessibility access to paste directly")
                        .font(.callout.weight(.medium))
                    Text("Without it, clicking a card copies instead of pasting — press Cmd-V yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if permissions.needsPasteboardAttention {
                Button("Open Settings") { permissions.openPasteboardSettings() }
            } else if !permissions.hotKeyConflict {
                Button("Open Settings") { permissions.openAccessibilitySettings() }
            }
        }
        .padding(12)
        .cardSurface(in: .rect(cornerRadius: 12))
    }

    // MARK: Grid

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: search.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 32))
            Text(search.isEmpty ? "Nothing copied yet" : "No matches").font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(Array(visible.enumerated()), id: \.element.persistentModelID) { index, clip in
                        ClipCard(clip: clip,
                                 isSelected: clip.persistentModelID == selection,
                                 quickPasteDigit: index < 9 ? index + 1 : nil)
                            .id(clip.persistentModelID)
                            .onTapGesture { onPaste(clip, false) }
                            // Zero-permission alternative to synthesising a
                            // keystroke: the user drags the card straight into
                            // the target app.
                            .onDrag { itemProvider(for: clip) }
                            .contextMenu {
                                Button("Paste") { onPaste(clip, false) }
                                Button("Paste as Plain Text") { onPaste(clip, true) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(clip) }
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.persistentModelID == selection } ?? -1
        let next = min(max(current + delta, 0), list.count - 1)
        selection = list[next].persistentModelID
    }

    /// No fallback to "the first item" on a stale selection. Pasting something
    /// the user did not choose into a real document is worse than doing nothing.
    private func pasteSelected() {
        guard let clip = visible.first(where: { $0.persistentModelID == selection }) else { return }
        onPaste(clip, false)
    }

    private func deleteSelected() {
        guard let index = visible.firstIndex(where: { $0.persistentModelID == selection })
        else { return }
        let doomed = visible[index]

        // Chosen before the delete, because afterwards `visible` has already
        // shifted and the old index means something different.
        let survivors = visible.filter { $0.persistentModelID != selection }
        selection = survivors.indices.contains(index)
            ? survivors[index].persistentModelID
            : survivors.last?.persistentModelID

        delete(doomed)
    }

    private func delete(_ clip: ClipItem) {
        modelContext.delete(clip)
        // Explicit: SwiftData's autosave timing is unpredictable, and a delete
        // the user asked for should not be pending when the app quits.
        try? modelContext.save()
    }

    /// Builds a drag payload carrying every stored representation.
    ///
    /// Previously this returned an empty provider for anything that was not
    /// plain text, so dragging an image or a file out did nothing at all.
    /// Registering each representation lazily means the payload is only decoded
    /// if a drop target actually asks for that type.
    private func itemProvider(for clip: ClipItem) -> NSItemProvider {
        let provider = NSItemProvider()
        let representations = clip.representations
        guard !representations.isEmpty else { return provider }

        for representation in representations {
            provider.registerDataRepresentation(
                forTypeIdentifier: representation.typeIdentifier,
                visibility: .all
            ) { completion in
                completion(representation.data, nil)
                return nil
            }
        }
        return provider
    }
}

// MARK: - Card

private struct ClipCard: View {
    let clip: ClipItem
    let isSelected: Bool
    /// 1–9 for the first nine cards, so the shortcut is discoverable rather
    /// than something you have to read the README to find.
    let quickPasteDigit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(height: 170)
        .padding(12)
        .cardSurface(in: .rect(cornerRadius: 14))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch clip.kind {
        case .image:
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder("photo")
            }
        case .fileURL:
            HStack(spacing: 8) {
                Image(systemName: "doc").font(.title2)
                Text(fileName ?? "File").font(.callout).lineLimit(2)
            }
        case .text, .richText:
            Text(clip.previewText ?? "")
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(7)
                .multilineTextAlignment(.leading)
        case .other:
            placeholder("questionmark.square.dashed")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let icon = sourceIcon {
                Image(nsImage: icon).resizable().frame(width: 13, height: 13)
            }
            Text(clip.copiedAt.formatted(.relative(presentation: .numeric)))
                .font(.caption2)
            Spacer()
            if clip.kind == .richText {
                Text("RICH").font(.system(size: 8, weight: .bold))
            }
            if let quickPasteDigit {
                Text("⌘\(quickPasteDigit)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
            }
        }
        .foregroundStyle(.secondary)
    }

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 28))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Reads the small PNG derived at capture time. Never touches the
    /// full-size representation: `body` re-runs on every keystroke in the
    /// search field, and decoding multi-megabyte blobs per visible card each
    /// time is what makes a grid of screenshots stutter.
    private var thumbnail: NSImage? {
        guard let data = clip.thumbnailData else { return nil }
        return NSImage(data: data)
    }

    private var fileName: String? {
        guard let text = clip.previewText else { return nil }
        return URL(string: text)?.lastPathComponent ?? text
    }

    private var sourceIcon: NSImage? {
        guard let bundleID = clip.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

#Preview {
    ClipboardPanelView()
        .modelContainer(for: [ClipItem.self, ClipPayload.self, ClipRepresentation.self],
                        inMemory: true)
}
