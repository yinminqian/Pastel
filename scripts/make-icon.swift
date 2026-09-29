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

/// Deep indigo into violet. Dark enough that the cards' colours carry the
/// icon, rich enough that it is not a black hole in the Dock.
let tileTop = NSColor(srgbRed: 0.310, green: 0.290, blue: 0.820, alpha: 1)
let tileBottom = NSColor(srgbRed: 0.130, green: 0.120, blue: 0.420, alpha: 1)
/// Warm, so the cards read as paper against a cool tile.
let cardFill = NSColor(srgbRed: 0.992, green: 0.988, blue: 0.976, alpha: 1)
let barColor = NSColor(srgbRed: 0.780, green: 0.790, blue: 0.830, alpha: 1)

/// The panel's own card colours, back to front — the icon is the row.
let bandColors = [
    NSColor(srgbRed: 0.97, green: 0.53, blue: 0.16, alpha: 1),  // orange
    NSColor(srgbRed: 0.27, green: 0.74, blue: 0.33, alpha: 1),  // green
    NSColor(srgbRed: 0.20, green: 0.52, blue: 0.97, alpha: 1),  // blue
]

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
    let full = CGRect(x: 0, y: 0, width: s, height: s)
    let tile = squircle(in: full, radiusRatio: 0.224)
    tile.setClip()
    NSGradient(starting: tileBottom, ending: tileTop)?.draw(in: full, angle: 90)

    // The glyph: three cards fanned from a point below the tile, each with
    // the coloured band the panel's cards carry. Back to front: orange, green,
    // blue. The front card is upright-ish and centred; the fan opens up and to
    // the left, where the back cards' bands stay visible.
    let cardW = s * 0.50
    let cardH = s * 0.54
    let bandH = cardH * 0.25
    let radius: CGFloat = 0.13
    let fans: [(angle: CGFloat, dx: CGFloat, dy: CGFloat)] = [
        (16, -0.085, 0.030),
        (6, -0.035, 0.012),
        (-5, 0.035, -0.012),
    ]
    let small = size <= 32

    for (index, fan) in fans.enumerated() {
        NSGraphicsContext.saveGraphicsState()
        let center = CGPoint(x: s / 2 + s * fan.dx, y: s / 2 + s * fan.dy - s * 0.01)
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: fan.angle)
        transform.concat()

        let card = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
        let shape = squircle(in: card, radiusRatio: radius)

        // A soft contact shadow between layers, inside the tile. Not an outer
        // icon shadow — the system draws that.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = s * 0.035
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        cardFill.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // The band, clipped to the card so it takes the card's top corners.
        NSGraphicsContext.saveGraphicsState()
        shape.setClip()
        bandColors[index].setFill()
        CGRect(x: card.minX, y: card.maxY - bandH, width: cardW, height: bandH).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Only the front card has content, and only where it survives the
        // size: at 16 and 32 px the bars are noise.
        if index == fans.count - 1 && !small {
            barColor.setFill()
            let barH = cardH * 0.075
            let x = card.minX + cardW * 0.14
            var y = card.maxY - bandH - cardH * 0.17
            for widthRatio in [0.70, 0.52, 0.62] {
                squircle(in: CGRect(x: x, y: y, width: cardW * widthRatio, height: barH),
                         radiusRatio: 0.5).fill()
                y -= barH + cardH * 0.085
            }
            // A white dot on the band: the source-app icon the real cards carry.
            NSColor.white.withAlphaComponent(0.92).setFill()
            let dot = cardH * 0.13
            NSBezierPath(ovalIn: CGRect(x: card.maxX - cardW * 0.13 - dot,
                                        y: card.maxY - bandH / 2 - dot / 2,
                                        width: dot, height: dot)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
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
