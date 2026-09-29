//
//  PanelStyle.swift
//  paster
//

import AppKit
import SwiftUI

/// How the panel looks and where it appears. Chosen in Settings; a change
/// takes effect the next time the panel opens, never while it is on screen.
///
/// Every style shows the same history, in the same order, with the same keys.
/// What differs is the shape of the list and where it sits.
enum PanelStyle: String, CaseIterable, Identifiable {
    /// Big square cards in a strip along the bottom of the screen.
    case basic
    /// A single-line list in a small floating panel.
    case minimal
    /// A short strip of small tiles along the bottom of the screen.
    case lightStrip
    /// A list dropping from the top centre, where Spotlight sits.
    case topDrop
    /// A full-height list sliding in from the right edge.
    case sidebar
    /// A grid of small square tiles in the middle of the screen.
    case grid
    /// A list beside a preview of the selection, with a search bar on top.
    case palette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: String(localized: "Basic")
        case .minimal: String(localized: "Minimal")
        case .lightStrip: String(localized: "Light Strip")
        case .topDrop: String(localized: "Top Drop")
        case .sidebar: String(localized: "Sidebar")
        case .grid: String(localized: "Grid")
        case .palette: String(localized: "Command Palette")
        }
    }

    var summary: String {
        switch self {
        case .basic: String(localized: "Large cards along the bottom of the screen")
        case .minimal: String(localized: "A one-line list in a small floating panel")
        case .lightStrip: String(localized: "Small tiles in a short strip along the bottom")
        case .topDrop: String(localized: "A list that drops from the top, like Spotlight")
        case .sidebar: String(localized: "A full-height list at the right edge, grouped by day")
        case .grid: String(localized: "Small square tiles in the middle of the screen")
        case .palette: String(localized: "A list beside a preview of the selection")
        }
    }

    /// Read from the launch arguments only, so a test run can pick a style
    /// without touching the user's setting: `-PanelStyle grid`.
    static var launchOverride: PanelStyle? {
        UserDefaults(suiteName: UserDefaults.argumentDomain)?
            .string(forKey: "PanelStyle")
            .flatMap(PanelStyle.init(rawValue:))
    }

    // MARK: Geometry

    /// Clear room around a floating panel for its shadow.
    static let shadowMargin: CGFloat = 40

    /// Gap between a docked panel and the screen edge it is docked to.
    static let edgeInset: CGFloat = 8

    /// The visible panel's size, for the styles whose size is fixed.
    var panelSize: CGSize {
        switch self {
        case .basic, .lightStrip, .sidebar: .zero      // derived from the screen
        case .minimal: CGSize(width: 500, height: 620)
        case .topDrop: CGSize(width: 680, height: 640)
        case .grid: CGSize(width: 830, height: 680)
        case .palette: CGSize(width: 1080, height: 760)
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .basic: PanelMetrics.cornerRadius
        case .minimal: 22
        case .lightStrip: 26
        case .topDrop, .grid: 26
        case .sidebar: 24
        case .palette: 30
        }
    }

    /// Floating styles cast a shadow and need clear room around them for it.
    var isFloating: Bool {
        switch self {
        case .basic, .lightStrip: false
        case .minimal, .topDrop, .sidebar, .grid, .palette: true
        }
    }

    /// The window's frame on `screen`. The panel sits inside it at
    /// `panelRect(inWindowOf:)`; the rest is transparent.
    func windowFrame(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let margin = Self.shadowMargin
        switch self {
        case .basic:
            return NSRect(x: frame.minX, y: frame.minY,
                          width: frame.width, height: PanelMetrics.windowHeight)
        case .lightStrip:
            return NSRect(x: frame.minX, y: frame.minY,
                          width: frame.width, height: LightStripMetrics.windowHeight)
        case .sidebar:
            // From just below the menu bar to the bottom of the screen: like
            // the strips, the panel goes over the Dock rather than above it.
            let top = visible.maxY - Self.edgeInset
            let bottom = frame.minY + Self.edgeInset
            return NSRect(x: frame.maxX - SidebarMetrics.width - Self.edgeInset - margin,
                          y: bottom - margin,
                          width: SidebarMetrics.width + Self.edgeInset + margin,
                          height: top - bottom + margin * 2)
        case .topDrop:
            let size = panelSize
            // Where Spotlight sits: centred, a seventh of the way down.
            let top = visible.maxY - frame.height * 0.08
            return NSRect(x: frame.midX - size.width / 2 - margin,
                          y: top - size.height - margin,
                          width: size.width + margin * 2,
                          height: size.height + margin * 2)
        case .minimal, .grid, .palette:
            let size = panelSize
            // Optically centred: a little above the true middle.
            let centreY = visible.midY + visible.height * 0.06
            return NSRect(x: frame.midX - size.width / 2 - margin,
                          y: centreY - size.height / 2 - margin,
                          width: size.width + margin * 2,
                          height: size.height + margin * 2)
        }
    }

    // MARK: Motion

    /// Where the panel waits while hidden, relative to where it is shown.
    func hiddenOffset(windowSize: CGSize) -> CGSize {
        switch self {
        case .basic, .lightStrip: CGSize(width: 0, height: windowSize.height)
        case .topDrop: CGSize(width: 0, height: -18)
        case .sidebar: CGSize(width: SidebarMetrics.width + Self.edgeInset + Self.shadowMargin, height: 0)
        case .minimal, .grid, .palette: .zero
        }
    }

    /// Floating panels grow in from slightly smaller rather than sliding.
    var hiddenScale: CGFloat {
        switch self {
        case .minimal, .grid, .palette: 0.96
        default: 1
        }
    }

    /// Whether the panel fades while it moves. The strips slide in fully
    /// opaque; the rest fade as they arrive.
    var fadesWhileMoving: Bool {
        switch self {
        case .basic, .lightStrip, .sidebar: false
        case .minimal, .topDrop, .grid, .palette: true
        }
    }

    var appearAnimation: Animation {
        if PanelMetrics.reduceMotion { return .easeOut(duration: 0.12) }
        switch self {
        case .basic, .lightStrip: return PanelMetrics.appearAnimation
        case .sidebar: return .spring(duration: 0.24, bounce: 0)
        case .topDrop: return .spring(duration: 0.22, bounce: 0)
        case .minimal, .grid, .palette: return .spring(duration: 0.2, bounce: 0)
        }
    }

    var dismissAnimation: Animation {
        if PanelMetrics.reduceMotion { return .easeOut(duration: 0.1) }
        switch self {
        case .basic, .lightStrip: return PanelMetrics.dismissAnimation
        case .sidebar: return .easeIn(duration: 0.18)
        case .topDrop, .minimal, .grid, .palette: return .easeIn(duration: 0.14)
        }
    }

    // MARK: Keys

    /// Which arrow keys walk the list.
    var arrowAxis: ArrowAxis {
        switch self {
        case .basic, .lightStrip: .horizontal
        case .minimal, .topDrop, .sidebar, .palette: .vertical
        case .grid: .both(columns: GridMetrics.columns)
        }
    }

    enum ArrowAxis {
        case horizontal
        case vertical
        case both(columns: Int)

        var isHorizontal: Bool {
            if case .horizontal = self { return true }
            return false
        }
    }
}

