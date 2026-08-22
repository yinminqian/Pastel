//
//  ClipGroupingTests.swift
//  pasterTests
//

import Foundation
import SwiftData
import Testing
@testable import paster

/// The grid's layout algebra.
///
/// These exist because the derivation used to live inside a `body`, where it was
/// wrong in a way no test could see: after a pin moved a card into the leading
/// section, ⌘1 was drawn on two cards at once.
@MainActor
struct ClipGroupingTests {

    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ClipSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Newest first, matching what `@Query` hands the view.
    private func clips(_ specs: [(label: String, pinned: Bool, daysAgo: Double)],
                       in context: ModelContext) throws -> [ClipItem] {
        let items = specs.enumerated().map { index, spec in
            let item = ClipItem(
                copiedAt: Date().addingTimeInterval(-spec.daysAgo * 86_400 - Double(index)),
                kind: .text,
                fingerprint: spec.label,
                previewText: spec.label
            )
            item.isPinned = spec.pinned
            context.insert(item)
            return item
        }
        try context.save()
        return items.sorted { $0.copiedAt > $1.copiedAt }
    }

    // MARK: Ordering

    @Test("Pinned clippings come first, and the rest keep their order")
    func pinnedFirst() throws {
        let context = try context()
        let items = try clips([("a", false, 0), ("b", true, 0), ("c", false, 0), ("d", true, 0)],
                              in: context)
        let ordered = ClipGrouping.ordered(items)
        #expect(ordered.map { $0.previewText } == ["b", "d", "a", "c"])
    }

    @Test("With nothing pinned the order is untouched")
    func nothingPinned() throws {
        let context = try context()
        let items = try clips([("a", false, 0), ("b", false, 0)], in: context)
        #expect(ClipGrouping.ordered(items).map { $0.previewText } == ["a", "b"])
    }

    // MARK: Digits

    @Test("No digit is ever assigned twice")
    func digitsAreUnique() throws {
        // The bug this file exists for. Two cards showing ⌘1 means pressing it
        // pastes something other than what the user counted to.
        let context = try context()
        let items = try clips((0 ..< 12).map { ("c\($0)", $0 % 3 == 0, 0) }, in: context)
        let sections = ClipGrouping.sections(ClipGrouping.ordered(items))
        let digits = sections.flatMap { $0.entries }.compactMap(\.digit)
        #expect(digits.count == 9)
        #expect(Set(digits).count == 9)
        #expect(Set(digits) == Set(1 ... 9))
    }

    @Test("The digits run 1…9 down the grid, across section boundaries")
    func digitsFollowTheDrawnOrder() throws {
        let context = try context()
        // Two pins and three from different eras, so the numbering has to cross
        // three section boundaries to stay in the order the eye counts.
        let items = try clips([("today", false, 0), ("pin1", true, 0),
                               ("old", false, 40), ("pin2", true, 30),
                               ("yesterday", false, 1)],
                              in: context)
        let sections = ClipGrouping.sections(ClipGrouping.ordered(items))
        let drawn = sections.flatMap { $0.entries }
        #expect(drawn.map(\.digit) == [1, 2, 3, 4, 5])
        #expect(drawn.compactMap { $0.clip.previewText }
                == ["pin1", "pin2", "today", "yesterday", "old"])
    }

    @Test("Only the first nine cards get a digit")
    func digitsStopAtNine() throws {
        let context = try context()
        let items = try clips((0 ..< 15).map { ("c\($0)", false, 0) }, in: context)
        let entries = ClipGrouping.sections(ClipGrouping.ordered(items)).flatMap { $0.entries }
        #expect(entries.prefix(9).allSatisfy { $0.digit != nil })
        #expect(entries.dropFirst(9).allSatisfy { $0.digit == nil })
    }

    // MARK: Sections

    @Test("Pinned gets its own leading section")
    func pinnedSectionLeads() throws {
        let context = try context()
        let items = try clips([("a", false, 0), ("b", true, 0)], in: context)
        let sections = ClipGrouping.sections(ClipGrouping.ordered(items))
        #expect(sections.first?.title == ClipGrouping.pinnedTitle)
        #expect(sections.first?.entries.count == 1)
    }

    @Test("There is no Pinned section when nothing is pinned")
    func noEmptyPinnedSection() throws {
        let context = try context()
        let items = try clips([("a", false, 0)], in: context)
        let titles = ClipGrouping.sections(ClipGrouping.ordered(items)).map(\.title)
        #expect(!titles.contains(ClipGrouping.pinnedTitle))
    }

    @Test("A pinned clipping leaves its era rather than appearing in both")
    func pinnedAppearsOnce() throws {
        let context = try context()
        let items = try clips([("a", false, 0), ("b", true, 0), ("c", true, 40)], in: context)
        let sections = ClipGrouping.sections(ClipGrouping.ordered(items))
        let ids = sections.flatMap { $0.entries.map(\.id) }
        #expect(ids.count == Set(ids).count)
        #expect(ids.count == 3)
    }

    @Test("Section titles are unique, which is what makes them usable as ids")
    func titlesAreUnique() throws {
        let context = try context()
        // One in every era plus a pin, so every section that can exist does.
        let items = try clips([("t", false, 0), ("y", false, 1), ("w", false, 4),
                               ("e", false, 90), ("p", true, 0)],
                              in: context)
        let titles = ClipGrouping.sections(ClipGrouping.ordered(items)).map(\.title)
        #expect(titles.count == 5)
        #expect(Set(titles).count == titles.count)
    }

    @Test("Sections run newest era to oldest")
    func sectionOrder() throws {
        let context = try context()
        let items = try clips([("e", false, 90), ("t", false, 0), ("w", false, 4),
                               ("y", false, 1)],
                              in: context)
        let titles = ClipGrouping.sections(ClipGrouping.ordered(items)).map(\.title)
        #expect(titles == ["Today", "Yesterday", "Previous 7 Days", "Earlier"])
    }

    @Test("An empty history produces no sections rather than empty ones")
    func emptyHistory() {
        #expect(ClipGrouping.sections(ClipGrouping.ordered([])).isEmpty)
    }
}
