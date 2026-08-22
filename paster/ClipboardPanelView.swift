//
//  ClipboardPanelView.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import SwiftData
import UniformTypeIdentifiers
import SwiftUI

/// Panel geometry, shared with `PanelController` so the two cannot drift.
enum PanelMetrics {
    /// The window is larger than the visible panel by this much on every side,
    /// because a window cannot draw outside its own frame and the ambient
    /// shadow's falloff has to land somewhere.
    ///
    /// It costs something real — the transparent margin still swallows mouse
    /// events, since a borderless window hit-tests its whole frame — so it is
    /// only as wide as the shadow needs (radius plus y-offset), not as wide as
    /// it once had to be to contain an outsized appear animation.
    static let windowMargin: CGFloat = 70

    /// The visible panel, in points. Smaller than it was: a list plus a preview
    /// pane shows more clippings *and* a far larger preview than a grid of
    /// cards did, in about half the screen area.
    static let panelSize = CGSize(width: 1000, height: 640)

    /// Inset from the window edge to the content.
    static let panelPadding: CGFloat = 12

    /// Fixed, not adaptive: the arrow keys need to know the stride to move a
    /// whole row, and a column count the code cannot name is a grid the
    /// keyboard cannot navigate.
    static let gridColumns = 4
    static let cardGap: CGFloat = 12

    /// Every control in Safari's macOS 26 toolbar measures this tall — the
    /// sidebar capsule, the back/forward capsule, the address field and the
    /// actions cluster, all the same, inside a toolbar the accessibility API
    /// reports as 52pt. Measured, not chosen: an earlier pass used 24 and the
    /// header read as a toy.
    static let headerControl: CGFloat = 36
    /// Safari's toolbar glyphs, to the nearest point.
    static let headerGlyph: CGFloat = 15
    /// Safari's address field is 40% of its window's width. This is a little
    /// under that, because a clipboard panel's subject is the grid below.
    static let searchWidth: CGFloat = 340
    /// Between the header's three groups.
    static let headerGlassSpacing: CGFloat = 10

    /// One height for every card.
    ///
    /// Content-driven heights were tried and reverted. `LazyVGrid` lays out by
    /// ROW, so unequal heights do not flow into a masonry — they leave each row
    /// as tall as its tallest card with the others adrift inside it, and the
    /// metadata bands stop sharing a baseline. Real masonry needs independently
    /// flowing columns, which is a different layout entirely.
    ///
    /// So the grid is regular on purpose: every band on one line, every footer
    /// on another. Uniformity is a weakness in a list of wildly different
    /// content, and it is the right trade against a grid that reads as broken.
    static let cardHeight: CGFloat = 150

    /// The card's title zone. Split out because the content zone's height has
    /// to be stated explicitly — a picture that sizes itself grows its
    /// container and the card stops matching its neighbours.
    static let cardBandHeight: CGFloat = 26
    static var cardContentHeight: CGFloat { cardHeight - cardBandHeight }

    /// Room for the overlay scroller to float in.
    ///
    /// The system reports `.overlay` at 17pt here. Hiding the indicator would
    /// be worse — a scrollbar that never appears whatever the user's System
    /// Settings say is a reliable non-native tell — so it gets a gutter instead
    /// of the rightmost card's face.
    static let scrollerGutter = NSScroller.scrollerWidth(for: .regular,
                                                        scrollerStyle: .overlay)

    /// Concentric with the shell: a card sits `panelPadding` from the window
    /// edge, so 24 − 12 = 12 rather than a number somebody liked.
    static let cardRadius: CGFloat = 12

    /// The shell's radius. The one hand-picked radius in the app; every
    /// interior radius derives from it.
    static let cornerRadius: CGFloat = 24

    /// Interior radius, derived rather than chosen: the selection pill sits
    /// 12pt (panel padding) + 6pt (row inset) from the window edge, and
    /// concentricity gives 24 − 18 = 6.
    ///
    /// On macOS 26 an inner shape's radius is a function of its distance to the
    /// container edge, so a hand-picked interior radius is itself the tell. Used
    /// as a literal here for shapes that do not hug a panel corner — where the
    /// concentric formula is meaningless — because the app has one interior
    /// radius, not because a formula produced it.
    static let interiorRadius: CGFloat = 6

    /// Radii clamp on small rects, so anything under about 24×24 needs its own.
    static let thumbnailRadius: CGFloat = 3

