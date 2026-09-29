//
//  ClipRow.swift
//  paster
//

import AppKit
import SwiftData
import SwiftUI

/// What every card reads besides its own clipping, kept out of the panel's
/// root view so that changing it redraws the cards on screen and nothing else.
///
/// This is the difference between an arrow press costing a handful of cards
/// and costing the whole history: with the selection in the root view's state,
/// every press re-ran the root body, re-filtered every row and re-diffed every
/// card's identity — O(n) work per keystroke, measured at a 126 ms p99 frame
/// with 10,000 clippings.
@Observable
final class RowModel {
    /// Held as the object rather than its identifier, so the ⋯ menu can ask
    /// whether it is pinned without searching the history for it.
    ///
    /// Items never read this: see `flags(for:)`.
    var selected: ClipItem? {
        didSet {
            guard selected !== oldValue else { return }
            if let oldValue { cellFlags[oldValue.persistentModelID]?.isSelected = false }
            if let selected { cellFlags[selected.persistentModelID]?.isSelected = true }
            onSelectionChange?(selected)
        }
    }

    /// One small observable per item, so moving the selection tells exactly
    /// two items and no others. Were every item to read `selected`, every
    /// item on screen would re-run and re-lay itself out on each arrow press
    /// — measured at 126 frames over 25 ms in the grid, where twenty-five
    /// are on screen at once.
    @ObservationIgnored private var cellFlags: [PersistentIdentifier: CellFlags] = [:]

    func flags(for clip: ClipItem) -> CellFlags {
        let id = clip.persistentModelID
        if let existing = cellFlags[id] { return existing }
        let flags = CellFlags(isSelected: selected === clip)
        cellFlags[id] = flags
        return flags
    }

    /// The first nine visible clippings, which ⌘1–⌘9 count.
    var quickPasteOrder: [PersistentIdentifier] = []

    /// The active search, for highlighting what matched.
    var search: ClipSearch?

    /// Set by the row, which owns the scroll position.
    @ObservationIgnored var onSelectionChange: ((ClipItem?) -> Void)?
    @ObservationIgnored var scrollToStart: (() -> Void)?

    func quickPasteDigit(for clip: ClipItem) -> Int? {
        quickPasteOrder.firstIndex(of: clip.persistentModelID).map { $0 + 1 }
    }
}

extension ClipItem {
    /// Deleted — or deleted and saved, which detaches it from its context.
    ///
    /// A card holds its clipping, and a deleted clipping's observers fire
    /// before the row's list catches up, so the card redraws once more with
    /// it. Reading any stored property then traps inside SwiftData; this is
    /// the one question that is still safe to ask.
    var isGone: Bool { isDeleted || modelContext == nil }
}

/// An item's own share of the selection.
@Observable
final class CellFlags {
    var isSelected: Bool

    init(isSelected: Bool) {
        self.isSelected = isSelected
    }
}

/// What a card can ask the panel to do.
struct RowActions {
    var paste: (ClipItem, Bool) -> Void
    var togglePin: (ClipItem) -> Void
    var delete: (ClipItem) -> Void
}

/// A run of clippings under an optional heading: a day in the sidebar, or
/// Pinned / Today in the palette. Styles without headings use one section.
struct RowSection {
    var id: String
    var title: String?
    var count: Int?
    var clips: [ClipItem]
}

/// The shape of the list.
enum RowLayout {
    /// One row that scrolls sideways.
    case strip(item: CGSize, gap: CGFloat, inset: CGFloat)
    /// A column that scrolls down, optionally with section headings.
    case list(ListMetrics)
    /// Fixed square tiles in rows that scroll down.
    case grid(tile: CGFloat, gap: CGFloat, padding: CGFloat)

    /// The basic style's row, whose items carry room for the ring drawn
    /// outside each card.
    static var basic: RowLayout {
        .strip(item: CGSize(width: ClipRow.itemSide, height: ClipRow.itemSide),
               gap: PanelMetrics.cardGap - ClipRow.ringRoom * 2,
               inset: PanelMetrics.rowInset - ClipRow.ringRoom)
    }

    var isHorizontal: Bool {
        if case .strip = self { return true }
        return false
    }
}

