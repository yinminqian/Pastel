//
//  ClipSearchTests.swift
//  pasterTests
//

import Foundation
import SwiftData
import Testing
@testable import paster

@MainActor
struct ClipSearchTests {

    /// Held so the items stay attached to a live context for the test's length.
    private let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: ClipSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func clip(_ text: String?, kind: ClipKind = .text) -> ClipItem {
        let item = ClipItem(kind: kind, fingerprint: UUID().uuidString, previewText: text)
        container.mainContext.insert(item)
        return item
    }

    @Test("Every term has to match, in any field")
    func allTermsMatch() {
        let link = clip("https://www.v2ex.com/t/1244750", kind: .link)
        let search = ClipSearch(query: "chrome v2ex")
        #expect(search.matches(link, appName: "Google Chrome"))
        #expect(!search.matches(link, appName: "WeChat"))
    }

    @Test("Case and full-width forms do not matter")
    func insensitive() {
        let item = clip("Hello ＡＢＣ")
        #expect(ClipSearch(query: "hello abc").matches(item, appName: nil))
    }

    @Test("An image with no text is found by its kind")
    func kindWord() {
        let image = clip(nil, kind: .image)
        #expect(ClipSearch(query: "image").matches(image, appName: nil))
        #expect(!ClipSearch(query: "text").matches(image, appName: nil))
    }

    @Test("The kind filter narrows before the terms are considered")
    func kindFilter() {
        let text = clip("hello")
        let rich = clip("hello", kind: .richText)
        let link = clip("https://hello.com", kind: .link)
        let search = ClipSearch(query: "hello", kind: .text)
        #expect(search.matches(text, appName: nil))
        #expect(search.matches(rich, appName: nil))
        #expect(!search.matches(link, appName: nil))
        #expect(ClipSearch(query: "", kind: .link).matches(link, appName: nil))
    }

    @Test("An empty query with no filter is inactive and matches everything")
    func inactive() {
        let search = ClipSearch(query: "   ")
        #expect(!search.isActive)
        #expect(search.matches(clip("anything"), appName: nil))
    }

    @Test("Overlapping matches merge into one range")
    func mergedRanges() {
        let text = "abcdef"
        let ranges = ClipSearch(query: "abc cde").ranges(in: text)
        #expect(ranges.count == 1)
        #expect(ranges.first.map { String(text[$0]) } == "abcde")
    }

    @Test("A match near the start leaves the text whole")
    func snippetNearStart() {
        let text = "find me here, then a long tail of text"
        #expect(ClipSearch(query: "find").snippet(of: text) == text)
    }

    @Test("A match deep in the text starts the snippet near it")
    func snippetDeep() {
        let text = String(repeating: "filler ", count: 30) + "needle and after"
        let snippet = ClipSearch(query: "needle").snippet(of: text)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.contains("needle and after"))
        #expect(snippet.count < text.count)
    }
}
