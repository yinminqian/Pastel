//
//  PanelStyleTests.swift
//  pasterTests
//

import AppKit
import Foundation
import SwiftData
import Testing
@testable import paster

@MainActor
struct PanelStyleTests {

    private let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: ClipSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func clip(copiedAt: Date) -> ClipItem {
        let item = ClipItem(copiedAt: copiedAt, kind: .text, fingerprint: UUID().uuidString,
                            previewText: "x")
        container.mainContext.insert(item)
        return item
    }

    @Test("Clippings are grouped by the day they were copied, newest first")
    func daySections() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let lastWeek = calendar.date(byAdding: .day, value: -3, to: now)!
        let clips = [clip(copiedAt: now), clip(copiedAt: now.addingTimeInterval(-60)),
                     clip(copiedAt: yesterday), clip(copiedAt: lastWeek)]

        let sections = ClipboardPanelView.daySections(clips)

        #expect(sections.map(\.title) == ["Today", "Yesterday",
                                          lastWeek.formatted(.dateTime.weekday(.wide))])
        #expect(sections.map(\.count) == [2, 1, 1])
        // Every clipping in exactly one section, in the original order.
        #expect(sections.flatMap(\.clips).map(\.fingerprint) == clips.map(\.fingerprint))
        #expect(Set(sections.map(\.id)).count == sections.count)
    }

    @Test("Every style's window fits on the screen it opens on")
    func windowsFitTheScreen() throws {
        let screen = try #require(NSScreen.main)
        for style in PanelStyle.allCases {
            let frame = style.windowFrame(on: screen)
            // The shadow margin may overhang; the panel itself may not.
            let margin = style.isFloating ? PanelStyle.shadowMargin : 0
            let panel = frame.insetBy(dx: margin, dy: margin)
            #expect(screen.frame.contains(panel.insetBy(dx: 1, dy: 1)),
                    "\(style) panel \(panel) is off \(screen.frame)")
        }
    }

    @Test("A style is stored and restored by its raw value")
    func styleRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "paster.tests.style"))
        defaults.removePersistentDomain(forName: "paster.tests.style")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.panelStyle == .basic)
        settings.panelStyle = .palette
        #expect(AppSettings(defaults: defaults).panelStyle == .palette)
    }

    @Test("Bare hex colours are recognised; ordinary words are not")
    func colours() {
        #expect(ClipVisual.colour(in: "#F2552C")?.1 == "#F2552C")
        #expect(ClipVisual.colour(in: " 2f6bff\n")?.1 == "#2F6BFF")
        #expect(ClipVisual.colour(in: "#f52")?.1 == "#FF5522")
        #expect(ClipVisual.colour(in: "bead") == nil)
        #expect(ClipVisual.colour(in: "add") == nil)
        #expect(ClipVisual.colour(in: "#F2552C is ember") == nil)
    }

    @Test("Commands are set in the monospaced face; prose is not")
    func code() {
        #expect(ClipVisual.looksLikeCode("git push origin main"))
        #expect(ClipVisual.looksLikeCode("ssh deploy@10.0.3.21 -p 2222"))
        #expect(ClipVisual.looksLikeCode("let rows = clips.prefix(14)"))
        #expect(!ClipVisual.looksLikeCode("Can you review PR #482 before lunch?"))
        #expect(!ClipVisual.looksLikeCode("明天下午三点开会"))
    }

    @Test("Whitespace, newlines included, collapses to single spaces")
    func oneLineText() {
        #expect(oneLine("\n\n  first\tsecond\n third ") == "first second third")
    }
}
