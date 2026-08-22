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
/// Derived at display time rather than stored. Paste keeps an icon blob and an
/// accent per app in its database, but it has to: it syncs, and a device that
/// never installed the app cannot look either up. Nothing here syncs, so
/// deriving costs no storage and stays correct when an app ships a new icon.
@MainActor
enum AppAccent {
    private static var cache: [String: Color?] = [:]

    /// - Returns: `nil` when the icon has no chromatic hue worth using — plenty
    ///   of icons are deliberately monochrome, and inventing a colour for them
    ///   would be worse than leaving the card neutral.
    static func color(forBundleID bundleID: String?) -> Color? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }

        let derived = icon(for: bundleID).flatMap(accent(for:)).map(Color.init)
        cache[bundleID] = derived
        return derived
    }

    /// The app's user-visible name, for anything that has to be *spoken* rather
    /// than shown.
    ///
    /// The interface uses the icon, which needs no name; VoiceOver cannot read
    /// an icon, and "com.apple.Safari" is not what anyone calls it.
    static func displayName(forBundleID bundleID: String?) -> String? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
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
    private static func accent(for icon: NSImage) -> NSColor? {
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
        var sumSaturation = [CGFloat](repeating: 0, count: buckets)
        var sumBrightness = [CGFloat](repeating: 0, count: buckets)

        for y in 0 ..< side {
            for x in 0 ..< side {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.alphaComponent > 0.6
                else { continue }

                let saturation = pixel.saturationComponent
                let brightness = pixel.brightnessComponent
                // Skips the greys, the near-whites and the near-blacks that
                // every icon is largely made of.
                guard saturation > 0.25, brightness > 0.20, brightness < 0.98 else { continue }

                let bucket = min(buckets - 1, Int(pixel.hueComponent * CGFloat(buckets)))
                // Weighted by saturation, so a vivid pixel counts for more than
                // a washed-out one in the same hue family.
                weight[bucket] += saturation
                sumSaturation[bucket] += saturation * saturation
                sumBrightness[bucket] += brightness * saturation
            }
        }

        guard let top = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[top] > 0
        else { return nil }

        let total = weight[top]
        // Clamped so a neon icon cannot produce a colour that is unusable as a
        // UI accent behind text.
        return NSColor(hue: (CGFloat(top) + 0.5) / CGFloat(buckets),
                       saturation: min(0.85, max(0.35, sumSaturation[top] / total)),
                       brightness: min(0.92, max(0.45, sumBrightness[top] / total)),
                       alpha: 1)
    }
}
