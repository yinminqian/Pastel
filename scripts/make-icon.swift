#!/usr/bin/env swift
//
//  make-icon.swift
//  paster
//
//  Regenerates Assets.xcassets/AppIcon.appiconset from geometry.
//
//  The icon is drawn rather than exported from a design tool so it is exact and
//  reproducible: perfect symmetry, the same colours at every size, and no baked
//  outer shadow (the system draws that). Run it from the repo root:
//
//      swift scripts/make-icon.swift
//

import AppKit
import Foundation

// MARK: - Design

/// Restrained indigo rather than an electric blue. System icons sit closer to
/// this; a fully saturated primary reads as a placeholder.
let tileTop = NSColor(srgbRed: 0.361, green: 0.416, blue: 0.706, alpha: 1)
let tileBottom = NSColor(srgbRed: 0.239, green: 0.290, blue: 0.564, alpha: 1)
/// Warm, so the card reads as paper against a cool tile.
let cardFill = NSColor(srgbRed: 0.980, green: 0.973, blue: 0.953, alpha: 1)
let barColor = NSColor(srgbRed: 0.239, green: 0.290, blue: 0.564, alpha: 1)

/// A continuous-curvature squircle, which is the shape macOS actually uses —
/// a plain rounded rectangle reads subtly wrong next to system icons.
func squircle(in rect: CGRect, radiusRatio: CGFloat) -> NSBezierPath {
    let r = min(rect.width, rect.height) * radiusRatio
    // Apple's shape is close to a rounded rect whose corner arcs are extended
    // and smoothed; a 1.28 control-point factor is the standard approximation.
    let k = r * 1.28
    let path = NSBezierPath()
    let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)

    path.move(to: CGPoint(x: x + r, y: y))
    path.line(to: CGPoint(x: x + w - r, y: y))
    path.curve(to: CGPoint(x: x + w, y: y + r),
               controlPoint1: CGPoint(x: x + w - r + k * 0.55, y: y),
               controlPoint2: CGPoint(x: x + w, y: y + r - k * 0.55))
    path.line(to: CGPoint(x: x + w, y: y + h - r))
    path.curve(to: CGPoint(x: x + w - r, y: y + h),
               controlPoint1: CGPoint(x: x + w, y: y + h - r + k * 0.55),
               controlPoint2: CGPoint(x: x + w - r + k * 0.55, y: y + h))
    path.line(to: CGPoint(x: x + r, y: y + h))
    path.curve(to: CGPoint(x: x, y: y + h - r),
               controlPoint1: CGPoint(x: x + r - k * 0.55, y: y + h),
               controlPoint2: CGPoint(x: x, y: y + h - r + k * 0.55))
    path.line(to: CGPoint(x: x, y: y + r))
    path.curve(to: CGPoint(x: x + r, y: y),
               controlPoint1: CGPoint(x: x, y: y + r - k * 0.55),
               controlPoint2: CGPoint(x: x + r - k * 0.55, y: y))
    path.close()
    return path
}

/// Draws the icon into a bitmap of `size` points square.
///
/// Everything is expressed as a fraction of the canvas, so every size is the
/// same drawing rather than a scaled screenshot of one.
func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                    pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Tile, edge to edge. No inset and no outer shadow: macOS masks the icon
    // and draws its own shadow, and baking one in double-shadows it.
    let tile = squircle(in: CGRect(x: 0, y: 0, width: s, height: s), radiusRatio: 0.224)
    tile.setClip()
    NSGradient(starting: tileBottom, ending: tileTop)?
        .draw(in: CGRect(x: 0, y: 0, width: s, height: s), angle: 90)

    // The glyph: two offset cards.
    //
    // The FRONT card is centred, not the pair's bounding box. Centring the box
    // puts the bright card down and to the right of centre, because all the
    // visual weight is in it — the eye reads the composition as off-balance
    // even though the geometry is symmetrical. The back card's sliver hangs up
    // and to the left, where it costs nothing.
    let cardW = s * 0.560
    let cardH = s * 0.408
    let step = s * 0.052
    let cardRadius: CGFloat = 0.10

    let front = CGRect(x: (s - cardW) / 2, y: (s - cardH) / 2, width: cardW, height: cardH)
    let back = front.offsetBy(dx: -step, dy: step)

    // Drawn first so the front card overlaps it. The sliver has to survive
    // 16pt, where the offset is only a pixel or two.
    NSColor.white.withAlphaComponent(0.42).setFill()
    squircle(in: back, radiusRatio: cardRadius).fill()

    cardFill.setFill()
    squircle(in: front, radiusRatio: cardRadius).fill()

    // Two chunky bars. Two, not three: at 16pt a third becomes noise.
    let barH = cardH * 0.150
    let barX = front.minX + cardW * 0.130
    let gap = cardH * 0.150
    let totalBars = barH * 2 + gap
    let barsTop = front.midY + totalBars / 2
    barColor.setFill()
    for (index, widthRatio) in [0.740, 0.480].enumerated() {
        let y = barsTop - barH - CGFloat(index) * (barH + gap)
        let bar = CGRect(x: barX, y: y, width: cardW * widthRatio, height: barH)
        squircle(in: bar, radiusRatio: 0.42).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Emit

/// macOS needs each size at 1x and 2x; the 2x file is simply twice the points.
let entries: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

let root = FileManager.default.currentDirectoryPath
let outDir = "\(root)/paster/Assets.xcassets/AppIcon.appiconset"
guard FileManager.default.fileExists(atPath: outDir) else {
    print("no appiconset at \(outDir) — run from the repo root")
    exit(1)
}

var images: [[String: String]] = []
for entry in entries {
    let pixels = entry.point * entry.scale
    let name = "icon_\(entry.point)x\(entry.point)\(entry.scale == 2 ? "@2x" : "").png"
    guard let png = draw(size: pixels) else {
        print("failed at \(pixels)px"); exit(1)
    }
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    images.append([
        "filename": name,
        "idiom": "mac",
        "scale": "\(entry.scale)x",
        "size": "\(entry.point)x\(entry.point)",
    ])
    print("wrote \(name) (\(pixels)px, \(png.count) bytes)")
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(withJSONObject: contents,
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
print("wrote Contents.json")
