//
//  ThumbnailCache.swift
//  paster
//
//  Created by yinminqian on 23/8/2026.
//

import AppKit
import ImageIO

/// Decoded card thumbnails, kept so a card's `body` does not decode a PNG.
///
/// `NSImage(data:)` inside a computed property looks free and is not: a body
/// runs per card per pass, so scrolling decoded every visible thumbnail on
/// every tick. Measured over 246 clippings with 50 thumbnails, one pass spent
/// 7.6 ms there and three consecutive passes cost the same — nothing was being
/// reused.
///
/// Keyed by fingerprint rather than by `PersistentIdentifier`: the fingerprint
/// is a digest of the content, so identical content shares one decode and a
/// re-inserted clipping hits the cache rather than missing it.
@MainActor
enum ThumbnailCache {
    private static var cache: [String: NSImage] = [:]
    /// Bounded so a long session cannot hold every thumbnail the user has ever
    /// scrolled past. Cleared wholesale rather than evicted one by one: the
    /// grid re-decodes what is on screen within a frame or two, and an LRU here
    /// would be more machinery than the problem deserves.
    private static let limit = 400

    static func image(fingerprint: String, data: Data?) -> NSImage? {
        if let cached = cache[fingerprint] { return cached }
        guard let data, let image = NSImage(data: data) else { return nil }
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[fingerprint] = image
        return image
    }

    /// An image's size, for its card's caption. `nil` results are kept too, so
    /// an unreadable image is not retried on every pass.
    private static var imageSizes: [String: CGSize?] = [:]

    /// In points, not pixels — a Retina screenshot of a 258-point-wide area
    /// is 258 wide, as Finder's Get Info says, though it holds 516 pixels.
    /// Read from the image's header, not by decoding it. `source` is only
    /// called on a miss.
    static func imageSize(fingerprint: String, source: () -> CGImageSource?) -> CGSize? {
        if let cached = imageSizes[fingerprint] { return cached }
        let size = source().flatMap { image -> CGSize? in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Double,
                  let height = properties[kCGImagePropertyPixelHeight] as? Double
            else { return nil }
            // 72 dpi is one pixel per point, and what an image without a
            // resolution is taken to be.
            let dpiX = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
            let dpiY = properties[kCGImagePropertyDPIHeight] as? Double ?? 72
            return CGSize(width: (width * 72 / dpiX).rounded(),
                          height: (height * 72 / dpiY).rounded())
        }
        if imageSizes.count >= limit { imageSizes.removeAll(keepingCapacity: true) }
        imageSizes[fingerprint] = size
        return size
    }

    /// Only what has already been read; never reads anything itself.
    static func cachedImageSize(fingerprint: String) -> CGSize? {
        imageSizes[fingerprint] ?? nil
    }

    /// Called when history is cleared, so the cache cannot outlive its rows.
    static func removeAll() {
        cache.removeAll()
        imageSizes.removeAll()
    }
}
