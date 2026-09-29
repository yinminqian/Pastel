//
//  AppAccent.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import SwiftUI

/// The colour a person would name if you pointed at an app's icon.
///
/// Derived at display time rather than stored. An app that syncs would have
/// to store an icon and an accent per app, since a device that never installed
/// the app cannot look either up. Nothing here syncs, so deriving costs no
/// storage and stays correct when an app ships a new icon.
@MainActor
enum AppAccent {
    private static var cache: [String: Color?] = [:]
    /// `icon` and `displayName` are cached for the same reason the accent is,
    /// and the omission was expensive: both reach into `NSWorkspace` on every
    /// call, both are called from a card's `body`, and a body runs per card per
    /// pass. Measured over 246 clippings, one pass spent 41.9 ms looking up
    /// icons and 20.3 ms looking up names — 62 of the pass's 88 ms, or roughly
    /// four dropped frames, repeated on every scroll tick.
    ///
    /// The staleness trade-off is the one this type already accepted for the
    /// accent: an app that ships a new icon keeps the old one until relaunch.
    /// That is the correct side to err on for something consulted hundreds of
    /// times a second.
    private static var iconCache: [String: NSImage?] = [:]
    private static var nameCache: [String: String?] = [:]

    /// The icon's hue, snapped to the nearest colour in `palette`; or, for the
    /// many deliberately monochrome icons, a palette colour picked by the
    /// bundle ID, so each such app still keeps one colour of its own.
    ///
    /// Snapped rather than used raw, because raw icon hues are what made the
    /// row look muddy: a navy, an olive and a dusty rose side by side read as
    /// accidents. A small set of clean colours reads as designed.
    ///
    /// - Returns: `nil` only when there is no bundle ID at all.
    static func color(forBundleID bundleID: String?) -> Color? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }

        let index = icon(for: bundleID).flatMap(dominantHue(of:)).map(nearestSwatch(toHue:))
            ?? stableIndex(of: bundleID, count: swatches.count)
        let derived = palette[index]
        cache[bundleID] = derived
        return derived
    }

    /// Bright, clean colours, each able to carry white text. In hue order.
    private static let swatches: [(red: Double, green: Double, blue: Double)] = [
        (0.94, 0.27, 0.27),  // red
        (0.97, 0.53, 0.16),  // orange
        (0.96, 0.71, 0.13),  // yellow
        (0.27, 0.74, 0.33),  // green
        (0.10, 0.68, 0.66),  // teal
        (0.20, 0.52, 0.97),  // blue
        (0.35, 0.36, 0.93),  // indigo
        (0.63, 0.38, 0.93),  // purple
        (0.94, 0.33, 0.56),  // pink
    ]

    static let palette: [Color] = swatches.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }

    private static let swatchHues: [CGFloat] = swatches.map {
        NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1).hueComponent
    }

    /// Hue is a circle, so red at 0.98 is next to red at 0.0.
    private static func nearestSwatch(toHue hue: CGFloat) -> Int {
        func distance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let d = abs(a - b)
            return min(d, 1 - d)
        }
        return swatchHues.indices.min { distance(swatchHues[$0], hue) < distance(swatchHues[$1], hue) } ?? 0
    }

    /// Not `hashValue`, which is seeded per launch: the same app has to get the
    /// same colour every time the panel opens.
    private static func stableIndex(of string: String, count: Int) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Int(hash % UInt64(count))
    }

    /// The app's user-visible name, for anything that has to be *spoken* rather
    /// than shown.
    ///
    /// The interface uses the icon, which needs no name; VoiceOver cannot read
    /// an icon, and "com.apple.Safari" is not what anyone calls it.
    static func displayName(forBundleID bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let cached = nameCache[bundleID] { return cached }

        let derived = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
        nameCache[bundleID] = derived
        return derived
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }

        let derived = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        iconCache[bundleID] = derived
        return derived
    }

    // MARK: - Derivation

    /// Reads the icon's pixels and takes the dominant chromatic hue.
    ///
    /// Two approaches were tried and rejected. Averaging the icon converges on
    /// grey, because every icon is mostly white, black and shadow. `CIKMeans`
    /// looks like the right tool but returns *premultiplied* means whose alpha
    /// channel carries each cluster's weight rather than its opacity — read it
    /// as a colour and every cluster comes out a shade of grey, silently. A
    /// 32×32 render is 1024 samples, which is ample for picking a hue, and
    /// every step of this is inspectable.
    private static func dominantHue(of icon: NSImage) -> CGFloat? {
        let side = 32
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: side, pixelsHigh: side,
                                           bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        let buckets = 24
        var weight = [CGFloat](repeating: 0, count: buckets)

        for y in 0 ..< side {
            for x in 0 ..< side {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.alphaComponent > 0.6
                else { continue }

                let saturation = pixel.saturationComponent
                let brightness = pixel.brightnessComponent
                // Skips the greys, the near-whites and the near-blacks that
                // every icon is largely made of. The floor is low enough to
                // keep dark but clearly coloured backgrounds, like Ghostty's
                // navy, which the clamp below then brightens.
                guard saturation > 0.25, brightness > 0.12, brightness < 0.98 else { continue }

                let bucket = min(buckets - 1, Int(pixel.hueComponent * CGFloat(buckets)))
                // Weighted by saturation, so a vivid pixel counts for more than
                // a washed-out one in the same hue family.
                weight[bucket] += saturation
            }
        }

        guard let top = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[top] > 0
        else { return nil }

        return (CGFloat(top) + 0.5) / CGFloat(buckets)
    }
}
