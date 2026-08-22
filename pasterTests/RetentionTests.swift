//
//  RetentionTests.swift
//  pasterTests
//

import Foundation
import SwiftData
import Testing
@testable import paster

/// Everything that deletes the user's clippings on purpose.
@MainActor
struct RetentionTests {

    private func inMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ClipSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func settings(_ name: String, limit: Int, days: Int) -> AppSettings {
        let suite = "paster.tests.retention.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.historyLimit = limit
        settings.retentionDays = days
        return settings
    }

    /// Inserted newest-first so the index reads the way the panel shows them.
    @discardableResult
    private func insert(_ count: Int,
                        into context: ModelContext,
                        pinned: Bool = false,
                        ageInDays: Double = 0) -> [ClipItem] {
        (0 ..< count).map { index in
            let item = ClipItem(
                copiedAt: Date().addingTimeInterval(-ageInDays * 86_400 - Double(index)),
                kind: .text,
                fingerprint: "\(pinned ? "pin" : "clip")-\(ageInDays)-\(index)",
                previewText: "item \(index)"
            )
            item.isPinned = pinned
            context.insert(item)
            return item
        }
    }

    // MARK: Count axis

    @Test("The newest clippings up to the limit survive and the rest go")
    func countLimitDeletesTheOldest() throws {
        let context = try inMemoryContext()
        let monitor = ClipboardMonitor(context: context,
                                       settings: settings("count", limit: 3, days: 365))
        insert(5, into: context)
        try context.save()

        monitor.prune()

        let survivors = try context.fetch(
            FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        )
        #expect(survivors.count == 3)
        #expect(survivors.map(\.previewText) == ["item 0", "item 1", "item 2"])
    }

    @Test("Pinned clippings survive the count limit")
    func pinnedSurviveTheCountLimit() throws {
        let context = try inMemoryContext()
        let monitor = ClipboardMonitor(context: context,
                                       settings: settings("pinCount", limit: 2, days: 365))
        insert(2, into: context, pinned: true, ageInDays: 5)
        insert(5, into: context)
        try context.save()

        monitor.prune()

        let all = try context.fetch(FetchDescriptor<ClipItem>())
        // Two pins kept plus the two newest unpinned. The pins do NOT eat into
        // the limit: had they counted, only the single newest unpinned clipping
        // would remain and the limit would be doing something the user did not
        // ask for.
        #expect(all.filter(\.isPinned).count == 2)
        #expect(all.filter { !$0.isPinned }.count == 2)
    }

    @Test("The offset is measured against the same list it deletes from")
    func offsetIsNotSkewedByPins() throws {
        let context = try inMemoryContext()
        let monitor = ClipboardMonitor(context: context,
                                       settings: settings("offset", limit: 3, days: 365))
        // More pins than the limit, which is what makes the two-axis mistake
        // visible: an offset counted over every row would start past the end of
        // the unpinned list and delete nothing at all.
        insert(4, into: context, pinned: true, ageInDays: 5)
        insert(6, into: context)
        try context.save()

        monitor.prune()

        let unpinned = try context.fetch(
            FetchDescriptor<ClipItem>(predicate: #Predicate { !$0.isPinned })
        )
        #expect(unpinned.count == 3)
    }

    // MARK: Age axis

    @Test("Clippings older than the retention window go")
    func ageLimitDeletesTheStale() throws {
        let context = try inMemoryContext()
        let monitor = ClipboardMonitor(context: context,
                                       settings: settings("age", limit: 500, days: 7))
        insert(2, into: context, ageInDays: 30)
        insert(2, into: context, ageInDays: 1)
        try context.save()

        monitor.prune()

        let remaining = try context.fetchCount(FetchDescriptor<ClipItem>())
        #expect(remaining == 2)
    }

    @Test("Pinned clippings survive the age limit too")
    func pinnedSurviveTheAgeLimit() throws {
        let context = try inMemoryContext()
        let monitor = ClipboardMonitor(context: context,
                                       settings: settings("pinAge", limit: 500, days: 7))
        // A pin that expires quietly after a month is worse than no pin, so
        // both axes have to honour it, not just the one that is easier to fix.
        insert(2, into: context, pinned: true, ageInDays: 400)
        insert(2, into: context, ageInDays: 30)
        try context.save()

        monitor.prune()

        let all = try context.fetch(FetchDescriptor<ClipItem>())
        #expect(all.count == 2)
        #expect(all.allSatisfy { $0.isPinned })
    }

    // MARK: Clearing

    @Test("Clearing keeps the pins and deletes everything else")
    func clearKeepsPins() throws {
        let context = try inMemoryContext()
        insert(3, into: context, pinned: true)
        insert(7, into: context)
        try context.save()

        // A private pasteboard, so running the suite does not wipe the
        // developer's real clipboard.
        let deleted = ClipboardHistory.clear(in: context,
                                             keepingPinned: true,
                                             pasteboard: .withUniqueName())

        #expect(deleted == 7)
        let all = try context.fetch(FetchDescriptor<ClipItem>())
        #expect(all.count == 3)
        #expect(all.allSatisfy { $0.isPinned })
    }

    @Test("Clearing without keeping pins empties the store")
    func clearEverything() throws {
        let context = try inMemoryContext()
        insert(3, into: context, pinned: true)
        insert(4, into: context)
        try context.save()

        let deleted = ClipboardHistory.clear(in: context,
                                             keepingPinned: false,
                                             pasteboard: .withUniqueName())

        #expect(deleted == 7)
        let remaining = try context.fetchCount(FetchDescriptor<ClipItem>())
        #expect(remaining == 0)
    }

    @Test("Clearing cascades to the payloads, so no blob is orphaned")
    func clearCascadesToPayloads() throws {
        let context = try inMemoryContext()
        let item = ClipItem(kind: .text, fingerprint: "with-payload")
        context.insert(item)
        let payload = ClipPayload(
            archive: try ClipArchive(representations: [
                .init(typeIdentifier: "public.utf8-plain-text", data: Data("x".utf8)),
            ]).encoded()
        )
        context.insert(payload)
        item.payload = payload
        try context.save()

        // The reason `clear` fetches and deletes rather than using
        // `delete(model:where:)`: the batch form runs below the object graph and
        // skips the cascade, leaving the blob and its external file behind.
        ClipboardHistory.clear(in: context,
                               keepingPinned: false,
                               pasteboard: .withUniqueName())

        let orphans = try context.fetchCount(FetchDescriptor<ClipPayload>())
        #expect(orphans == 0)
    }

    @Test("The tally describes what would go before anything does")
    func tallyCountsBothGroups() throws {
        let context = try inMemoryContext()
        insert(2, into: context, pinned: true)
        insert(5, into: context)
        try context.save()

        let keeping = ClipboardHistory.tally(in: context, keepingPinned: true)
        #expect(keeping.deletable == 5)
        #expect(keeping.pinned == 2)

        let everything = ClipboardHistory.tally(in: context, keepingPinned: false)
        #expect(everything.deletable == 7)
        #expect(everything.pinned == 0)
    }

    @Test("An empty store tallies to nothing, so the menu item can refuse")
    func emptyTally() throws {
        let context = try inMemoryContext()
        #expect(ClipboardHistory.tally(in: context, keepingPinned: true).isEmpty)
    }
}