/// The history as an `NSCollectionView`, in whichever shape the style wants.
///
/// Rather than a SwiftUI `LazyHStack`, which creates each card as it scrolls
/// into view but keeps every one it has created, and whose `ForEach` diffs the
/// identity of every row on each update. Here only the items on screen exist:
/// a few dozen hosting views, reused as the list scrolls, whatever the
/// history's size. The items themselves are SwiftUI, built by `cell`.
struct ClipRow: NSViewRepresentable {
    var sections: [RowSection]
    var showsAttention: Bool
    var attention: AnyView
    var model: RowModel
    var presentation: PanelPresentation
    var layout: RowLayout = .basic
    /// Builds an item's view. Called when an item scrolls into view or is
    /// reused, never for items off screen.
    var cell: (ClipItem) -> AnyView
    var header: (RowSection) -> AnyView = { _ in AnyView(EmptyView()) }
    /// Whether a list row needs the taller, picture-carrying height.
    var hasPicture: (ClipItem) -> Bool = { _ in false }

    /// Room for the selection ring, which is drawn outside the card.
    static var ringRoom: CGFloat { PanelMetrics.selectionRingWidth + 1 }
    static var itemSide: CGFloat { PanelMetrics.cardSide + ringRoom * 2 }
    /// The row's height: a card and its ring.
    static var height: CGFloat { itemSide }

    func makeCoordinator() -> Coordinator { Coordinator(layout: layout) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    /// Whatever it is offered. Left to itself SwiftUI asks the scroll view
    /// for its fitting size, which runs AppKit's layout of the whole list —
    /// on every pass of the panel's layout, measured as most of an arrow
    /// press's cost in the vertical styles.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: proposal.height ?? 100)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.presentation = presentation
        coordinator.attention = attention
        coordinator.cell = cell
        coordinator.header = header
        coordinator.hasPicture = hasPicture
        coordinator.bind(model)
        coordinator.apply(sections: sections, showsAttention: showsAttention)
    }

    enum Item: Hashable {
        case attention
        case clip(PersistentIdentifier)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout {
        let layout: RowLayout
        var presentation: PanelPresentation?
        var attention = AnyView(EmptyView())
        var cell: (ClipItem) -> AnyView = { _ in AnyView(EmptyView()) }
        var header: (RowSection) -> AnyView = { _ in AnyView(EmptyView()) }
        var hasPicture: (ClipItem) -> Bool = { _ in false }

        private var model: RowModel?
        private weak var scrollView: NSScrollView?
        private weak var collectionView: NSCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<String, Item>?

        private var clipsByID: [PersistentIdentifier: ClipItem] = [:]
        private var indexPathByID: [PersistentIdentifier: IndexPath] = [:]
        private var sectionsByID: [String: RowSection] = [:]
        private var sectionOrder: [String] = []
        private var lastSections: [RowSection] = []
        private var lastShowsAttention = false
        private var firstClipID: PersistentIdentifier?
        private var lastReveal: CFTimeInterval = 0

        private static let attentionSection = "_attention"

        init(layout: RowLayout) {
            self.layout = layout
        }

        func makeScrollView() -> NSScrollView {
            let flow = NSCollectionViewFlowLayout()
            switch layout {
            case .strip(let item, let gap, let inset):
                flow.scrollDirection = .horizontal
                flow.itemSize = item
                // Between columns, in a horizontal flow.
                flow.minimumLineSpacing = gap
                // Between items in one column; large enough that there is only one.
                flow.minimumInteritemSpacing = 10_000
                flow.sectionInset = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            case .list(let metrics):
                flow.scrollDirection = .vertical
                flow.minimumLineSpacing = metrics.rowGap
                flow.minimumInteritemSpacing = 0
            case .grid(let tile, let gap, let padding):
                flow.scrollDirection = .vertical
                flow.itemSize = NSSize(width: tile, height: tile)
                flow.minimumLineSpacing = gap
                flow.minimumInteritemSpacing = gap
                flow.sectionInset = NSEdgeInsets(top: padding, left: padding,
                                                 bottom: padding, right: padding)
            }

            let collectionView = RowCollectionView()
            collectionView.collectionViewLayout = flow
            // The panel's own selection drives the highlight; the collection
            // view's would fight it, and its rubber-band selection would eat drags.
            collectionView.isSelectable = false
            collectionView.backgroundColors = [.clear]
            collectionView.delegate = self
            collectionView.register(CardItem.self, forItemWithIdentifier: CardItem.identifier)
            collectionView.register(HeaderView.self,
                                    forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                    withIdentifier: HeaderView.identifier)

            let dataSource = NSCollectionViewDiffableDataSource<String, Item>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, item in
                let cell = collectionView.makeItem(withIdentifier: CardItem.identifier, for: indexPath)
                guard let self, let card = cell as? CardItem else { return cell }
                card.show(self.content(for: item))
                return card
            }
            dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
                let view = collectionView.makeSupplementaryView(
                    ofKind: kind, withIdentifier: HeaderView.identifier, for: indexPath)
                let header = view as? HeaderView ?? HeaderView()
                if let self, self.sectionOrder.indices.contains(indexPath.section),
                   let section = self.sectionsByID[self.sectionOrder[indexPath.section]] {
                    header.show(self.header(section))
                }
                return header
            }
            self.dataSource = dataSource

