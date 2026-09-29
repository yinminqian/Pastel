//
//  ClipSearch.swift
//  paster
//
//  Created by yinminqian on 25/9/2026.
//

import Foundation

/// What the search field matches, kept out of the view so it can be tested.
///
/// A query is split on whitespace and every term has to match — "chrome
/// v2ex" finds the v2ex link copied from Chrome, not every Chrome clipping
/// plus every v2ex one. A term matches if it appears in the clipping's text,
/// its kind, its link's host, or the name of the app it came from, so an
/// image, which has no text, can still be found by "image" or by its app.
struct ClipSearch: Equatable {
    /// The kinds a filter can narrow to. `nil` in `kind` means all of them.
    enum KindFilter: String, CaseIterable, Identifiable {
        case text = "Text"
        case link = "Link"
        case image = "Image"
        case file = "File"

        var id: String { rawValue }

        /// The name shown in the filter menu.
        var title: String {
            switch self {
            case .text: String(localized: "Text")
            case .link: String(localized: "Link")
            case .image: String(localized: "Image")
            case .file: String(localized: "File")
            }
        }

        var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .link: "link"
            case .image: "photo"
            case .file: "doc"
            }
        }

        func includes(_ kind: ClipKind) -> Bool {
            switch self {
            case .text: kind == .text || kind == .richText
            case .link: kind == .link
            case .image: kind == .image
            case .file: kind == .fileURL
            }
        }
    }

    let terms: [String]
    let kind: KindFilter?

    init(query: String, kind: KindFilter? = nil) {
        self.terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        self.kind = kind
    }

    /// Whether the search narrows anything at all.
    var isActive: Bool { !terms.isEmpty || kind != nil }

    /// - Parameter appName: looked up by the caller, which owns the cache.
    func matches(_ clip: ClipItem, appName: String?) -> Bool {
        if let kind, !kind.includes(clip.kind) { return false }
        guard !terms.isEmpty else { return true }
        let fields = [clip.previewText, clip.kindLabel, clip.linkURL?.host, appName]
            .compactMap { $0 }
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: Self.options) != nil }
        }
    }

    /// Case- and width-insensitive, so "ABC" finds "abc" and full-width
    /// characters match their half-width forms — the latter matters for text
    /// typed with a Chinese input method.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// The ranges of every term in `text`, in order, without overlaps.
    func ranges(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in terms {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: term, options: Self.options, range: start ..< text.endIndex) {
                found.append(range)
                start = range.upperBound
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The text to show on a card: whole, unless the first match is too far in
    /// to be visible, in which case it starts a little before the match.
    ///
    /// A card shows a few lines. A match on line twelve would otherwise put a
    /// card in the results with no visible reason for being there.
    func snippet(of text: String, lead: Int = 30, threshold: Int = 80) -> String {
        guard let first = ranges(in: text).first else { return text }
        let offset = text.distance(from: text.startIndex, to: first.lowerBound)
        guard offset > threshold else { return text }
        var start = text.index(first.lowerBound, offsetBy: -lead)
        // Start on a line or word boundary if there is one nearby, rather than
        // mid-word.
        if let boundary = text[start ..< first.lowerBound].lastIndex(where: { $0.isNewline }) {
            start = text.index(after: boundary)
        } else if let space = text[start ..< first.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        return "…" + text[start...]
    }
}
