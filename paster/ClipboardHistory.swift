//
//  ClipboardHistory.swift
//  paster
//
//  Created by yinminqian on 22/8/2026.
//

import AppKit
import SwiftData

/// Deleting the stored history in one go.
///
/// A free operation over a context rather than a method on `ClipboardMonitor`,
/// so it can be called from the menu bar, from Settings and from a test without
/// any of them owning the poller — and so the confirmation stays at the call
/// site, where the UI framework belongs.
enum ClipboardHistory {
    /// How much would go, for the confirmation to quote before anything does.
    struct Tally {
        var deletable: Int
        var pinned: Int
        var isEmpty: Bool { deletable == 0 && pinned == 0 }
    }

    static func tally(in context: ModelContext, keepingPinned: Bool) -> Tally {
        let pinned = (try? context.fetchCount(
            FetchDescriptor<ClipItem>(predicate: #Predicate { $0.isPinned })
        )) ?? 0
        let total = (try? context.fetchCount(FetchDescriptor<ClipItem>())) ?? 0
        return keepingPinned
            ? Tally(deletable: total - pinned, pinned: pinned)
            : Tally(deletable: total, pinned: 0)
    }

    /// Deletes the history and empties the system pasteboard.
    ///
    /// Both halves are the point. Leaving the pasteboard loaded would mean the
    /// thing the user just asked to forget is still one ⌘V away, and the next
    /// app to read the pasteboard would still see it — so a "clear history" that
    /// only touched the database would be a false promise. Emptying it also
    /// moves `changeCount`, and the poller's next tick advances its token and
    /// finds no items, so nothing is re-captured.
    ///
    /// - Returns: the number of clippings deleted.
    @discardableResult
    static func clear(in context: ModelContext,
                      keepingPinned: Bool,
                      pasteboard: NSPasteboard? = .general) -> Int {
        // Fetch-and-delete rather than `context.delete(model:where:)`: the batch
        // form runs at the store level and skips the cascade rules, which would
        // orphan every payload row and its external thumbnail file. A few
        // thousand rows is nothing to load.
        let descriptor = keepingPinned
            ? FetchDescriptor<ClipItem>(predicate: #Predicate { !$0.isPinned })
            : FetchDescriptor<ClipItem>()

        let doomed = (try? context.fetch(descriptor)) ?? []
        doomed.forEach(context.delete)
        if !doomed.isEmpty { try? context.save() }

        pasteboard?.clearContents()
        // The decoded thumbnails belong to rows that no longer exist.
        ThumbnailCache.removeAll()
        return doomed.count
    }
}