            let scrollView = RowScrollView()
            scrollView.convertsVerticalWheel = layout.isHorizontal
            scrollView.documentView = collectionView
            scrollView.drawsBackground = false
            // Hidden: a scroller laid across the items covers what tells them
            // apart, and the list is self-evidently scrollable.
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.horizontalScrollElasticity = layout.isHorizontal ? .allowed : .none
            scrollView.verticalScrollElasticity = layout.isHorizontal ? .none : .allowed
            scrollView.automaticallyAdjustsContentInsets = false

            self.scrollView = scrollView
            self.collectionView = collectionView
            return scrollView
        }

        func bind(_ model: RowModel) {
            guard self.model !== model else { return }
            self.model = model
            // One runloop later: a selection set alongside a new list (a
            // search, a tab switch) arrives before the list does, and would be
            // placed by the old one's positions.
            model.onSelectionChange = { [weak self] clip in
                DispatchQueue.main.async { self?.reveal(clip) }
            }
            model.scrollToStart = { [weak self] in self?.scroll(to: 0, animated: false) }
        }

        /// Cheap when nothing changed, which is most calls: this runs on every
        /// pass of the panel's body, and comparing object identities is a
        /// pointer compare per row.
        func apply(sections: [RowSection], showsAttention: Bool) {
            let unchanged = showsAttention == lastShowsAttention
                && sections.count == lastSections.count
                && zip(sections, lastSections).allSatisfy { new, old in
                    new.id == old.id && new.title == old.title && new.count == old.count
                        && new.clips.elementsEqual(old.clips, by: ===)
                }
            guard !unchanged else { return }
            lastSections = sections
            lastShowsAttention = showsAttention

            var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
            clipsByID.removeAll(keepingCapacity: true)
            indexPathByID.removeAll(keepingCapacity: true)
            sectionsByID.removeAll(keepingCapacity: true)
            sectionOrder.removeAll(keepingCapacity: true)
            firstClipID = nil

            if showsAttention {
                snapshot.appendSections([Self.attentionSection])
                snapshot.appendItems([.attention], toSection: Self.attentionSection)
                sectionOrder.append(Self.attentionSection)
                sectionsByID[Self.attentionSection] = RowSection(id: Self.attentionSection, clips: [])
            }
            for section in sections {
                // A repeated identifier — an item in two sections, or two
                // sections with one name — would crash the snapshot. The store
                // cannot produce one, but a history view is no place to learn
                // otherwise.
                guard sectionsByID[section.id] == nil else { continue }
                var items: [Item] = []
                for clip in section.clips {
                    let id = clip.persistentModelID
                    guard clipsByID[id] == nil else { continue }
                    clipsByID[id] = clip
                    indexPathByID[id] = IndexPath(item: items.count, section: sectionOrder.count)
                    if firstClipID == nil { firstClipID = id }
                    items.append(.clip(id))
                }
                guard !items.isEmpty else { continue }
                snapshot.appendSections([section.id])
                snapshot.appendItems(items, toSection: section.id)
                sectionOrder.append(section.id)
                sectionsByID[section.id] = section
            }

            // Unanimated, as the SwiftUI row was: a new clipping arriving while
            // the panel is open should not set the whole list sliding.
            dataSource?.apply(snapshot, animatingDifferences: false)
            // Headers keep what they were built with; a changed count needs a
            // fresh one.
            collectionView?.collectionViewLayout?.invalidateLayout()

            // Every position just moved; put the selected item back in view.
            reveal(model?.selected, animated: false)
        }