// MARK: - Per-style measurements
//
// Taken from the design files and brought onto the app's own type scale: SF
// throughout, 13 pt body, 12 pt captions, 12.5 pt monospaced.

enum PanelType {
    static let body: CGFloat = 15
    static let caption: CGFloat = 13
    static let mono: CGFloat = 14
    static let sectionLabel: CGFloat = 13
    /// A row's second line.
    static let meta: CGFloat = 13
    static let search: CGFloat = 17
}

enum LightStripMetrics {
    static let panelHeight: CGFloat = 230
    /// Room above the panel for the search capsule, which floats over it.
    static let searchRoom: CGFloat = 54
    static var windowHeight: CGFloat { panelHeight + PanelStyle.edgeInset + searchRoom }
    static let tile = CGSize(width: 210, height: 160)
    static let tileGap: CGFloat = 14
    static let tileRadius: CGFloat = 16
    static let tilePadding: CGFloat = 14
    static let rowInset: CGFloat = 18
    /// The panel's own top and bottom padding around the tiles.
    static var verticalPadding: CGFloat { (panelHeight - tile.height) / 2 }
}

enum SidebarMetrics {
    static let width: CGFloat = 440
}

enum GridMetrics {
    static let columns = 5
    static let tile: CGFloat = 150
    static let gap: CGFloat = 12
    static let padding: CGFloat = 16
    static let tileRadius: CGFloat = 16
    static let tilePadding: CGFloat = 12
}

/// The row shapes of the list styles.
struct ListMetrics {
    var rowHeight: CGFloat
    /// Rows carrying a picture are taller.
    var pictureRowHeight: CGFloat
    var thumbnail: CGSize
    var rowGap: CGFloat
    var listPadding: NSEdgeInsets
    var rowPadding: CGFloat
    var iconGap: CGFloat
    var rowRadius: CGFloat
    var iconSide: CGFloat
    /// Age and kind shown on every row rather than only on hover.
    /// A second, quieter line: the source app, the age and one detail.
    var twoLine: Bool = true
    var sectionHeaderHeight: CGFloat = 0

    static let minimal = ListMetrics(
        rowHeight: 62, pictureRowHeight: 62, thumbnail: CGSize(width: 40, height: 40),
        rowGap: 3, listPadding: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
        rowPadding: 12, iconGap: 14, rowRadius: 13, iconSide: 40)

    static let topDrop = ListMetrics(
        rowHeight: 64, pictureRowHeight: 64, thumbnail: CGSize(width: 42, height: 42),
        rowGap: 3, listPadding: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
        rowPadding: 14, iconGap: 14, rowRadius: 14, iconSide: 42)

    /// The sidebar trades the second line for twenty-odd rows at once.
    static let sidebar = ListMetrics(
        rowHeight: 44, pictureRowHeight: 44, thumbnail: CGSize(width: 30, height: 30),
        rowGap: 2, listPadding: NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8),
        rowPadding: 12, iconGap: 12, rowRadius: 11, iconSide: 30,
        twoLine: false, sectionHeaderHeight: 34)

    static let palette = ListMetrics(
        rowHeight: 62, pictureRowHeight: 62, thumbnail: CGSize(width: 40, height: 40),
        rowGap: 3, listPadding: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10),
        rowPadding: 12, iconGap: 14, rowRadius: 13, iconSide: 40,
        sectionHeaderHeight: 36)
}

/// Colours shared by the new styles, from the design files' variables, with
/// the selection in the app's accent colour rather than the files' orange.
enum PanelPalette {
    static var accent: Color { Color(nsColor: .controlAccentColor) }
    static func selection(_ scheme: ColorScheme) -> Color {
        accent.opacity(scheme == .dark ? 0.24 : 0.14)
    }
    static func hover(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.045)
    }
    static func tile(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.08) : .white.opacity(0.72)
    }
    static func tileHover(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.14) : .white.opacity(0.95)
    }
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.1) : .black.opacity(0.1)
    }
    static func inset(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.05) : .white.opacity(0.6)
    }
    /// Search matches.
    static func highlight(_ scheme: ColorScheme) -> Color {
        Color.yellow.opacity(scheme == .dark ? 0.3 : 0.45)
    }
}
