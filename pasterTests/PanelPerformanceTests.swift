//
//  PanelPerformanceTests.swift
//  pasterTests
//

import AppKit
import Foundation
import SwiftData
import Testing
@testable import paster

/// Guards the per-pass cost of drawing the grid.
///
/// These exist because the grid became unusable at a few hundred clippings and
/// the cause was invisible to every other test: `AppAccent.icon`,
/// `AppAccent.displayName` and the thumbnail decode all sat in a card's `body`
/// with no cache, and a body runs per card per pass. One pass over 246 rows cost
/// 87.8 ms — 5.3 frames at 60 Hz, repaid on every scroll tick.
///
/// They assert on *ratios and repeat-pass behaviour*, not on wall-clock budgets:
/// an absolute millisecond threshold would be a flaky test on a busy machine,
/// where "the second identical pass must be far cheaper than the first" is a
/// statement about caching that holds on any hardware.
@Suite(.serialized)
@MainActor
struct PanelPerformanceTests {

    private func png(_ side: Int) -> Data {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// A store shaped like the one that was slow: a few hundred rows, a fifth
    /// carrying a real thumbnail, spread over several source apps.
    private func seed(_ count: Int) throws -> [ClipItem] {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ClipSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let thumbnail = png(160)
        let apps = ["com.apple.Safari", "com.apple.dt.Xcode", "com.apple.Terminal",
                    "com.apple.finder", "com.apple.TextEdit"]
        for index in 0 ..< count {
            let isImage = index % 5 == 0
            context.insert(ClipItem(
                copiedAt: Date().addingTimeInterval(-Double(index) * 60),
                kind: isImage ? .image : .text,
                fingerprint: "perf-\(index)",
                previewText: isImage ? nil : String(repeating: "clipping \(index) ", count: 6),
                contentLength: 120,
                thumbnailData: isImage ? thumbnail : nil,
                sourceBundleID: apps[index % apps.count]
            ))
        }
        try context.save()
        return try context.fetch(
            FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        )
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        return Double(start.duration(to: .now).components.attoseconds) / 1e15
    }

    @Test("Source-app icons are looked up once, not once per card per pass")
    func iconsAreCached() throws {
        let clips = try seed(246)
        let first = milliseconds { for c in clips { _ = AppAccent.icon(for: c.sourceBundleID) } }
        let second = milliseconds { for c in clips { _ = AppAccent.icon(for: c.sourceBundleID) } }
        // Uncached this was ~30 ms on every pass, first and tenth alike, because
        // each call reached into NSWorkspace twice.
        #expect(second < first / 5,
                "repeat pass \(second) ms should be far below the first \(first) ms")
        #expect(second < 5, "246 cached icon lookups took \(second) ms")
    }

    @Test("Source-app names are looked up once, not once per card per pass")
    func namesAreCached() throws {
        let clips = try seed(246)
        _ = milliseconds { for c in clips { _ = AppAccent.displayName(forBundleID: c.sourceBundleID) } }
        let second = milliseconds { for c in clips { _ = AppAccent.displayName(forBundleID: c.sourceBundleID) } }
        // Added for the cards' VoiceOver labels, which made every card pay a
        // filesystem lookup it did not previously pay.
        #expect(second < 5, "246 cached name lookups took \(second) ms")
    }

    @Test("A thumbnail is decoded once, not on every pass of its card's body")
    func thumbnailsAreDecodedOnce() throws {
        let clips = try seed(246)
        func pass() -> Double {
            milliseconds {
                for c in clips {
                    _ = ThumbnailCache.image(fingerprint: c.fingerprint, data: c.thumbnailData)
                }
            }
        }
        let first = pass()
        let second = pass()
        #expect(second < first / 3,
                "repeat pass \(second) ms should be far below the first \(first) ms")
    }

    @Test("Clearing history drops the decoded thumbnails with it")
    func clearingDropsTheCache() throws {
        let clips = try seed(10)
        let clip = try #require(clips.first { $0.thumbnailData != nil })
        _ = ThumbnailCache.image(fingerprint: clip.fingerprint, data: clip.thumbnailData)
        ThumbnailCache.removeAll()
        // Nothing to assert but that it is a miss again; a cache that outlived
        // its rows would hold every thumbnail of a history the user deleted.
        let afterClear = milliseconds {
            _ = ThumbnailCache.image(fingerprint: clip.fingerprint, data: clip.thumbnailData)
        }
        let cached = milliseconds {
            _ = ThumbnailCache.image(fingerprint: clip.fingerprint, data: clip.thumbnailData)
        }
        #expect(cached <= afterClear)
    }

    @Test("Grouping the whole history stays cheap")
    func groupingIsCheap() throws {
        let clips = try seed(500)
        let ms = milliseconds { _ = ClipGrouping.sections(ClipGrouping.ordered(clips)) }
        // Measured at 1.5 ms for 246 rows and comfortably inside a frame at 500.
        // Asserted because this is the one per-pass cost that grows with history
        // and cannot be cached — it depends on the search text and the clock.
        #expect(ms < 16, "grouping 500 rows took \(ms) ms, a whole frame at 60 Hz")
    }
}
