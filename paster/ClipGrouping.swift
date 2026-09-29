//
//  ClipGrouping.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import Foundation
import SwiftData

/// Coarse time buckets, so the grid carries time context in a handful of
/// headers instead of repeating a relative timestamp on every card.
enum ClipEra: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case week = "Previous 7 Days"
    case earlier = "Earlier"

    static func of(_ date: Date, now: Date = Date()) -> ClipEra {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        return days <= 7 ? .week : .earlier
    }
}

// MARK: - Grouping

/// How the grid is laid out: which sections, in what order, and which cards
/// carry a quick-paste digit.
///
/// Pulled out of the view because the ordering is shared by three things that
/// have to agree — the sections the grid draws, the list the arrow keys walk,
/// and the ⌘1–⌘9 digits — and a disagreement between them is invisible to a
/// test as long as the derivation lives inside a `body`. It was in fact wrong:
/// after a pin moved a card into the leading section, ⌘1 was drawn on two cards
/// at once and two cards showed a selection ring.
enum ClipGrouping {
    /// A clipping together with the digit that pastes it.
    ///
    /// Paired rather than looked up per card. The digit describes a position in
    /// the grid, so deriving it separately from the grid's own ordering makes
    /// two sources of truth that can disagree. It also replaces an O(n) scan
    /// per card with one pass over the list.
    struct Entry: Identifiable {
        let clip: ClipItem
        let digit: Int?
        var id: PersistentIdentifier { clip.persistentModelID }
    }

    /// Identified by its title, not by its position.
    ///
    /// An offset-based id was the other half of the same bug: pinning inserts a
    /// section at the front, so every later section's offset shifts by one and
    /// SwiftUI matches each section's content against the section that used to
    /// be there — leaving cards with properties from a layout they are no
    /// longer part of. Titles are unique by construction: one "Pinned" and at
    /// most one per era.
    struct Section: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let pinnedTitle = "Pinned"

    /// The single ordering everything else reads: pinned first, input order
    /// preserved within each partition.
    ///
    /// The keyboard and the digits both use this, so a pinned card drawn in the
    /// leading section is also the card ⌘1 pastes and the card the up arrow
    /// stops at. Sorting only inside `sections` would leave the keyboard
    /// walking an order the eye does not see.
    static func ordered(_ clips: [ClipItem]) -> [ClipItem] {
        let pinned = clips.filter(\.isPinned)
        guard !pinned.isEmpty else { return clips }
        return pinned + clips.filter { !$0.isPinned }
    }

    /// - Parameter clips: already through `ordered`.
    static func sections(_ clips: [ClipItem], now: Date = Date()) -> [Section] {
        // 1–9 for the first nine cards overall, numbered in the order the grid
        // draws them, so the digits match what the eye counts from the top
        // regardless of where the section boundaries fall.
        var digits: [PersistentIdentifier: Int] = [:]
        for (index, clip) in clips.prefix(9).enumerated() {
            digits[clip.persistentModelID] = index + 1
        }
        func numbered(_ items: [ClipItem]) -> [Entry] {
            items.map { Entry(clip: $0, digit: digits[$0.persistentModelID]) }
        }

        var result: [Section] = []

        // Pinned clippings leave their era entirely rather than appearing twice.
        // A card in two places is a card the arrow keys visit twice and the
        // digits cannot label, and "kept on purpose" is the more useful thing to
        // know about it than when it was copied.
        let pinned = clips.filter(\.isPinned)
        if !pinned.isEmpty {
            result.append(Section(title: pinnedTitle, entries: numbered(pinned)))
        }

        let buckets = Dictionary(grouping: clips.filter { !$0.isPinned }) {
            ClipEra.of($0.copiedAt, now: now)
        }
        result += ClipEra.allCases.compactMap { era in
            guard let items = buckets[era], !items.isEmpty else { return nil }
            return Section(title: era.rawValue, entries: numbered(items))
        }
        return result
    }
}