    /// Scale the panel starts at when appearing, and returns to when leaving.
    ///
    /// Deliberately tiny, and under 1 rather than over it. Apple's Motion
    /// guidance is blunt about this case: "In apps, generally avoid adding
    /// motion to UI interactions that occur frequently… you generally want to
    /// avoid making people spend extra time paying attention to unnecessary
    /// motion every time they interact with it." A panel summoned dozens of
    /// times a day is exactly that interaction.
    ///
    /// 1.5% is about 16pt of travel on a panel this wide — enough to read as a
    /// settle rather than a cut, little enough that it never becomes the thing
    /// you notice. Under 1 because shrinking from larger reads as the window
    /// rushing at the viewer, where growing into place reads as arriving.
    static let restingScale: CGFloat = 0.985

    /// "Aim for brevity and precision in feedback animations. When animated
    /// feedback is brief and precise, it tends to feel lightweight and
    /// unobtrusive."
    ///
    /// The search field takes focus at the *start* of this, not at its end, so
    /// typing is never gated on the animation — which is the other half of the
    /// guidance: "don't make people wait for an animation to complete before
    /// they can do anything, especially if they have to experience the
    /// animation more than once."
    static let appearDuration: TimeInterval = 0.20
    /// Leaving is faster than arriving. On the way out there is nothing to
    /// read, so getting out of the way promptly is the whole courtesy.
    static let dismissDuration: TimeInterval = 0.12

    /// Honours the system Reduce Motion setting: no scaling at all, just a
    /// brief cross-fade. "Make motion optional. Not everyone can or wants to
    /// experience the motion in your app" — and scaling a surface this large is
    /// exactly what that setting exists to switch off.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var appearAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            // `bounce: 0` is critically damped. A settle is charming the first
            // time and irritating the fortieth.
            : .spring(duration: appearDuration, bounce: 0)
    }

    static var dismissAnimation: Animation {
        .easeOut(duration: reduceMotion ? 0.1 : dismissDuration)
    }
}

/// Drives the panel's appear and dismiss animation.
///
/// Owned by `PanelController`. The panel's SwiftUI tree is built once and then
/// reused across every show/hide, so `onAppear` fires only for the first
/// presentation — the animation has to be driven from outside instead.
@Observable
final class PanelPresentation {
    var isVisible: Bool

    /// Whether the panel is the key window.
    ///
    /// Drives the selection's emphasis. A Mac list draws selection in three
    /// states, not one — accent when the window is key, a de-emphasized grey
    /// when it is visible but not, and a focus ring for a context-menu target
    /// that has not changed the selection. Getting this wrong is among the
    /// most reliable tells of a non-native list, and it matters unusually much
    /// here because this panel is nearly always on screen while another app is
    /// frontmost.
    var isKeyWindow: Bool = true

    init(isVisible: Bool = false) {
        self.isVisible = isVisible
    }
}

/// The panel's backdrop, and the caster of its shadow.
///
/// A standard material rather than Liquid Glass — see `PanelMaterial` for why
/// that is the layer this belongs to.
///
/// AppKit's own window shadow is switched off in `PanelController`. That shadow
/// is inferred from the window's alpha, and `NSHostingView` paints an opaque
/// backing across the whole content rect — so AppKit saw a rectangle and drew a
/// rectangular shadow around the rounded backdrop. Casting the shadow here
/// instead means it comes from the very shape it belongs to.
private struct PanelBackdrop: View {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        PanelMaterial()
            .clipShape(shape)
            // A hairline at the edge, in the semantic separator colour rather
            // than a hand-picked opacity: "use system colors, which already
            // define variants for all these contexts."
            .overlay {
                shape.strokeBorder(.separator, lineWidth: 0.5)
            }
            // Two layers, because a macOS window shadow is two things: a wide
            // ambient falloff and a tight contact line at the edge. A single
            // shadow cannot be both, and tuning one to cover both is what made
            // this read heavier than Xcode's — the weight was concentration,
            // not darkness.
            .shadow(color: .black.opacity(0.16), radius: 40, y: 14)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

// MARK: - Selection

/// Selection on a card is a ring, not a fill.
///
/// A filled card would drown the content it is meant to be showing, so the
/// accent goes on the border. Still three states, keyed off the panel's
/// key-window status rather than view focus: focus lives permanently in the
/// search field so typing filters, and a focus-based test would render every
/// selection grey.
private enum SelectionStyle {
    static func ring(isSelected: Bool, isKey: Bool) -> Color {
        guard isSelected else { return .clear }
        return isKey
            ? Color(nsColor: .controlAccentColor)
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    static func ringWidth(isSelected: Bool) -> CGFloat { isSelected ? 2 : 0.5 }

    static func border(isSelected: Bool) -> Color {
        isSelected ? .clear : Color(nsColor: .separatorColor)
    }
}

/// Coarse time buckets, so the grid carries time context in a handful of
/// headers instead of repeating a relative timestamp on every card.
enum ClipEra: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case week = "Previous 7 Days"
    case earlier = "Earlier"