        private func content(for item: Item) -> AnyView {
            switch item {
            case .attention:
                return attention
            case .clip(let id):
                guard let clip = clipsByID[id] else { return AnyView(EmptyView()) }
                // Keyed by the clipping, so view state such as a hover
                // highlight never carries over when the slot is reused for
                // another.
                return AnyView(cell(clip).id(id))
            }
        }

        // MARK: Flow layout

        private var listWidth: CGFloat {
            guard case .list(let metrics) = layout else { return 0 }
            let width = scrollView?.contentSize.width ?? collectionView?.bounds.width ?? 0
            return max(1, width - metrics.listPadding.left - metrics.listPadding.right)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            switch layout {
            case .strip(let item, _, _):
                return item
            case .grid(let tile, _, _):
                return NSSize(width: tile, height: tile)
            case .list(let metrics):
                var height = metrics.rowHeight
                if sectionOrder.indices.contains(indexPath.section),
                   let section = sectionsByID[sectionOrder[indexPath.section]],
                   section.clips.indices.contains(indexPath.item),
                   hasPicture(section.clips[indexPath.item]) {
                    height = metrics.pictureRowHeight
                }
                return NSSize(width: listWidth, height: height)
            }
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            insetForSectionAt section: Int) -> NSEdgeInsets {
            // Between two sections, one ordinary gap rather than an inset on
            // each side of it.
            let isFirst = section == 0
            let isLast = section == sectionOrder.count - 1
            switch layout {
            case .strip(_, let gap, let inset):
                return NSEdgeInsets(top: 0, left: isFirst ? inset : 0,
                                    bottom: 0, right: isLast ? inset : gap)
            case .grid(_, let gap, let padding):
                return NSEdgeInsets(top: isFirst ? padding : 0, left: padding,
                                    bottom: isLast ? padding : gap, right: padding)
            case .list(let metrics):
                let padding = metrics.listPadding
                return NSEdgeInsets(top: section == 0 ? padding.top : 0,
                                    left: padding.left,
                                    bottom: section == sectionOrder.count - 1 ? padding.bottom : metrics.rowGap,
                                    right: padding.right)
            }
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            referenceSizeForHeaderInSection section: Int) -> NSSize {
            guard case .list(let metrics) = layout, metrics.sectionHeaderHeight > 0,
                  sectionOrder.indices.contains(section),
                  sectionsByID[sectionOrder[section]]?.title != nil
            else { return .zero }
            return NSSize(width: listWidth, height: metrics.sectionHeaderHeight)
        }

        // MARK: Scrolling

        /// Brings the selected item into view — only as far as needed, so
        /// arrowing along does not re-centre on every step. The first item
        /// goes to the true start instead, so it always sits at the inset.
        ///
        /// Animated for a single press, immediate for a run of them: animations
        /// started every 30 ms by a held key stack up and stutter.
        private func reveal(_ clip: ClipItem?, animated: Bool? = nil) {
            guard let clip, presentation?.isVisible == true,
                  let indexPath = indexPathByID[clip.persistentModelID],
                  let collectionView, let clipView = scrollView?.contentView
            else { return }

            let animate: Bool
            if let animated {
                animate = animated
            } else {
                let now = CACurrentMediaTime()
                animate = now - lastReveal >= 0.25
                lastReveal = now
            }

            guard clip.persistentModelID != firstClipID else {
                scroll(to: 0, animated: animate)
                return
            }
            // The layout's own answer, which it computes on demand; laying
            // the view out first would redo every visible item.
            guard let frame = collectionView.collectionViewLayout?
                .layoutAttributesForItem(at: indexPath)?.frame
            else { return }

            let visible = clipView.bounds
            if layout.isHorizontal {
                guard case .strip(_, _, let inset) = layout else { return }
                // The item plus the row's margin on either side.
                let wanted = frame.insetBy(dx: -inset, dy: 0)
                var x = visible.minX
                if wanted.minX < visible.minX {
                    x = wanted.minX
                } else if wanted.maxX > visible.maxX {
                    x = wanted.maxX - visible.width
                }
                scroll(to: x, animated: animate)
            } else {
                var margin: CGFloat = 8
                if case .list(let metrics) = layout {
                    margin = metrics.listPadding.top
                    // Keep a section's heading with its first row.
                    if indexPath.item == 0 { margin += metrics.sectionHeaderHeight }
                } else if case .grid(_, _, let padding) = layout {
                    margin = padding
                }
                let wanted = frame.insetBy(dx: 0, dy: -margin)
                var y = visible.minY
                if wanted.minY < visible.minY {
                    y = wanted.minY
                } else if wanted.maxY > visible.maxY {
                    y = wanted.maxY - visible.height
                }
                scroll(to: y, animated: animate)
            }
        }

