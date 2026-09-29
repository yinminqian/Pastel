//
//  ClipboardPanelView.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import SwiftUI

/// Panel geometry, shared with `PanelController` so the two cannot drift.
///
/// A strip docked along the bottom of the screen, one row of square cards that
/// scrolls sideways, and a thin toolbar above it.
enum PanelMetrics {
    /// The visible panel's height. Its width is the screen's.
    static let panelHeight: CGFloat = 324

    /// Gap between the panel and the screen's left, right and bottom edges.
    static let screenInset: CGFloat = 8

    /// Transparent room above the panel. There is no shadow to hold any more;
    /// this is only enough for the glass's edge highlight to not be clipped.
    static let shadowMargin: CGFloat = 4

    /// The window's height. The window spans the screen's full width.
    static var windowHeight: CGFloat { panelHeight + screenInset + shadowMargin }

    static let cornerRadius: CGFloat = 22

    /// With `panelHeight`, puts the cards 68 pt below the panel's top edge and
    /// the toolbar's centre 30 pt below it.
    static let headerHeight: CGFloat = 62

    /// Cards are square.
    static let cardSide: CGFloat = 232
    static let cardGap: CGFloat = 24
    static let cardRadius: CGFloat = 14
    /// The coloured strip carrying the kind and the age.
    static let cardBandHeight: CGFloat = 48
    static let cardFooterHeight: CGFloat = 32
    /// The share of a macOS app icon's canvas its visible tile occupies: 824
    /// of 1024 on Apple's icon grid. The rest is transparent margin.
    static let appIconTileRatio: CGFloat = 824.0 / 1024.0
    /// How far the icon's tile runs past the card's top and right edges.
    /// Flush, the tile's own rounded bottom-right corner left a notch of band
    /// colour between it and the card's edge; pushed out by this much, that
    /// corner is outside the card and the band clips it off.
    static let cardIconOverflow: CGFloat = 10
    /// Sized so the icon's visible *tile*, not its canvas, reaches from the
    /// band's bottom edge to past the card's top.
    static var cardIconSide: CGFloat { (cardBandHeight + cardIconOverflow) / appIconTileRatio }
    /// How far the icon is pushed out of the top-right corner: its canvas
    /// margin, so the tile rather than the canvas meets the corner, plus the
    /// overflow.
    static var cardIconOffset: CGFloat {
        (cardIconSide - cardBandHeight - cardIconOverflow) / 2 + cardIconOverflow
    }

    /// Inset from the panel's left and right edges to the first and last card.
    static let rowInset: CGFloat = 24

    /// Drawn outside the card, so selecting one never shifts its content.
    static let selectionRingWidth: CGFloat = 3
    /// The card's shadow, which lifts it off the glass in place of a stroke.
    static let cardShadowRadius: CGFloat = 2
    static let cardShadowY: CGFloat = 1
    /// From the header's bottom edge to the cards' top.
    static let cardTopGap: CGFloat = 6

    static let searchWidth: CGFloat = 220

    /// Honours the system Reduce Motion setting: a fade in place of the slide.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var appearAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            // Critically damped: it arrives and stops, with no bounce to watch
            // on something summoned dozens of times a day.
            : .spring(duration: 0.2, bounce: 0)
    }

    /// Leaving is faster than arriving; there is nothing to read on the way out.
    static var dismissAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.1) : .easeIn(duration: 0.18)
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
    /// Drives the selection's emphasis: accent when key, a de-emphasized grey
    /// when visible but not. Observed by `PanelController` rather than read from
    /// `\.appearsActive`, which is not reliable for a non-activating panel.
    var isKeyWindow: Bool = true

    /// Whether ⌘ is held. The quick-paste numbers are only drawn then: they
    /// are needed at the moment you reach for ⌘1–⌘9, and the rest of the time
    /// they are nine bits of clutter.
    var isCommandHeld: Bool = false

    /// Whether the search field is open. Esc reads this: while searching it
    /// ends the search, and only once the field is closed does it close the
    /// panel.
    var isSearching: Bool = false
    /// Bumped by Esc while searching. A counter rather than a flag, so the view
    /// sees every press, not just the first.
    var searchCancellations: Int = 0

    /// Set by `PanelController` each time the panel opens.
    var style: PanelStyle = .basic
    /// The app a paste goes into, for the palette's "Paste into …" button.
    var targetAppName: String?

    init(isVisible: Bool = false) {
        self.isVisible = isVisible
    }
}

/// The panel's backdrop: Liquid Glass, flat.
///
/// No drop shadow and no stroke. The glass draws its own edge highlight, and a
/// shadow under a strip docked on the screen's edge only reads as a heavy grey
/// halo over whatever is behind it.
///
/// Tinted with the window background colour, so it reads as bright, milky
/// glass rather than taking on the grey of a dark terminal behind it. The
/// colour adapts, so in Dark Mode the tint is dark.
///
/// Nothing on the header is glass: glass controls on a glass backdrop have
/// nothing to refract but more glass, and came out as flat white discs.
private struct PanelBackdrop: View {
    var body: some View {
        Color.clear
            .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)),
                         in: .rect(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
    }
}

/// Which clippings the row shows: all of them, or only the pinned ones.
nonisolated enum PanelTab: Hashable, Sendable {
    case clipboard
    case pinned
}