    static func of(_ date: Date, now: Date = Date()) -> ClipEra {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        return days <= 7 ? .week : .earlier
    }
}

// MARK: - Grouping

/// How the grid is laid out: which sections, in what order, and which cards
/// carry a quick-paste digit.
///
/// Pulled out of the view because the ordering is shared by three things that
/// have to agree — the sections the grid draws, the list the arrow keys walk,
/// and the ⌘1–⌘9 digits — and a disagreement between them is invisible to a
/// test as long as the derivation lives inside a `body`. It was in fact wrong:
/// after a pin moved a card into the leading section, ⌘1 was drawn on two cards
/// at once and two cards showed a selection ring.
enum ClipGrouping {
    /// A clipping together with the digit that pastes it.
    ///
    /// Paired rather than looked up per card. The digit describes a position in
    /// the grid, so deriving it separately from the grid's own ordering makes
    /// two sources of truth that can disagree. It also replaces an O(n) scan
    /// per card with one pass over the list.
    struct Entry: Identifiable {
        let clip: ClipItem
        let digit: Int?
        var id: PersistentIdentifier { clip.persistentModelID }
    }

    /// Identified by its title, not by its position.
    ///
    /// An offset-based id was the other half of the same bug: pinning inserts a
    /// section at the front, so every later section's offset shifts by one and
    /// SwiftUI matches each section's content against the section that used to
    /// be there — leaving cards with properties from a layout they are no
    /// longer part of. Titles are unique by construction: one "Pinned" and at
    /// most one per era.
    struct Section: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let pinnedTitle = "Pinned"

    /// The single ordering everything else reads: pinned first, input order
    /// preserved within each partition.
    ///
    /// The keyboard and the digits both use this, so a pinned card drawn in the
    /// leading section is also the card ⌘1 pastes and the card the up arrow
    /// stops at. Sorting only inside `sections` would leave the keyboard
    /// walking an order the eye does not see.
    static func ordered(_ clips: [ClipItem]) -> [ClipItem] {
        let pinned = clips.filter(\.isPinned)
        guard !pinned.isEmpty else { return clips }
        return pinned + clips.filter { !$0.isPinned }
    }

    /// - Parameter clips: already through `ordered`.
    static func sections(_ clips: [ClipItem], now: Date = Date()) -> [Section] {
        // 1–9 for the first nine cards overall, numbered in the order the grid
        // draws them, so the digits match what the eye counts from the top
        // regardless of where the section boundaries fall.
        var digits: [PersistentIdentifier: Int] = [:]
        for (index, clip) in clips.prefix(9).enumerated() {
            digits[clip.persistentModelID] = index + 1
        }
        func numbered(_ items: [ClipItem]) -> [Entry] {
            items.map { Entry(clip: $0, digit: digits[$0.persistentModelID]) }
        }

        var result: [Section] = []

        // Pinned clippings leave their era entirely rather than appearing twice.
        // A card in two places is a card the arrow keys visit twice and the
        // digits cannot label, and "kept on purpose" is the more useful thing to
        // know about it than when it was copied.
        let pinned = clips.filter(\.isPinned)
        if !pinned.isEmpty {
            result.append(Section(title: pinnedTitle, entries: numbered(pinned)))
        }

        let buckets = Dictionary(grouping: clips.filter { !$0.isPinned }) {
            ClipEra.of($0.copiedAt, now: now)
        }
        result += ClipEra.allCases.compactMap { era in
            guard let items = buckets[era], !items.isEmpty else { return nil }
            return Section(title: era.rawValue, entries: numbered(items))
        }
        return result
    }
}

// MARK: - Root

struct ClipboardPanelView: View {
    /// Invoked by the panel's close button.
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
    /// Held so the grid can be scrolled back to the top while it is hidden.
    @State private var scrollProxy: ScrollViewProxy?
    @State private var hasSeededSelection = false

