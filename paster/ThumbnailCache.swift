//
//  ThumbnailCache.swift
//  paster
//
//  Created by yinminqian on 23/8/2026.
//

import AppKit

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

    /// Called when history is cleared, so the cache cannot outlive its rows.
    static func removeAll() {
        cache.removeAll()
    }
}