/// The ⋯ menu. Its own view because it reads the selection, and whatever
/// reads the selection redraws on every arrow press — this way that is a menu
/// button rather than the whole panel.
private struct MoreMenu: View {
    let model: RowModel
    var onPastePlain: (ClipItem) -> Void
    var onPin: () -> Void
    var onDelete: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let selected = model.selected.flatMap { $0.isGone ? nil : $0 }
        Menu {
            Button("Paste as Plain Text") {
                if let selected { onPastePlain(selected) }
            }
            .disabled(selected == nil)
            // No `keyboardShortcut` here: `shortcutButtons` owns ⌘P and ⌘⌫,
            // and a second registration risks one keypress toggling twice.
            Button(selected?.isPinned == true ? String(localized: "Unpin  ⌘P") : String(localized: "Pin  ⌘P"), action: onPin)
                .disabled(selected == nil)
            Button("Delete  ⌘⌫", action: onDelete)
                .disabled(selected == nil)
            Divider()
            // Not `SettingsLink`: from a panel that never activates the app,
            // Settings would open behind whatever is in front.
            Button("Settings…") {
                NSApp.activate()
                openSettings()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

// MARK: - Root

struct ClipboardPanelView: View {
    /// Invoked when the panel should go away.
    var onClose: () -> Void = {}
    /// The panel does not paste itself — that needs the previously-frontmost
    /// app, which only `PanelController` knows.
    var onPaste: (ClipItem, Bool) -> Void = { _, _ in }

    var presentation = PanelPresentation(isVisible: true)
    var permissions = PermissionsService()
    var launchAtLogin = LaunchAtLogin()

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \ClipItem.copiedAt, order: .reverse) private var clips: [ClipItem]

    @State private var search = ""
    /// Open because it was asked for (🔍 or ⌘F), even with nothing typed yet.
    @State private var searchOpen = false
    @State private var kindFilter: ClipSearch.KindFilter?
    @State private var tab: PanelTab = .clipboard
    @FocusState private var searchFocused: Bool
    @State private var hasSeededSelection = false

    /// The selection and what else the cards read. Deliberately not read by
    /// this view's body: see `RowModel`.
    @State private var rowModel = RowModel()

    /// Newest first, in the order the row draws them — which is also the order
    /// the arrow keys walk and ⌘1–⌘9 count.
    ///
    /// Stored, and recomputed only when one of its inputs changes. As a
    /// computed property it was re-derived, several times over, on every pass
    /// of the body — O(n) work on every keystroke.
    @State private var visible: [ClipItem] = []
    /// `visible`, cut into the runs the style shows under headings. One run
    /// for the styles without any.
    @State private var rowSections: [RowSection] = []
    @State private var pinnedCount = 0

    private var selection: ClipItem? {
        get { rowModel.selected }
        nonmutating set { rowModel.selected = newValue }
    }

    private var query: ClipSearch { ClipSearch(query: search, kind: kindFilter) }

    /// Whether the header shows the full search field rather than the 🔍.
    private var isSearching: Bool { searchOpen || query.isActive }

    /// Re-derives `visible` and what the cards read from it.
    ///
    /// In memory rather than a dynamic @Query predicate, which keeps the query
    /// static; filtering even 10,000 rows here is well inside a frame, and it
    /// only happens when the history, the search or the tab changes.
    private func refreshVisible() {
        let scoped = tab == .pinned ? clips.filter(\.isPinned) : clips
        let query = self.query
        let matching = query.isActive
            ? scoped.filter {
                query.matches($0, appName: AppAccent.displayName(forBundleID: $0.sourceBundleID))
            }
            : scoped
        pinnedCount = clips.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }

        switch presentation.style {
        case .palette:
            // Pinned first, under their own heading. `visible` takes the same
            // order, so the arrows and ⌘1–⌘9 walk what the eye sees.
            let pinned = matching.filter(\.isPinned)
            let rest = matching.filter { !$0.isPinned }
            visible = pinned + rest
            var sections: [RowSection] = []
            if !pinned.isEmpty {
                sections.append(RowSection(id: "pinned", title: String(localized: "Pinned"), count: pinned.count, clips: pinned))
            }
            rowSections = sections + Self.daySections(rest)
        case .sidebar:
            visible = matching
            rowSections = query.isActive
                // Ranked by recency still, but one run: day headings over a
                // handful of results only interrupt them.
                ? [RowSection(id: "results", clips: matching)]
                : Self.daySections(matching)
        default:
            visible = matching
            rowSections = [RowSection(id: "all", clips: matching)]
        }

        rowModel.quickPasteOrder = visible.prefix(9).map(\.persistentModelID)
        rowModel.search = query.terms.isEmpty ? nil : query
        // The selection is held as an object, so a clipping deleted from
        // outside the panel — Clear History, the retention limits — would
        // otherwise leave it pointing at a deleted model.
        if let selected = rowModel.selected, !visible.contains(where: { $0 === selected }) {
            rowModel.selected = visible.first
        }
    }

    /// Runs of clippings copied on the same day, newest first: Today,
    /// Yesterday, then the day's name within the week, then the date.
    static func daySections(_ clips: [ClipItem]) -> [RowSection] {
        let calendar = Calendar.current
        var sections: [RowSection] = []
        var currentDay: Date?
        for clip in clips {
            let day = calendar.startOfDay(for: clip.copiedAt)
            if day != currentDay {
                currentDay = day
                sections.append(RowSection(id: "day-\(Int(day.timeIntervalSince1970))",
                                           title: dayTitle(day, calendar: calendar),
                                           clips: []))
            }
            sections[sections.count - 1].clips.append(clip)
        }
        for index in sections.indices { sections[index].count = sections[index].clips.count }
        return sections
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: .now)).day ?? 0
        if days < 7 { return day.formatted(.dateTime.weekday(.wide)) }
        return day.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        Group {
            if presentation.style == .basic {
                basicPanel
            } else {
                styledPanel
                    // A fresh view per style: the list's layout is fixed when
                    // its view is made, and must not be carried over.
                    .id(presentation.style)
            }
        }
        .background { shortcutButtons }
        .onKeyPress(.leftArrow) { arrow(dx: -1) }
        .onKeyPress(.rightArrow) { arrow(dx: 1) }
        .onKeyPress(.upArrow) { arrow(dy: -1) }
        .onKeyPress(.downArrow) { arrow(dy: 1) }
        // ⇧↩ pastes as plain text; a plain ↩ is the search field's submit.
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift), let clip = visibleSelection else { return .ignored }
            onPaste(clip, true)
            return .handled
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
        .onChange(of: presentation.isVisible) { _, isVisible in
            if isVisible {
                searchFocused = true
                // Always the first card, not only when nothing is selected: a
                // paste moves its card to the front *after* the panel has
                // gone, so the selection reset on the way out is by now on
                // what has become the second card.
                selection = visible.first
            } else {
                // Reset on the way OUT, so a re-summoned panel does not visibly
                // rewind while it is already on screen.
                endSearch()
                resetScroll()
            }
        }
        .onChange(of: presentation.style) { _, _ in
            refreshVisible()
            selection = visible.first
        }
        .onChange(of: clips, initial: true) { _, _ in
            refreshVisible()
        }
        .onChange(of: search) { _, _ in
            refreshVisible()
            selection = visible.first
        }
        .onChange(of: kindFilter) { _, _ in
            refreshVisible()
            selection = visible.first
        }
        .onChange(of: isSearching, initial: true) { _, searching in
            presentation.isSearching = searching
        }
        // Esc while searching ends the search; the next one closes the panel.
        .onChange(of: presentation.searchCancellations) { _, _ in
            endSearch()
        }
        .onChange(of: tab) { _, _ in
            refreshVisible()
            selection = visible.first
            rowModel.scrollToStart?()
        }
        .onAppear {
            guard !hasSeededSelection else { return }
            hasSeededSelection = true
            selection = visible.first
        }
    }

    /// Which arrows walk the list depends on its shape. Sideways arrows are
    /// the search field's while it has text; a list's up and down are always
    /// the list's, so "type, ↓, Return" works.
    private func arrow(dx: Int = 0, dy: Int = 0) -> KeyPress.Result {
        switch presentation.style.arrowAxis {
        case .horizontal:
            guard dx != 0, search.isEmpty else { return .ignored }
            move(dx)
        case .vertical:
            guard dy != 0 else { return .ignored }
            move(dy)
        case .both(let columns):
            if dy != 0 {
                move(dy * columns)
            } else {
                guard search.isEmpty else { return .ignored }
                move(dx)
            }
        }
        return .handled
    }

    private var basicPanel: some View {
        VStack(spacing: 0) {
            // The top margin. The panel hangs from the bottom of the window.
            Spacer(minLength: 0)
            ZStack {
                PanelBackdrop()
                content
            }
            .frame(height: PanelMetrics.panelHeight)
            .containerShape(.rect(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        }
        .padding([.horizontal, .bottom], PanelMetrics.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Slides up out of the bottom of the screen. The window's own frame
        // never moves: the content is pushed below it and clipped by it, so the
        // layout is never recomputed mid-animation.
        .offset(y: presentation.isVisible || PanelMetrics.reduceMotion
                ? 0 : PanelMetrics.windowHeight)
        .opacity(presentation.isVisible || !PanelMetrics.reduceMotion ? 1 : 0)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            if visible.isEmpty && !needsAttention { emptyState } else { row }
        }
    }

    /// ⌘P and ⌘⌫, which have no visible button of their own any more.
    ///
    /// The ⋯ menu names them but cannot perform them: a pop-up menu's key
    /// equivalents are only live while it is open. These answer the keys —
    /// invisible, but in the hierarchy, which is what `keyboardShortcut` needs.
    private var shortcutButtons: some View {
        ZStack {
            Button("Pin", action: pinSelected)
                .keyboardShortcut("p", modifiers: .command)
            Button("Delete", action: deleteSelected)
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Find", action: openSearch)
                .keyboardShortcut("f", modifiers: .command)
            // ⌘, is the app menu's, and the app menu is not in the menu bar:
            // the panel never activates the app, so the menu bar still
            // belongs to whatever was in front and the keystroke found no
            // taker. Activating first brings Settings to the front; the panel
            // then loses key and goes away by itself.
            Button("Settings") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Header

    /// Search and the tabs in the middle, the ⋯ menu at the trailing edge.
    private var header: some View {
        ZStack {
            HStack {
                Spacer()
                moreMenu
            }
            // The tabs stay while searching, so a search can be scoped to
            // Pinned.
            HStack(spacing: 8) {
                searchControl
                if isSearching { kindMenu(glass: false) }
                GlassTabs(selection: $tab, glass: false, items: [
                    .init(.clipboard, String(localized: "Clipboard")) {
                        Image(systemName: "clock.arrow.circlepath")
                    },
                    .init(.pinned, String(localized: "Pinned")) {
                        Circle().fill(.red).frame(width: 11, height: 11)
                    },
                ])
            }
            .animation(.easeOut(duration: 0.15), value: isSearching)
        }
        .padding(.horizontal, 16)
        // 1 pt above the frame's centre, which reads as centred against the
        // cards below.
        .padding(.bottom, 2)
        .frame(height: PanelMetrics.headerHeight)
    }

    /// 🔍 until it is clicked, ⌘F is pressed or anything is typed; then a
    /// search field with a type filter, a result count and a clear button.
    ///
    /// The `TextField` is always in the hierarchy, at the same place, and
    /// always focused — only collapsed while closed. That is what lets typing
    /// filter from the first keystroke: a field swapped in on the first
    /// keystroke would drop that keystroke, and focus with it.
    private var searchControl: some View {
        HStack(spacing: 6) {
            Button(action: openSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: isSearching ? 15 : 17, weight: .medium))
                    .foregroundStyle(isSearching ? .secondary : .primary)
                    .frame(width: isSearching ? 30 : 36, height: isSearching ? 30 : 36)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Search (⌘F, or just start typing)")

            TextField("Search clipboard", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { pasteSelected() }
                .frame(width: isSearching ? PanelMetrics.searchWidth : 1)
                .opacity(isSearching ? 1 : 0)

            if isSearching {
                if query.isActive {
                    Text(String(localized: "\(visible.count) results"))
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Button(action: endSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("End search (Esc)")
            }
        }
        .padding(.leading, isSearching ? 4 : 0)
        .padding(.trailing, isSearching ? 10 : 0)
        .frame(height: 36)
        // The open field is a capsule, like the selected tab beside it.
        .background {
            if isSearching { Capsule().fill(.fill.tertiary) }
        }
    }

    /// Narrows the search to one kind: the thing a query cannot say, since an
    /// image has no text to type.
    private var kindMenu: some View { kindMenu(glass: false) }

    /// With `glass`, the label is a Liquid Glass capsule, as the new styles'
    /// other controls are. Applied to the label rather than as `.glass`: a
    /// `Menu` renders that button style fainter than a `Button` does.
    private func kindMenu(glass: Bool) -> some View {
        Menu {
            Button {
                kindFilter = nil
            } label: {
                Label("All Types", systemImage: "square.grid.2x2")
            }
            Divider()
            ForEach(ClipSearch.KindFilter.allCases) { kind in
                Button {
                    kindFilter = kind
                } label: {
                    Label(kind.title, systemImage: kind.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kindFilter?.symbol ?? "line.3.horizontal.decrease")
                Text(kindFilter?.title ?? String(localized: "All"))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: glass ? PanelType.caption : 12.5, weight: .medium))
            .foregroundStyle(kindFilter == nil
                             ? AnyShapeStyle(glass ? .primary : .secondary)
                             : AnyShapeStyle(.white))
            .padding(.horizontal, glass ? 14 : 10)
            .frame(height: glass ? 34 : 26)
            .background {
                if !glass {
                    Capsule().fill(kindFilter == nil
                                   ? AnyShapeStyle(.fill.tertiary)
                                   : AnyShapeStyle(Color.accentColor))
                }
            }
            .glassEffect(glass
                         ? (kindFilter == nil ? Glass.regular : Glass.regular.tint(PanelPalette.accent)).interactive()
                         : Glass.identity,
                         in: .capsule)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by type")
    }

    private func openSearch() {
        searchOpen = true
        searchFocused = true
    }

    /// Clears the query and the filter and closes the field. Focus stays in
    /// the field, so typing again starts a new search.
    private func endSearch() {
        search = ""
        kindFilter = nil
        searchOpen = false
        searchFocused = true
    }

    private var moreMenu: some View {
        MoreMenu(model: rowModel,
                 onPastePlain: { onPaste($0, true) },
                 onPin: pinSelected,
                 onDelete: deleteSelected)
    }

    // MARK: Attention

    private var needsAttention: Bool {
        permissions.hotKeyConflict != nil
            || permissions.needsPasteboardAttention
            || !permissions.canPasteDirectly
    }

    /// A problem that needs the user, as the first card in the row — where the
    /// eye lands first — rather than as a banner that pushes the row down.
    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
                .padding(.bottom, 4)
            Text(attentionTitle)
                .font(.system(size: 16, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(attentionDetail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            attentionButton
                .controlSize(.small)
        }
        .padding(16)
        .frame(width: PanelMetrics.cardSide, height: PanelMetrics.cardSide, alignment: .topLeading)
        .background(.fill.tertiary,
                    in: .rect(cornerRadius: PanelMetrics.cardRadius, style: .continuous))
    }

    private var attentionButton: some View {
        attentionAction
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
    }

    private var attentionAction: some View {
        Group {
            if permissions.hotKeyConflict != nil {
                // A taken shortcut is fixed in this app's own settings, not
                // in System Settings, so it gets a different destination.
                SettingsLink { Text("Change Shortcut") }
            } else {
                Button("Open Settings") {
                    if permissions.needsPasteboardAttention {
                        permissions.openPasteboardSettings()
                    } else {
                        permissions.openAccessibilitySettings()
                    }
                }
            }
        }
    }

    private var rowActions: RowActions {
        RowActions(paste: onPaste, togglePin: togglePin, delete: delete)
    }

    private var attentionTitle: String {
        if permissions.needsPasteboardAttention { String(localized: "Allow clipboard access") }
        else if let taken = permissions.hotKeyConflict { "\(taken) is already taken" }
        else { String(localized: "Allow accessibility access") }
    }

    private var attentionDetail: String {
        if permissions.needsPasteboardAttention {
            "macOS asks before an app may read the clipboard. Set this app to Allow to keep saving copies."
        } else if permissions.hotKeyConflict != nil {
            String(localized: "Another app claimed it first. Pick a different shortcut, or click the Dock icon.")
        } else {
            String(localized: "Needed to paste directly. Without it, clicking a card copies and you press ⌘V.")
        }
    }

    // MARK: Row

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: emptySymbol)
                .font(.system(size: 30))
            Text(emptyMessage).font(.body)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySymbol: String {
        if query.isActive { return "magnifyingglass" }
        return tab == .pinned ? "pin" : "doc.on.clipboard"
    }

    private var emptyMessage: String {
        if query.isActive { return String(localized: "No matches") }
        return tab == .pinned ? String(localized: "Nothing pinned yet — press ⌘P on a card") : String(localized: "Nothing copied yet")
    }

    /// A card and its ring tall, with the row's own gap beneath it to the
    /// panel's bottom edge.
    private var row: some View {
        VStack(spacing: 0) {
            ClipRow(sections: rowSections,
                    showsAttention: needsAttention,
                    attention: AnyView(attentionCard.padding(ClipRow.ringRoom)),
                    model: rowModel,
                    presentation: presentation,
                    layout: .basic,
                    cell: { [rowModel, presentation, rowActions] clip in
                        AnyView(RowCard(clip: clip, model: rowModel,
                                        presentation: presentation, actions: rowActions))
                    })
                .frame(height: ClipRow.height)
                // The slot's own room above the card counts towards the gap.
                .padding(.top, PanelMetrics.cardTopGap - ClipRow.ringRoom)
            Spacer(minLength: 0)
        }
    }

    /// One sentence describing a clipping, for VoiceOver.
    ///
    /// Ordered the way someone would ask for it — what it is, when, from where,
    /// then what is in it — rather than the order the card happens to draw.
    static func spokenDescription(of clip: ClipItem) -> String {
        var parts = [clip.kindLabel]
        parts.append(clip.copiedAt.formatted(.relative(presentation: .named)))
        if clip.isFromRemoteDevice {
            parts.append(String(localized: "from another device"))
        } else if let bundleID = clip.sourceBundleID,
                  let name = AppAccent.displayName(forBundleID: bundleID) {
            parts.append(String(localized: "from \(name)"))
        }
        if clip.isPinned { parts.append(String(localized: "pinned")) }
        if let preview = clip.previewText, !preview.isEmpty {
            // Truncated: VoiceOver reading several hundred characters of a
            // clipping before the user can move on is worse than a summary.
            parts.append(String(preview.prefix(120)))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0 === selection } ?? 0
        let next = min(max(current + delta, 0), list.count - 1)
        selection = list[next]
    }

    /// The selection, if it is still one of the visible cards.
    private var visibleSelection: ClipItem? {
        guard let selection, visible.contains(where: { $0 === selection }) else { return nil }
        return selection
    }

    /// No fallback to "the first item" on a stale selection. Pasting something
    /// the user did not choose into a real document is worse than doing nothing.
    private func pasteSelected() {
        guard let clip = visibleSelection else { return }
        onPaste(clip, false)
    }

    private func deleteSelected() {
        guard let clip = visibleSelection else { return }
        delete(clip)
    }

    private func togglePin(_ clip: ClipItem) {
        clip.isPinned.toggle()
        // Explicit for the same reason as `delete`: autosave timing is
        // unpredictable, and a pin the user set should not be pending at quit.
        try? modelContext.save()
        // Not a change to the history's membership, so the query does not
        // report it — but it moves the clipping in or out of Pinned.
        refreshVisible()
    }

    private func pinSelected() {
        guard let clip = visibleSelection else { return }
        togglePin(clip)
    }

    /// Moves the selection off the clipping first, if it is on it, to the one
    /// that takes its place — chosen before the delete, because afterwards
    /// `visible` has already shifted — and so that nothing is left holding a
    /// deleted model.
    private func delete(_ clip: ClipItem) {
        if selection === clip, let index = visible.firstIndex(where: { $0 === clip }) {
            let survivors = visible.filter { $0 !== clip }
            selection = survivors.indices.contains(index) ? survivors[index] : survivors.last
        }
        modelContext.delete(clip)
        // Explicit: SwiftData's autosave timing is unpredictable, and a delete
        // the user asked for should not be pending when the app quits.
        try? modelContext.save()
    }

    private func resetScroll() {
        selection = visible.first
        rowModel.scrollToStart?()
    }

    /// Builds a drag payload carrying every stored representation, registered
    /// lazily so a type is only decoded if a drop target asks for it.
    static func itemProvider(for clip: ClipItem) -> NSItemProvider {
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

// MARK: - Row card

/// A card as the row hosts it: the card, its selection, and what clicking,
/// dragging and right-clicking it do.
///
/// Reads the selection and the ⌘ state itself, from `RowModel` and
/// `PanelPresentation`, so a change to either redraws the cards on screen
/// rather than the panel.
///
/// A real `Button`, not an `onTapGesture`: the gesture made the panel's
/// primary action invisible to VoiceOver and Voice Control.
/// `.buttonStyle(.plain)` keeps the card looking like a card. Full Keyboard
/// Access cannot Tab onto it — its hosting view refuses focus so the search
/// field keeps it — and reaches the cards with the arrow keys instead.
struct RowCard: View {
    let clip: ClipItem
    let model: RowModel
    let presentation: PanelPresentation
    let actions: RowActions

    var body: some View {
        if clip.isGone {
            // Replaced as soon as the row catches up; see `ClipItem.isGone`.
            Color.clear
        } else {
            card
        }
    }

    private var card: some View {
        Button {
            model.selected = clip
            actions.paste(clip, false)
        } label: {
            // Every card on screen re-runs this body when the selection moves,
            // since each has to ask whether it is the one. `.equatable()` is
            // what keeps that cheap: only the two cards whose answer changed
            // go on to rebuild.
            CardFace(clip: clip,
                     isSelected: model.flags(for: clip).isSelected,
                     isKey: presentation.isKeyWindow,
                     quickPasteDigit: presentation.isCommandHeld ? model.quickPasteDigit(for: clip) : nil,
                     search: model.search)
                .equatable()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Pastes into the previous app")
        .onDrag { ClipboardPanelView.itemProvider(for: clip) }
        .contextMenu {
            Button("Paste") { actions.paste(clip, false) }
            Button("Paste as Plain Text") { actions.paste(clip, true) }
            Divider()
            Button(clip.isPinned ? String(localized: "Unpin") : String(localized: "Pin")) { actions.togglePin(clip) }
            Divider()
            Button("Delete", role: .destructive) { actions.delete(clip) }
        }
        .padding(ClipRow.ringRoom)
    }
}

/// A card and its spoken description, compared by what they show.
///
/// The description is here rather than on the button because it formats a
/// relative date, which is not free, and would otherwise be redone for every
/// card on screen on every arrow press.
private struct CardFace: View, Equatable {
    let clip: ClipItem
    let isSelected: Bool
    let isKey: Bool
    let quickPasteDigit: Int?
    let search: ClipSearch?

    /// The clipping by identity: its own properties are observed by
    /// `ClipCard`, which redraws itself when they change.
    static func == (lhs: CardFace, rhs: CardFace) -> Bool {
        lhs.clip === rhs.clip && lhs.isSelected == rhs.isSelected && lhs.isKey == rhs.isKey
            && lhs.quickPasteDigit == rhs.quickPasteDigit && lhs.search == rhs.search
    }

    var body: some View {
        if clip.isGone {
            Color.clear
        } else {
            ClipCard(clip: clip, isSelected: isSelected, isKey: isKey,
                     quickPasteDigit: quickPasteDigit, search: search)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ClipboardPanelView.spokenDescription(of: clip))
        }
    }
}

// MARK: - Card

/// A clipping as a square card: a band in the source app's colour carrying
/// the kind and the age, the app's icon
/// cropped into the band's trailing edge, the content on a plain surface below,
/// and a centred measurement with the quick-paste number at the foot.
private struct ClipCard: View {
    let clip: ClipItem
    let isSelected: Bool
    let isKey: Bool
    let quickPasteDigit: Int?
    /// The active search, for highlighting what matched.
    var search: ClipSearch? = nil

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
    }

    /// The source app's colour; with no source app, a colour for the kind, so
    /// the row never falls back to a wall of grey.
    private var bandColor: Color {
        AppAccent.color(forBundleID: clip.isFromRemoteDevice ? nil : clip.sourceBundleID)
            ?? Self.kindColor(clip.kind)
    }

    /// From the same palette as the app colours, so the row stays one family.
    private static func kindColor(_ kind: ClipKind) -> Color {
        let palette = AppAccent.palette
        switch kind {
        case .text: return palette[4]      // teal
        case .richText: return palette[7]  // purple
        case .link: return palette[5]      // blue
        case .image: return palette[8]     // pink
        case .fileURL: return palette[1]   // orange
        case .other: return Color(nsColor: .systemGray)
        }
    }

    /// White on the band unless the app's colour is too light to carry it —
    /// a yellow icon would otherwise put white text on yellow.
    private var bandForeground: Color {
        guard let rgb = NSColor(bandColor).usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.8 ? .black.opacity(0.85) : .white
    }

    private var ringColor: Color {
        isKey
            ? Color(nsColor: .controlAccentColor)
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    /// Whether there is a real picture to show — an image, or a file QuickLook
    /// could render.
    private var visualPreview: NSImage? {
        guard clip.kind == .image || clip.kind == .fileURL else { return nil }
        // Through the cache: decoding here looks free and is not, because this
        // is read on every pass of every card's body.
        return ThumbnailCache.image(fingerprint: clip.fingerprint,
                                    data: clip.thumbnailData)
    }

    var body: some View {
        // This view observes the clipping itself, so it can be asked to redraw
        // one last time after a delete; see `ClipItem.isGone`.
        if clip.isGone {
            Color.clear
        } else {
            face
        }
    }

    @ViewBuilder
    private var face: some View {
        let picture = visualPreview
        VStack(spacing: 0) {
            band
            ZStack(alignment: .bottom) {
                if let picture {
                    mediaBody(picture)
                } else {
                    preview
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, PanelMetrics.cardFooterHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                footer(onPicture: picture != nil)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: PanelMetrics.cardSide, height: PanelMetrics.cardSide)
        // `in: shape` rather than a bare fill followed by `.clipShape`: at the
        // scroll view's clip boundary a separately masked backing stops being
        // masked, and its square corners show.
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .clipShape(shape)
        // A soft shadow lifts the card off the glass; a stroke read as a drawn
        // edge. The item slot leaves room for it — see `ClipRow.ringRoom`.
        .shadow(color: .black.opacity(0.1),
                radius: PanelMetrics.cardShadowRadius, y: PanelMetrics.cardShadowY)
        .overlay {
            if isSelected {
                let ring = PanelMetrics.selectionRingWidth
                RoundedRectangle(cornerRadius: PanelMetrics.cardRadius + ring, style: .continuous)
                    .strokeBorder(ringColor, lineWidth: ring)
                    .padding(-ring)
            }
        }
    }

    // MARK: Band

    private var band: some View {
        // Negative: SF's line boxes leave the two lines 1 pt further apart
        // than they read well at this size.
        VStack(alignment: .leading, spacing: -1) {
            HStack(spacing: 5) {
                Text(clip.kindLabel)
                    .font(.system(size: 15, weight: .medium))
                if clip.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .help("Kept regardless of the history limit")
                }
            }
            Text(age)
                .font(.system(size: 12))
                .opacity(0.75)
        }
        .lineLimit(1)
        .foregroundStyle(bandForeground)
        .padding(.leading, 12)
        // Clear of the icon.
        .padding(.trailing, PanelMetrics.cardBandHeight + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PanelMetrics.cardBandHeight)
        // In a `Rectangle`, stated. The bare `.background(style)` form fills
        // the container shape — here the panel's rounded rect — so the band
        // came out with rounded *bottom* corners too, and the card's white
        // base showed through beneath them as two small white dots.
        .background(bandColor, in: Rectangle())
        .overlay(alignment: .topTrailing) { icon }
        .clipped()
    }

    @ViewBuilder
    private var icon: some View {
        if clip.isFromRemoteDevice {
            // Checked first: the frontmost app's icon would be a lie here.
            Image(systemName: "iphone.gen3")
                .font(.system(size: 24))
                .foregroundStyle(bandForeground.opacity(0.9))
                .frame(width: PanelMetrics.cardBandHeight, height: PanelMetrics.cardBandHeight)
        } else if let appIcon = AppAccent.icon(for: clip.sourceBundleID) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: PanelMetrics.cardIconSide, height: PanelMetrics.cardIconSide)
                .offset(x: PanelMetrics.cardIconOffset, y: -PanelMetrics.cardIconOffset)
        } else {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 21))
                .foregroundStyle(bandForeground.opacity(0.9))
                .frame(width: PanelMetrics.cardBandHeight, height: PanelMetrics.cardBandHeight)
        }
    }

    /// "now", "4 minutes ago", "yesterday".
    private var age: String {
        if Date().timeIntervalSince(clip.copiedAt) < 60 { return String(localized: "now") }
        return clip.copiedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    // MARK: Content

    @ViewBuilder
    private var preview: some View {
        switch clip.kind {
        case .link: linkPreview
        case .image: placeholder("photo")
        case .fileURL: filePreview
        case .text, .richText: textPreview
        case .other: placeholder("questionmark.square.dashed")
        }
    }

    /// No line limit: the frame decides how many lines fit, and the last one
    /// gets the ellipsis.
    private var textPreview: some View {
        Text(highlighted(clip.previewText ?? ""))
            .font(clip.prefersMonospacedPreview
                  ? .system(size: 13, design: .monospaced)
                  : .system(size: 13))
            // No extra spacing: 13 pt already lands on a 16 pt line pitch.
            .lineSpacing(clip.prefersMonospacedPreview ? 2 : 0)
            .multilineTextAlignment(.leading)
    }

    /// The text with every match marked, starting near the first one if it
    /// would otherwise fall below the card's last visible line.
    private func highlighted(_ text: String) -> AttributedString {
        guard let search else { return AttributedString(text) }
        let shown = search.snippet(of: text)
        var result = AttributedString()
        var cursor = shown.startIndex
        for range in search.ranges(in: shown) {
            result += AttributedString(shown[cursor ..< range.lowerBound])
            var match = AttributedString(shown[range])
            match.backgroundColor = Color.yellow.opacity(0.45)
            match.inlinePresentationIntent = .stronglyEmphasized
            result += match
            cursor = range.upperBound
        }
        result += AttributedString(shown[cursor...])
        return result
    }

    /// Host prominent, path quiet. What is useful about a URL is where it
    /// points, and the path is what tells two links to the same site apart.
    private var linkPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(clip.linkURL?.host ?? clip.previewText ?? "")
                .font(.system(size: 15, weight: .medium))
                .lineLimit(2)
            if let path = clip.linkURL?.path, path.count > 1 {
                Text(path)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Only reached when QuickLook could not preview the file. The type icon
    /// and the name are then all there is to show.
    private var filePreview: some View {
        VStack(spacing: 8) {
            Image(nsImage: fileIcon)
                .resizable()
                .frame(width: 56, height: 56)
            Text(fileName ?? String(localized: "File"))
                .font(.system(size: 13.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The picture edge to edge, as a photo is best shown — unless it is so far
    /// from square that filling would crop away what it is (a wide screenshot
    /// becomes a sliver of its middle), in which case it is fitted over a
    /// flat grey instead. Not a checkerboard: most such pictures are opaque
    /// white-backed screenshots, and over grey-and-white squares their edges
    /// vanish.
    ///
    /// Sized by the empty `Color` it hangs off, not by the image: a picture that
    /// sizes itself grows the card past its neighbours.
    private func mediaBody(_ image: NSImage) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let fills = (0.6 ... 1.7).contains(aspect)
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if !fills { Rectangle().fill(.quaternary) }
            }
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fills ? .fill : .fit)
            }
            .clipped()
    }

    // MARK: Footer

    /// The measurement centred, the quick-paste number at the trailing edge.
    private func footer(onPicture: Bool) -> some View {
        ZStack {
            if let caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(onPicture ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, onPicture ? 8 : 0)
                    .padding(.vertical, onPicture ? 3 : 0)
                    // Over a picture the caption needs something to sit on:
                    // a dark pill, which reads on any photo.
                    .background {
                        if onPicture {
                            Capsule().fill(.black.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 24)
            }
            if let quickPasteDigit {
                Text("⌘\(quickPasteDigit)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(onPicture ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        // Raises the caption 1.5 pt off centre, clear of the card's
        // rounded bottom corners.
        .padding(.bottom, 3)
        .frame(height: PanelMetrics.cardFooterHeight)
        .background {
            // Text runs to the bottom of the card; the footer covers it rather
            // than overlapping it.
            if !onPicture {
                Color(nsColor: .controlBackgroundColor)
            }
        }
    }

    /// Dimensions for a picture, the name for any other file, the size for
    /// everything else.
    private var caption: String? {
        if let size = imageSize { return "\(Int(size.width)) × \(Int(size.height))" }
        if clip.kind == .fileURL, let name = fileName { return name }
        return clip.lengthSummary
    }

    /// Through the cache: this is read in `body`. A copied image file is read
    /// from disk; an image on the clipboard itself comes out of the payload,
    /// which is faulted once per clipping and never again.
    private var imageSize: CGSize? {
        guard clip.kind == .image || clip.isImageFile else { return nil }
        return ThumbnailCache.imageSize(fingerprint: clip.fingerprint) {
            if let url = clip.fileURL {
                return CGImageSourceCreateWithURL(url as CFURL, nil)
            }
            guard let data = clip.representations
                .first(where: { ClipboardMonitor.isImageType($0.typeIdentifier) })?.data
            else { return nil }
            return CGImageSourceCreateWithData(data as CFData, nil)
        }
    }

    // MARK: Derived

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

// MARK: - Styles other than basic

extension ClipboardPanelView {
    /// The panel of every style but basic: placed in its window, backed by
    /// glass, and moved in and out the way the style moves.
    @ViewBuilder
    fileprivate var styledPanel: some View {
        let style = presentation.style
        let shown = presentation.isVisible
        let reduce = PanelMetrics.reduceMotion
        placed(style, panel: styledSurface(style))
            .scaleEffect(shown || reduce ? 1 : style.hiddenScale,
                         anchor: style == .topDrop ? .top : .center)
            .offset(shown || reduce
                    ? .zero
                    : style.hiddenOffset(windowSize: CGSize(width: 0, height: LightStripMetrics.windowHeight)))
            .opacity(shown ? 1 : (reduce || style.fadesWhileMoving ? 0 : 1))
    }

    /// Where the panel sits in its window. The window is sized to the panel
    /// plus clear room for its shadow; see `PanelStyle.windowFrame(on:)`.
    @ViewBuilder
    private func placed(_ style: PanelStyle, panel: some View) -> some View {
        let margin = PanelStyle.shadowMargin
        switch style {
        case .lightStrip:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                panel
                    .frame(height: LightStripMetrics.panelHeight)
                    .overlay(alignment: .topLeading) {
                        stripSearch
                            .offset(x: LightStripMetrics.rowInset, y: -50)
                    }
            }
            .padding([.horizontal, .bottom], PanelStyle.edgeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .sidebar:
            panel
                .frame(width: SidebarMetrics.width)
                .frame(maxHeight: .infinity)
                .padding(.leading, margin)
                .padding(.vertical, margin)
                .padding(.trailing, PanelStyle.edgeInset)
        case .basic, .minimal, .topDrop, .grid, .palette:
            panel
                .frame(width: style.panelSize.width, height: style.panelSize.height)
                .padding(margin)
        }
    }

    private func styledSurface(_ style: PanelStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        return styledContent(style)
            .clipShape(shape)
            .background {
                ZStack {
                    if style.isFloating {
                        // Glass casts no shadow of its own; a faint fill
                        // beneath it does.
                        shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.3))
                            .shadow(color: .black.opacity(0.22), radius: 22, y: 16)
                            .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                    }
                    Color.clear
                        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)),
                                     in: shape)
                }
            }
            .containerShape(shape)
    }

    @ViewBuilder
    private func styledContent(_ style: PanelStyle) -> some View {
        switch style {
        case .minimal:
            VStack(spacing: 0) {
                queryLine
                listOrEmpty(.minimal, headings: false)
            }
        case .topDrop:
            VStack(spacing: 0) {
                queryLine
                listOrEmpty(.topDrop, headings: false)
            }
        case .sidebar:
            VStack(spacing: 0) {
                queryLine
                listOrEmpty(.sidebar, headings: true)
            }
        case .grid:
            VStack(spacing: 0) {
                queryLine
                withEmptyState(
                    ClipRow(sections: rowSections, showsAttention: needsAttention,
                            attention: AnyView(attentionItem(compact: false)),
                            model: rowModel, presentation: presentation,
                            layout: .grid(tile: GridMetrics.tile, gap: GridMetrics.gap,
                                          padding: GridMetrics.padding),
                            cell: tileCell(size: CGSize(width: GridMetrics.tile, height: GridMetrics.tile),
                                           padding: GridMetrics.tilePadding,
                                           radius: GridMetrics.tileRadius, lines: 5))
                )
            }
        case .lightStrip:
            withEmptyState(
                ClipRow(sections: rowSections, showsAttention: needsAttention,
                        attention: AnyView(attentionItem(compact: false)),
                        model: rowModel, presentation: presentation,
                        layout: .strip(item: LightStripMetrics.tile, gap: LightStripMetrics.tileGap,
                                       inset: LightStripMetrics.rowInset),
                        cell: tileCell(size: LightStripMetrics.tile,
                                       padding: LightStripMetrics.tilePadding,
                                       radius: LightStripMetrics.tileRadius, lines: 4))
                    .frame(height: LightStripMetrics.tile.height)
                    .padding(.vertical, LightStripMetrics.verticalPadding)
            )
        case .palette:
            paletteContent
        case .basic:
            EmptyView()
        }
    }

    // MARK: Lists and tiles

    /// The list with the empty state laid over it when there is nothing to
    /// show — over it rather than instead of it. Swapping the list's view out
    /// and back as a search narrows to nothing took the keyboard from the
    /// search field, so the rest of what was typed went nowhere.
    private func withEmptyState(_ list: some View) -> some View {
        let isEmpty = visible.isEmpty && !needsAttention
        return ZStack {
            list.opacity(isEmpty ? 0 : 1)
            if isEmpty { emptyState }
        }
    }

    private func listOrEmpty(_ metrics: ListMetrics, headings: Bool) -> some View {
        withEmptyState(
            ClipRow(sections: rowSections, showsAttention: needsAttention,
                    attention: AnyView(attentionItem(compact: true)),
                    model: rowModel, presentation: presentation,
                    layout: .list(metrics),
                    cell: { [rowModel, presentation, rowActions] clip in
                        AnyView(ClipCell(clip: clip, model: rowModel, presentation: presentation,
                                         actions: rowActions,
                                         selectsBeforePasting: presentation.style == .palette) { state, onPin in
                            ListRowFace(clip: clip, state: state, metrics: metrics, onPin: onPin)
                        })
                    },
                    header: { section in
                        AnyView(SectionHeading(section: section, emphasised: presentation.style == .palette))
                    },
                    hasPicture: { clip in
                        (clip.kind == .image || clip.isImageFile) && clip.thumbnailData != nil
                    })
        )
    }

    private func tileCell(size: CGSize, padding: CGFloat, radius: CGFloat,
                          lines: Int) -> (ClipItem) -> AnyView {
        { [rowModel, presentation, rowActions] clip in
            AnyView(ClipCell(clip: clip, model: rowModel, presentation: presentation,
                             actions: rowActions) { state, onPin in
                TileFace(clip: clip, state: state, size: size, padding: padding,
                         radius: radius, textLines: lines, onPin: onPin)
            })
        }
    }

    private func attentionItem(compact: Bool) -> some View {
        AttentionItem(title: attentionTitle, detail: attentionDetail,
                      action: AnyView(attentionButton), compact: compact)
    }

    // MARK: Search

    /// The search bar across the top of the panel: the query, the kind
    /// filter, and the switch between everything and the pinned clippings.
    ///
    /// The field is always focused, so typing filters from the first
    /// keystroke without clicking into it.
    private var queryLine: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                searchField(placeholder: String(localized: "Search"), size: PanelType.search)
                searchAccessories
                styledTabs
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 56)
            Rectangle().fill(.separator).frame(height: 0.5)
        }
    }

    /// The light strip keeps its height for the tiles: its search bar floats
    /// above it, at the leading end.
    private var stripSearch: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            searchField(placeholder: String(localized: "Search"), size: PanelType.body)
                .frame(width: 260)
            searchAccessories
            styledTabs
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 44)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)), in: .capsule)
    }

    /// Everything, or only what is pinned.
    private var styledTabs: some View {
        GlassTabs(selection: $tab, glass: true, items: [
            .init(.clipboard, String(localized: "All")) {
                Image(systemName: "clock.arrow.circlepath")
            },
            .init(.pinned, pinnedCount > 0 ? String(localized: "Pinned \(pinnedCount)") : String(localized: "Pinned")) {
                Image(systemName: "pin.fill")
            },
        ])
    }

    private func searchField(placeholder: String, size: CGFloat) -> some View {
        TextField(placeholder, text: $search)
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .focused($searchFocused)
            .onSubmit { pasteSelected() }
    }

    @ViewBuilder
    private var searchAccessories: some View {
        if query.isActive {
            Text(String(localized: "\(visible.count) results"))
                .font(.system(size: PanelType.caption).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        if query.isActive {
            Button(action: endSearch) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear search (Esc)")
        }
        kindMenu(glass: true)
    }

    // MARK: Palette

    private var paletteContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.secondary)
                searchField(placeholder: String(localized: "Search \(clips.count) clippings…"), size: 21)
                if query.isActive {
                    Text(String(localized: "\(visible.count) results"))
                        .font(.system(size: PanelType.caption).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                kindMenu(glass: true)
                styledTabs
            }
            .padding(.leading, 26)
            .padding(.trailing, 16)
            .frame(height: 76)
            Rectangle().fill(.separator).frame(height: 0.5)
            HStack(spacing: 0) {
                listOrEmpty(.palette, headings: true)
                    .frame(width: 440)
                Rectangle().fill(.separator).frame(width: 0.5)
                PalettePreview(model: rowModel, presentation: presentation, actions: rowActions)
            }
            Rectangle().fill(.separator).frame(height: 0.5)
            PaletteFooter(total: clips.count, pinned: pinnedCount)
        }
    }
}