    private var visible: [ClipItem] {
        // In memory rather than a dynamic @Query predicate: the history is
        // capped at 500 rows, so filtering here costs nothing and keeps the
        // query static.
        let matches = search.isEmpty ? clips : clips.filter {
            $0.previewText?.localizedCaseInsensitiveContains(search) ?? false
        }
        return ClipGrouping.ordered(matches)
    }

    private var selectedClip: ClipItem? {
        clips.first { $0.persistentModelID == selection }
    }

    var body: some View {
        ZStack {
            PanelBackdrop()
            content
        }
        .frame(width: PanelMetrics.panelSize.width, height: PanelMetrics.panelSize.height)
        .padding(PanelMetrics.windowMargin)
        // Declared so interior shapes can derive their corners from the shell's
        // rather than hand-picking one.
        .containerShape(.rect(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        // Scale and fade only — the window's own frame never moves, so the
        // layout is never recomputed and nothing reflows mid-animation.
        .scaleEffect(presentation.isVisible || PanelMetrics.reduceMotion
                     ? 1 : PanelMetrics.restingScale)
        .opacity(presentation.isVisible ? 1 : 0)
        .onChange(of: presentation.isVisible) { _, isVisible in
            if isVisible {
                searchFocused = true
                if selection == nil { selection = visible.first?.persistentModelID }
            } else {
                // Reset on the way OUT, not on the way in. Doing it on show
                // meant the selection change fired the grid's
                // scroll-to-selection while the panel was already on screen, so
                // a grid that had been scrolled visibly rewound to the top every
                // time it was summoned.
                search = ""
                resetScroll()
            }
        }
        .onChange(of: search) { _, _ in
            selection = visible.first?.persistentModelID
        }
        .onAppear {
            guard !hasSeededSelection else { return }
            hasSeededSelection = true
            selection = visible.first?.persistentModelID
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if needsAttention { attentionBanner }
            if visible.isEmpty { emptyState } else { grid }
        }
        .padding(PanelMetrics.panelPadding)
        // Up and down move by a whole row, which is only expressible because
        // the grid has a FIXED column count. With `.adaptive` columns the code
        // cannot know the stride, which is how Down used to step one cell to
        // the right instead of down.
        .onKeyPress(.upArrow) { move(-PanelMetrics.gridColumns); return .handled }
        .onKeyPress(.downArrow) { move(PanelMetrics.gridColumns); return .handled }
        // Left and right move one card, but only while the search field is
        // empty. With text in it the user is editing and the field editor owns
        // those keys; empty, they do nothing there and are ours to use.
        .onKeyPress(.leftArrow) {
            guard search.isEmpty else { return .ignored }
            move(-1); return .handled
        }
        .onKeyPress(.rightArrow) {
            guard search.isEmpty else { return .ignored }
            move(1); return .handled
        }
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

    /// The functional layer, on glass, at Safari's metrics.
    ///
    /// This started as flat monochrome chrome, on the reasoning that the panel's
    /// own material was already the functional layer and glass on top would be
    /// glass on glass. Wrong reading: the guidance puts Liquid Glass in the
    /// **functional** layer, and a panel's header is functional chrome over
    /// content — which is exactly where macOS 26 puts a toolbar's glass.
    ///
    /// Three groups, matching a toolbar's rhythm: window controls, the field,
    /// the actions. That is not a taste call — in a real toolbar *adjacent*
    /// `ToolbarItem`s share one glass capsule and `ToolbarSpacer` breaks them
    /// apart, which is why Safari reads as three groups. A borderless panel has
    /// no titlebar to hang a `.toolbar` on, so it is reproduced by hand.
    ///
    /// The sizes are measured, not chosen. Safari's toolbar on this machine
    /// reports 52pt tall through the accessibility API, and every control in it
    /// measures 36pt tall off a screenshot — the sidebar capsule, the
    /// back/forward capsule, the address field and the actions cluster, all the
    /// same. An earlier pass used 24pt and read as a toy.
    private var header: some View {
        GlassEffectContainer(spacing: PanelMetrics.headerGlassSpacing) {
            HStack(spacing: PanelMetrics.headerGlassSpacing) {
                // Bare, like Safari's. Traffic lights are not glass controls,
                // and being the real ones they come out at the system's 14pt.
                WindowButtons(onClose: onClose)
                    .fixedSize()

                Spacer(minLength: PanelMetrics.headerGlassSpacing)

                actionCluster
            }
            // Centred on the header rather than laid out between the two sides:
            // between `Spacer`s the field would drift, because the action
            // cluster is wider than the traffic lights.
            .overlay { searchField }
        }
        .frame(height: PanelMetrics.headerControl)
    }

    /// The three actions in **one** capsule, the way a toolbar groups adjacent
    /// items.
    ///
    /// Hand-built rather than three `.buttonStyle(.glass)` buttons, and the
    /// reason is measured. Native glass buttons do not participate in
    /// `glassEffectUnion`, so three of them can never merge into one shape. A
    /// raw `.glassEffect` can — but at 24pt circles it rendered essentially
    /// nothing at rest over this panel's light material, with only the
    /// pointer's interactive highlight doing any drawing. At 36pt, which is the
    /// real toolbar metric, the capsule is plainly visible. So the size that is
    /// correct is also the size that makes the correct construction work.
    private var actionCluster: some View {
        HStack(spacing: 0) {
            actionButton(selectedClip?.isPinned == true ? "pin.slash" : "pin",
                         help: selectedClip?.isPinned == true
                             ? "Unpin selected clipping (Command-P)"
                             : "Pin selected clipping (Command-P)",
                         action: pinSelected)
                .keyboardShortcut("p", modifiers: .command)

            // Not `role: .destructive` — a permanently red glyph in chrome is
            // not a Mac convention. Red belongs on the context menu's Delete,
            // where AppKit paints it.
            actionButton("trash",
                         help: "Delete selected clipping (Command-Delete)",
                         action: deleteSelected)
                .keyboardShortcut(.delete, modifiers: .command)

            // A button rather than a `Menu`: everything the old gear menu held —
            // launch at login and the two permission shortcuts — is in Settings
            // now, and a preference in two places is one that disagrees with
            // itself. It also sidesteps `Menu` refusing to render `.glass` at
            // the same strength as a button.
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: PanelMetrics.headerGlyph))
                    .frame(width: PanelMetrics.headerControl,
                           height: PanelMetrics.headerControl)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func actionButton(_ symbol: String,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PanelMetrics.headerGlyph))
                .frame(width: PanelMetrics.headerControl,
                       height: PanelMetrics.headerControl)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(selection == nil)
        .help(help)
    }

    /// A glass capsule, not `.roundedBorder`.
    ///
    /// The stock rounded-border style draws an opaque white rectangle with a hard
    /// edge, which is the most out-of-place thing that can sit on a blurred
    /// panel — it was what made the corner beside it look wrong.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: PanelMetrics.headerGlyph))
                .foregroundStyle(.secondary)

            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { pasteSelected() }

            // Shown only while filtering. A permanent count is decoration, and
            // inside the capsule it reads as part of the field rather than as a
            // label that appeared beside it.
            if !search.isEmpty {
                Text("\(visible.count) of \(clips.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .frame(width: PanelMetrics.searchWidth, height: PanelMetrics.headerControl)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: Attention banner

    private var needsAttention: Bool {
        permissions.hotKeyConflict != nil
            || permissions.needsPasteboardAttention
            || !permissions.canPasteDirectly
    }

    private var attentionBanner: some View {
        HStack(spacing: 8) {
            // The one semantic colour in the chrome, because it maps to a real
            // state rather than to a category.
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(attentionTitle).font(.body.weight(.medium))
                Text(attentionDetail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if permissions.hotKeyConflict != nil {
                // A taken shortcut is fixed in this app's own settings, not in
                // System Settings, so it gets a different destination.
                SettingsLink { Text("Change Shortcut") }
                    .controlSize(.small)
            } else {
                Button("Open Settings") {
                    if permissions.needsPasteboardAttention {
                        permissions.openPasteboardSettings()
                    } else {
                        permissions.openAccessibilitySettings()
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.fill.quaternary, in: .rect(cornerRadius: PanelMetrics.interiorRadius))
    }

    private var attentionTitle: String {
        if permissions.needsPasteboardAttention { "Allow clipboard access to keep saving copies" }
        else if let taken = permissions.hotKeyConflict { "\(taken) is already taken" }
        else { "Grant accessibility access to paste directly" }
    }

    private var attentionDetail: String {
        if permissions.needsPasteboardAttention {
            "macOS asks before an app may read the clipboard. Set this app to Allow."
        } else if permissions.hotKeyConflict != nil {
            "Another app claimed it first. Pick a different one, or click the Dock icon to open the panel."
        } else {
            "Without it, clicking a card copies instead of pasting — press Command-V yourself."
        }
    }

    // MARK: Grid

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: search.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 26))
            Text(search.isEmpty ? "Nothing copied yet" : "No matches").font(.body)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Fixed columns, not adaptive. The arrow keys need to know the stride, and
    /// a layout whose column count the code cannot name is a layout the
    /// keyboard cannot navigate correctly.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PanelMetrics.cardGap),
              count: PanelMetrics.gridColumns)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A zero-height anchor above the grid, so resetting the scroll
                // position returns to the very top rather than to the first
                // card. Scrolling to the card put the card flush with the top
                // edge and pushed its section header out of sight, so a
                // re-summoned panel opened on a grid with no "Pinned" or
                // "Today" heading at all.
                Color.clear.frame(height: 0).id(Self.topAnchor)

                LazyVGrid(columns: columns, alignment: .leading, spacing: PanelMetrics.cardGap) {
                    ForEach(ClipGrouping.sections(visible)) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                card(for: entry)
                            }
                        } header: {
                            // Smaller than the card text and in title case, per
                            // Apple's sidebar spec — a heading the same size as
                            // its content is not a heading. Not uppercased small
                            // caps either; that spelling is the iOS pattern.
                            Text(group.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                                .frame(height: 20, alignment: .leading)
                        }
                    }
                }
            }
            // Not `.hidden`: a scrollbar that never appears whatever the user's
            // System Settings say is a reliable non-native tell.
            .scrollIndicators(.automatic)
            // The gutter goes inside the scroll view, so the indicator has
            // somewhere of its own to sit.
            .padding(.trailing, PanelMetrics.scrollerGutter)
            .onAppear { scrollProxy = proxy }
            // Only follows the selection while the panel is actually on screen.
            .onChange(of: selection) { _, id in
                guard let id, presentation.isVisible else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Extracted because the grid's nested `ForEach`/`Section` plus a card's
    /// modifier chain was more than the type checker would solve in reasonable
    /// time.
    private func card(for entry: ClipGrouping.Entry) -> some View {
        let clip = entry.clip
        return ClipCard(clip: clip,
                        isSelected: clip.persistentModelID == selection,
                        isKey: presentation.isKeyWindow,
                        quickPasteDigit: entry.digit)
            .id(clip.persistentModelID)
            .onTapGesture {
                selection = clip.persistentModelID
                onPaste(clip, false)
            }
            .onDrag { itemProvider(for: clip) }
            .contextMenu {
                Button("Paste") { onPaste(clip, false) }
                Button("Paste as Plain Text") { onPaste(clip, true) }
                Divider()
                Button(clip.isPinned ? "Unpin" : "Pin") { togglePin(clip) }
                Divider()
                Button("Delete", role: .destructive) { delete(clip) }
            }
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.persistentModelID == selection } ?? 0
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

    private func togglePin(_ clip: ClipItem) {
        clip.isPinned.toggle()
        // Explicit for the same reason as `delete`: autosave timing is
        // unpredictable, and a pin the user set should not be pending at quit.
        try? modelContext.save()
    }

    private func pinSelected() {
        guard let clip = visible.first(where: { $0.persistentModelID == selection }) else { return }
        togglePin(clip)
    }

    private func delete(_ clip: ClipItem) {
        modelContext.delete(clip)
        // Explicit: SwiftData's autosave timing is unpredictable, and a delete
        // the user asked for should not be pending when the app quits.
        try? modelContext.save()
    }

    private static let topAnchor = "grid-top"

    private func resetScroll() {
        // Not `clips.first`: with a pin present the newest clipping is no longer
        // the topmost card, so the selection has to come from the same ordering
        // the grid draws.
        selection = ClipGrouping.ordered(clips).first?.persistentModelID
        scrollProxy?.scrollTo(Self.topAnchor, anchor: .top)
    }

    /// Builds a drag payload carrying every stored representation, registered
    /// lazily so a type is only decoded if a drop target asks for it.
    private func itemProvider(for clip: ClipItem) -> NSItemProvider {
        let provider = NSItemProvider()
        for representation in clip.representations {
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

/// A clipping as a card, in two zones.
///
/// The tonal split is what gives a flat card structure: a strip of `.quaternary`
/// carrying the metadata, and the content on the card's own material below it.
/// That device is why Paste's cards read as designed rather than as rectangles —
/// no border, no shadow, no coloured edge and no gradient is doing the work, so
/// none of them are needed. Borrowed as a principle; the proportions, the
/// typography and the arrangement here are our own.
private struct ClipCard: View {
    let clip: ClipItem
    let isSelected: Bool
    let isKey: Bool
    let quickPasteDigit: Int?

    @State private var isHovering = false

    /// The selected card's ring, in the source app's own colour.
    ///
    /// This is the one place the derived colour appears, and the layout is what
    /// keeps it honest: exactly one card is selected, so exactly one coloured
    /// element is ever on screen. Apple's guidance permits colour "for elements
    /// that truly benefit from emphasis, such as status indicators", and asks
    /// you to "refrain from adding colour to the background of multiple
    /// controls" — which is why every other card, and every badge, stays
    /// monochrome.
    ///
    /// The trade-off, stated plainly: selection is normally the *system* accent,
    /// the colour the user chose in System Settings, and this overrides it. It
    /// buys knowing at a glance which app a clipping came from. Falls back to
    /// the system accent for the many deliberately monochrome icons.
    private var ringColor: Color {
        guard isKey else { return SelectionStyle.ring(isSelected: true, isKey: false) }
        return AppAccent.color(forBundleID: clip.sourceBundleID)
            ?? Color(nsColor: .controlAccentColor)
    }

    private var shape: RoundedRectangle {
        // Concentric with the shell: a card sits `panelPadding` from the window
        // edge, so its radius is the shell's less that inset.
        RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
    }

    /// Whether there is a real picture to show.
    ///
    /// When there is, it gets the whole card below the band rather than a
    /// thumbnail in a corner: the preview *is* the identifying information for
    /// a screenshot, and a 54pt square of it was smaller than the space
    /// available by a factor of five.
    private var visualPreview: NSImage? {
        guard clip.kind == .image || clip.kind == .fileURL else { return nil }
        return clip.thumbnailData.flatMap(NSImage.init(data:))
    }

    var body: some View {
        VStack(spacing: 0) {
            band
            if let visualPreview {
                mediaBody(visualPreview)
            } else {
                textBody
            }
        }
        .frame(height: PanelMetrics.cardHeight)
        // A standard material, which is what the content layer is for. Not
        // Liquid Glass and not a hand-picked alpha over the panel.
        .background(.regularMaterial)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isSelected ? ringColor : SelectionStyle.border(isSelected: false),
                               lineWidth: SelectionStyle.ringWidth(isSelected: isSelected))
        }
        .shadow(color: .black.opacity(isHovering ? 0.10 : 0), radius: 4, y: 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    /// Everything below the band for a clipping with no picture.
    private var textBody: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            footer
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    /// A picture filling the content zone, with its caption laid over it.
    ///
    /// The height is stated rather than inferred. A `resizable` image with
    /// `aspectRatio(.fill)` proposes a size larger than its container and grows
    /// it — `.clipped()` then trims something that has already pushed the card
    /// taller than its neighbours. Sizing an empty `Color` and hanging the
    /// picture off it as an overlay is what keeps the geometry the card's and
    /// not the image's.
    ///
    /// Fill rather than fit, because a letterboxed screenshot leaves two grey
    /// bands where the picture should be. The caption sits on a gradient scrim:
    /// text over an arbitrary image needs one, and a dimming layer is what
    /// Apple's guidance prescribes for exactly this case.
    private func mediaBody(_ image: NSImage) -> some View {
        Color.clear
            .frame(height: PanelMetrics.cardContentHeight)
            .background {
                // Behind the picture, so a transparent PNG reads as transparent.
                Canvas { context, size in
                    let square = 8.0
                    for row in 0 ... Int(size.height / square) {
                        for column in 0 ... Int(size.width / square) {
                            guard (row + column).isMultiple(of: 2) else { continue }
                            context.fill(
                                Path(CGRect(x: Double(column) * square,
                                            y: Double(row) * square,
                                            width: square, height: square)),
                                with: .style(.quaternary)
                            )
                        }
                    }
                }
            }
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.66)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 30)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Text(mediaCaption)
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let quickPasteDigit {
                        Text("⌘\(quickPasteDigit)")
                            .font(.footnote.monospacedDigit())
                    }
                }
                // White on the scrim regardless of appearance: what is
                // underneath is the user's picture, not the app's background.
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            // Last, so nothing an overlay draws can escape the content zone.
            .clipped()
    }

    /// The name for a file, the size for a bare image — whichever actually
    /// identifies the thing.
    private var mediaCaption: String {
        if clip.kind == .fileURL, let name = fileName { return name }
        return clip.lengthSummary ?? ""
    }

    /// The metadata strip. A word for the kind, the time beside it, and the
    /// source app's real icon at the trailing edge.
    private var band: some View {
        HStack(spacing: 6) {
            if clip.isPinned {
                // Monochrome, like every other badge here. Colour in this
                // interface is reserved for the one selected card's ring, and a
                // grid of orange pins would take that distinction away.
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Kept regardless of the history limit")
            }
            Text(clip.kindLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Text(compactAge)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            icon.frame(width: 16, height: 16)
        }
        .padding(.horizontal, 10)
        .frame(height: PanelMetrics.cardBandHeight)
        .background(.fill.quaternary)
    }

    @ViewBuilder
    private var icon: some View {
        if clip.isFromRemoteDevice {
            // Checked first: the frontmost app's icon would be a lie here.
            Image(systemName: "iphone.gen3")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else if let appIcon = AppAccent.icon(for: clip.sourceBundleID) {
            // Never tinted. Real app icons are the most anti-template asset in
            // the interface: per-item, unrepeatable, and impossible for a
            // generated layout to have.
            Image(nsImage: appIcon).resizable()
        } else {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Per-kind content

    @ViewBuilder
    private var preview: some View {
        switch clip.kind {
        case .link: linkPreview
        case .image: imagePreview
        case .fileURL: filePreview
        case .text, .richText: textPreview
        case .other: placeholder("questionmark.square.dashed")
        }
    }

    /// Host prominent, path quiet. What is useful about a URL is where it
    /// points, and the path is what tells two links to the same site apart.
    private var linkPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(clip.linkURL?.host ?? "")
                .font(.body.weight(.medium))
                .lineLimit(1)
            if let path = clip.linkURL?.path, path.count > 1 {
                Text(path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    /// Only reached when an image clipping has no derived thumbnail, which means
    /// the capture could not decode it.
    private var imagePreview: some View {
        Image(systemName: "photo")
            .font(.system(size: 22))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only reached when QuickLook could not preview the file — an archive, a
    /// binary, something with no visual form. The type icon and the name are
    /// then all there is to show.
    private var filePreview: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: fileIcon)
                .resizable()
                .frame(width: 30, height: 30)
            Text(fileName ?? "File")
                .font(.callout)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    private var textPreview: some View {
        Text(clip.previewText ?? "")
            .font(clip.prefersMonospacedPreview
                  ? .system(size: 11, design: .monospaced)
                  : .callout)
            .lineSpacing(clip.prefersMonospacedPreview ? 1 : 2)
            .lineLimit(clip.prefersMonospacedPreview ? 6 : 5)
            .multilineTextAlignment(.leading)
    }

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    /// A measurement and a shortcut. Both monochrome — a tinted badge on every
    /// card is colour on multiple controls at once, which is the thing Apple's
    /// colour guidance asks you not to do.
    private var footer: some View {
        HStack(spacing: 4) {
            if let length = clip.lengthSummary {
                Text(length)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let quickPasteDigit {
                Text("⌘\(quickPasteDigit)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Derived

    /// "47s", "4m", "2h", "3d" — the long form crowded out the kind label on a
    /// 230pt card, and at a glance the unit is all that is being read anyway.
    private var compactAge: String {
        let seconds = Int(Date().timeIntervalSince(clip.copiedAt))
        switch seconds {
        case ..<60: return "\(max(seconds, 0))s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    private var fileName: String? {
        guard let text = clip.previewText else { return nil }
        return URL(string: text)?.lastPathComponent ?? text
    }

    /// The real Finder icon for the file's type, so a PDF looks like a PDF.
    private var fileIcon: NSImage {
        guard let text = clip.previewText, let url = URL(string: text) else {
            return NSWorkspace.shared.icon(for: .data)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}


#Preview {
    ClipboardPanelView()
        .modelContainer(for: [ClipItem.self, ClipPayload.self, ClipRepresentation.self],
                        inMemory: true)
}