        /// `offset` is along the scrolling axis.
        private func scroll(to offset: CGFloat, animated: Bool) {
            guard let scrollView, let collectionView else { return }
            let clipView = scrollView.contentView
            let origin: NSPoint
            if layout.isHorizontal {
                let maxX = max(0, collectionView.frame.width - clipView.bounds.width)
                origin = NSPoint(x: min(max(0, offset), maxX), y: 0)
            } else {
                let maxY = max(0, collectionView.frame.height - clipView.bounds.height)
                origin = NSPoint(x: 0, y: min(max(0, offset), maxY))
            }
            guard origin != clipView.bounds.origin else { return }
            NSAnimationContext.runAnimationGroup { context in
                // Zero, not a plain set, when not animating: a plain set would
                // be overwritten by an animation still in flight.
                context.duration = animated && !PanelMetrics.reduceMotion ? 0.15 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clipView.animator().setBoundsOrigin(origin)
            }
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}

/// Never takes focus. The search field holds it permanently — that is what
/// lets typing filter from the first keystroke — and the arrow keys are the
/// panel's, not the collection view's.
private final class RowCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }

    /// A list's rows are as wide as the view; when it changes, so do they.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { collectionViewLayout?.invalidateLayout() }
    }
}

/// Scrollers pinned off, and a mouse wheel's vertical turn turned sideways for
/// a horizontal row.
private final class RowScrollView: NSScrollView {
    var convertsVerticalWheel = false

    /// Pinned off. `NSCollectionView` turns its scroll view's scrollers back
    /// on to suit its layout, whatever was set before.
    override var hasHorizontalScroller: Bool {
        get { false }
        set { }
    }

    override var hasVerticalScroller: Bool {
        get { false }
        set { }
    }

    /// A row has no vertical extent to use a mouse wheel on. Trackpad
    /// gestures, which already carry a horizontal component, pass through
    /// untouched.
    override func scrollWheel(with event: NSEvent) {
        guard convertsVerticalWheel,
              !event.hasPreciseScrollingDeltas,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let copy = event.cgEvent?.copy()
        else { return super.scrollWheel(with: event) }

        for (vertical, horizontal) in [
            (CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
        ] {
            copy.setIntegerValueField(horizontal, value: copy.getIntegerValueField(vertical))
            copy.setIntegerValueField(vertical, value: 0)
        }
        // Fixed-point, so read and written as a double.
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                 value: copy.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        super.scrollWheel(with: NSEvent(cgEvent: copy) ?? event)
    }
}

/// One reusable item slot: a hosting view whose root is swapped on reuse.
private final class CardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ClipRow.CardItem")

    private let host = CardHostingView(rootView: AnyView(EmptyView()))

    override func loadView() {
        // The collection view sizes the item; the SwiftUI content must not
        // push back with a size of its own.
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        view = host
    }

    func show(_ content: AnyView) {
        host.rootView = content
    }
}

/// A section heading slot, reused like the items.
private final class HeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("ClipRow.HeaderView")

    private let host = CardHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ content: AnyView) {
        host.rootView = content
    }
}

/// Refuses focus for the same reason `RowCollectionView` does: clicking an
/// item must not take it from the search field.
private final class CardHostingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { false }
}