/// Tabs whose selection is one piece of Liquid Glass. Only the chosen tab
/// carries glass; the others are bare labels. The glass has one identity, so
/// choosing another tab moves it there — it stretches across and settles,
/// rather than two buttons swapping looks.
///
/// `tinted` gives the glass the accent colour, for the bars of the styled
/// panels; clear glass suits the basic style's quieter header.
private struct GlassTabs<Value: Hashable & Sendable>: View {
    struct Item {
        let value: Value
        let title: String
        let icon: AnyView

        init(_ value: Value, _ title: String, @ViewBuilder icon: () -> some View) {
            self.value = value
            self.title = title
            self.icon = AnyView(icon())
        }
    }

    @Binding var selection: Value
    /// Tinted Liquid Glass under the selected tab, or a plain grey capsule
    /// for a header that has no glass on it.
    let glass: Bool
    let items: [Item]
    @Namespace private var namespace

    var body: some View {
        Group {
            if glass {
                // Wide enough that the glass, mid-move, still touches both
                // tabs and reads as one stretching drop rather than a fade.
                GlassEffectContainer(spacing: 24) { tabs }
            } else {
                tabs
            }
        }
        .fixedSize()
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.value) { item in
                tab(item, isSelected: item.value == selection)
            }
        }
    }

    @ViewBuilder
    private func tab(_ item: Item, isSelected: Bool) -> some View {
        let label = Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { selection = item.value }
        } label: {
            HStack(spacing: 6) {
                item.icon
                Text(item.title).monospacedDigit()
            }
            .font(.system(size: PanelType.caption, weight: .medium))
            .foregroundStyle(isSelected
                             ? (glass ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                             : AnyShapeStyle(.secondary))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if isSelected, glass {
            label
                .glassEffect(Glass.regular.tint(PanelPalette.accent).interactive(), in: .capsule)
                .glassEffectID("selected", in: namespace)
        } else if isSelected {
            label
                .background {
                    Capsule().fill(.fill.tertiary)
                        .matchedGeometryEffect(id: "selected", in: namespace)
                }
        } else {
            label
        }
    }
}

