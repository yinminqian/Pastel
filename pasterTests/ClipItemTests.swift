//
//  ClipItemTests.swift
//  pasterTests
//

import Foundation
import SwiftData
import Testing
@testable import paster

@MainActor
struct ClipItemTests {

    private func inMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ClipSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("An item with a payload exposes its representations")
    func representationsComeFromThePayload() throws {
        let context = try inMemoryContext()
        let item = ClipItem(kind: .richText, fingerprint: "abc")
        context.insert(item)

        let archive = ClipArchive(representations: [
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("plain".utf8)),
            .init(typeIdentifier: "public.html", data: Data("<b>plain</b>".utf8)),
        ])
        let payload = ClipPayload(archive: try archive.encoded())
        context.insert(payload)
        item.payload = payload
        try context.save()

        #expect(item.representations.count == 2)
        #expect(item.representations.map(\.typeIdentifier).contains("public.html"))
    }

    @Test("An item with no payload has no representations rather than crashing")
    func noPayloadMeansNoRepresentations() throws {
        let context = try inMemoryContext()
        let item = ClipItem(kind: .text, fingerprint: "empty")
        context.insert(item)
        try context.save()
        #expect(item.representations.isEmpty)
    }

    @Test("Deleting an item cascades to its payload, so no blob is orphaned")
    func deleteCascadesToPayload() throws {
        let context = try inMemoryContext()
        let item = ClipItem(kind: .text, fingerprint: "cascade")
        context.insert(item)
        let payload = ClipPayload(archive: try ClipArchive(representations: []).encoded())
        context.insert(payload)
        item.payload = payload
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<ClipPayload>()) == 1)
        context.delete(item)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ClipPayload>()) == 0)
    }

    @Test("The legacy per-type rows are folded into a payload and removed")
    func backfillConvertsLegacyRows() throws {
        let context = try inMemoryContext()
        let item = ClipItem(kind: .text, fingerprint: "legacy")
        context.insert(item)
        item.legacyRepresentations = [
            ClipRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("old".utf8)),
            ClipRepresentation(typeIdentifier: "public.html", data: Data("<b>old</b>".utf8)),
        ]
        try context.save()

        let converted = PayloadBackfill.run(in: context)

        #expect(converted == 1)
        #expect(item.payload != nil)
        #expect(item.representations.count == 2)
        #expect(item.legacyRepresentations.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ClipRepresentation>()) == 0)
    }

    @Test("Running the backfill again is a no-op, so it is safe at every launch")
    func backfillIsIdempotent() throws {
        let context = try inMemoryContext()
        let item = ClipItem(kind: .text, fingerprint: "idem")
        context.insert(item)
        item.legacyRepresentations = [
            ClipRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("x".utf8))
        ]
        try context.save()

        #expect(PayloadBackfill.run(in: context) == 1)
        #expect(PayloadBackfill.run(in: context) == 0)
        #expect(PayloadBackfill.run(in: context) == 0)
        #expect(item.representations.count == 1)
    }

    @Test("An item that already has a payload is left alone by the backfill")
    func backfillSkipsConvertedItems() throws {
        let context = try inMemoryContext()
        let item = ClipItem(kind: .text, fingerprint: "already")
        context.insert(item)
        let payload = ClipPayload(archive: try ClipArchive(representations: [
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("new".utf8))
        ]).encoded())
        context.insert(payload)
        item.payload = payload
        try context.save()

        #expect(PayloadBackfill.run(in: context) == 0)
        #expect(item.representations.first?.typeIdentifier == "public.utf8-plain-text")
    }
}