// MARK: - Palette parts

/// The selected clipping at full size, beside the palette's list.
///
/// Its own view, reading the selection itself, so an arrow press redraws the
/// preview and two rows and nothing else. What it shows while the arrows move
/// is what is already in memory — the stored preview and thumbnail; the full
/// text or picture is read only once the selection has rested for 150 ms.
private struct PalettePreview: View {
    let model: RowModel
    let presentation: PanelPresentation
    let actions: RowActions

    @State private var fullText: String?
    @State private var fullImage: NSImage?
    /// The clipping on show: the selection, once it has been still for a
    /// moment. A held arrow key moves the selection thirty times a second,
    /// and laying out a preview for each of those was most of what the
    /// palette's arrows cost.
    @State private var shown: ClipItem?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let clip = shown, !clip.isGone {
                content(clip)
                    .task(id: clip.persistentModelID) {
                        fullText = nil
                        fullImage = nil
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled, !clip.isGone else { return }
                        load(clip)
                    }
            } else {
                empty
            }
        }
        .task(id: model.selected?.persistentModelID) {
            let selected = model.selected
            // At once when nothing is shown yet; otherwise after a pause.
            if shown != nil {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            shown = selected
        }
    }

    private var empty: some View {
        Group {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 34))
                Text("Nothing selected").font(.system(size: PanelType.body))
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load(_ clip: ClipItem) {
        if let url = clip.fileURL, clip.isImageFile {
            fullImage = NSImage(contentsOf: url)
            return
        }
        guard clip.kind == .text || clip.kind == .richText || clip.kind == .link else { return }
        let plain = NSPasteboard.PasteboardType.string.rawValue
        if let data = clip.representations.first(where: { $0.typeIdentifier == plain })?.data,
           let text = String(data: data, encoding: .utf8) {
            // Capped: a preview has no use for a whole log file, and laying
            // one out would stall.
            fullText = String(text.prefix(20_000))
        }
    }

    private func content(_ clip: ClipItem) -> some View {
        let visual = ClipVisual(clip)
        return VStack(alignment: .leading, spacing: 16) {
            header(clip)
            previewBody(clip, visual)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(PanelPalette.inset(scheme), in: .rect(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(PanelPalette.hairline(scheme), lineWidth: 0.5)
                }
            meta(clip)
            buttons(clip)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    private func header(_ clip: ClipItem) -> some View {
        HStack(spacing: 12) {
            AppBadge(clip: clip, side: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.isFromRemoteDevice
                     ? String(localized: "Another device")
                     : AppAccent.displayName(forBundleID: clip.sourceBundleID) ?? String(localized: "Unknown app"))
                    .font(.system(size: PanelType.body, weight: .semibold))
                Text("\(clip.kindLabel) · copied \(clip.copiedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: PanelType.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                actions.togglePin(clip)
            } label: {
                Label(clip.isPinned ? String(localized: "Unpin") : String(localized: "Pin"), systemImage: clip.isPinned ? "pin.fill" : "pin")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.extraLarge)
            .tint(clip.isPinned ? PanelPalette.accent : nil)
            .help(clip.isPinned ? String(localized: "Unpin (⌘P)") : String(localized: "Pin (⌘P)"))
        }
    }

    @ViewBuilder
    private func previewBody(_ clip: ClipItem, _ visual: ClipVisual) -> some View {
        switch visual {
        case .picture(let thumbnail, _, _):
            Image(nsImage: fullImage ?? thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        case .colour(let colour, let hex):
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colour)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(hex).font(.system(size: 18, weight: .medium, design: .monospaced))
            }
            .padding(18)
        case .file(let icon, let name, let size):
            VStack(spacing: 10) {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                Text(name).font(.system(size: PanelType.body, weight: .medium))
                if let size { Text(size).font(.system(size: PanelType.caption)).foregroundStyle(.secondary) }
                if let path = clip.fileURL?.deletingLastPathComponent().path {
                    Text(path)
                        .font(.system(size: PanelType.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(18)
        case .link(let host, _):
            VStack(alignment: .leading, spacing: 8) {
                Text(host).font(.system(size: 18, weight: .semibold))
                Text(fullText ?? clip.previewText ?? "")
                    .font(.system(size: PanelType.body))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        case .text(let text, let monospaced):
            ScrollView {
                Text(fullText ?? text)
                    .font(monospaced
                          ? .system(size: PanelType.mono, design: .monospaced)
                          : .system(size: PanelType.body))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            }
            .scrollIndicators(.never)
        }
    }

    private func meta(_ clip: ClipItem) -> some View {
        HStack(spacing: 20) {
            if let size = clip.lengthSummary { metaItem("Size", size) }
            if let text = fullText ?? clip.previewText,
               clip.kind == .text || clip.kind == .richText {
                metaItem("Lines", "\(text.split(separator: "\n", omittingEmptySubsequences: false).count)")
            }
            metaItem("Copied", clip.copiedAt.formatted(date: .abbreviated, time: .shortened))
            Spacer()
        }
    }

    private func metaItem(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.system(size: PanelType.caption))
    }

    /// Liquid Glass throughout: the paste as the one prominent, tinted
    /// button, the rest as clear glass beside it. Sizes come from the control
    /// size, not from numbers written here.
    private func buttons(_ clip: ClipItem) -> some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                Button {
                    actions.paste(clip, false)
                } label: {
                    HStack(spacing: 8) {
                        Text(presentation.targetAppName.map { String(localized: "Paste into \($0)") } ?? String(localized: "Paste"))
                        Image(systemName: "return")
                    }
                    .font(.system(size: PanelType.body, weight: .semibold))
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(PanelPalette.accent)
                secondaryButton(String(localized: "Plain text"), keys: "⇧↩") { actions.paste(clip, true) }
                secondaryButton(clip.isPinned ? String(localized: "Unpin") : String(localized: "Pin"), keys: "⌘P") { actions.togglePin(clip) }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.extraLarge)
        }
    }

    private func secondaryButton(_ title: String, keys: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Text(keys).foregroundStyle(.secondary)
            }
            .font(.system(size: PanelType.body, weight: .medium))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
    }
}

/// The palette's foot: how much there is, and the keys.
private struct PaletteFooter: View {
    let total: Int
    let pinned: Int

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(PanelPalette.accent).frame(width: 7, height: 7)
                Text("\(total) clippings · \(pinned) pinned")
            }
            .foregroundStyle(.secondary)
            Spacer()
            hint("↩", "Paste")
            hint("⇧↩", "Plain text")
            hint("⌘1–9", "Quick")
            hint("⌘P", "Pin")
            hint("⌘⌫", "Delete")
        }
        .font(.system(size: PanelType.caption))
        .padding(.horizontal, 22)
        .frame(height: 48)
    }

    private func hint(_ keys: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(.fill.tertiary, in: .rect(cornerRadius: 5, style: .continuous))
            Text(label).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ClipboardPanelView()
        .frame(width: 1200, height: PanelMetrics.windowHeight)
        .modelContainer(for: [ClipItem.self, ClipPayload.self, ClipRepresentation.self],
                        inMemory: true)
}
