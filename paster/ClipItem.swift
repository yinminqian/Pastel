//
//  ClipItem.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import Foundation
import SwiftData

/// What a clipping mainly is, chosen from the representations it carries.
/// Used for card layout, so it is stored rather than computed — computed
/// properties cannot appear in predicates if this ever needs filtering.
enum ClipKind: String, Codable, CaseIterable {
    case text
    case richText
    case image
    case fileURL
    case other
}

// MARK: - Payload archive

/// Versioned envelope for a clipping's serialized representations.
///
/// The payload is one opaque blob as far as the database is concerned, so the
/// only way to evolve its layout is an explicit version tag: a build must keep
/// being able to decode archives written by older builds. Bumping `version`
/// without handling the older value here is the mistake this field exists to
/// prevent.
/// `nonisolated` because this is a pure value type with no actor affinity —
/// the project defaults to MainActor isolation, which would otherwise stop a
/// model's computed property from decoding its own payload.
nonisolated struct ClipArchive: Codable {
    static let currentVersion = 1

    struct Representation: Codable {
        var typeIdentifier: String
        var data: Data
    }

    var version: Int
    var representations: [Representation]

    init(representations: [Representation]) {
        self.version = Self.currentVersion
        self.representations = representations
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        // Binary, not XML: these payloads are mostly `Data`, and the XML
        // format would base64 every byte of them.
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> ClipArchive {
        try PropertyListDecoder().decode(ClipArchive.self, from: data)
    }
}

// MARK: - Models

/// One clipboard event.
///
/// Keeping every type representation is what makes pasting lossless: writing
/// them all back lets the destination app pick its own best fit, so rich text
/// stays rich and HTML stays HTML instead of collapsing to plain text.
@Model
final class ClipItem {
    /// Repeat copies of identical content collapse onto one row. The unique
    /// constraint is also the index the dedup lookup uses, so there is no
    /// separate `#Index` on this property — declaring both is redundant.
    ///
    /// Deliberately NOT indexed on `copiedAt`. This table takes an INSERT on
    /// every copy, so a date B-tree would be write amplification on the
    /// hottest path in the app, and with a few hundred rows the sort is faster
    /// done in memory than maintained on disk.
    #Unique<ClipItem>([\.fingerprint])

    var copiedAt: Date = Date()
    var lastPastedAt: Date?
    var kind: ClipKind = ClipKind.other

    /// Digest over every representation, used to recognise a repeat copy.
    var fingerprint: String = ""

    /// Denormalised so a card can render without loading any blob. Not named
    /// `description` — SwiftData explicitly disallows that property name.
    var previewText: String?

    /// Small PNG derived at capture time, for image cards.
    ///
    /// Exists so drawing a card never touches the payload: a grid of
    /// screenshots would otherwise decode several megabytes per card on every
    /// keystroke in the search field.
    @Attribute(.externalStorage) var thumbnailData: Data?

    /// Bundle identifier of whoever produced this. Normally the frontmost app,
    /// but `org.nspasteboard.source` wins when present, since a background or
    /// cross-device write did not come from whatever happened to be in front.
    ///
    /// Kept as a plain string rather than normalised into its own model: the
    /// app icon is looked up live from `NSWorkspace`, which caches, so there is
    /// no per-row blob here that normalising would deduplicate.
    var sourceBundleID: String?

    /// Arrived from another device through Universal Clipboard, so
    /// `sourceBundleID` describes this Mac's foreground rather than the origin.
    var isFromRemoteDevice: Bool = false

    /// The heavy payload, isolated in its own model purely so that browsing
    /// history never faults it.
    @Relationship(deleteRule: .cascade, inverse: \ClipPayload.item)
    var payload: ClipPayload?

    /// Superseded by `payload`, kept only so the v1 store can be migrated.
    /// Nothing writes these any more.
    @Relationship(deleteRule: .cascade, inverse: \ClipRepresentation.item)
    var legacyRepresentations: [ClipRepresentation] = []

    init(copiedAt: Date = Date(),
         kind: ClipKind,
         fingerprint: String,
         previewText: String? = nil,
         thumbnailData: Data? = nil,
         sourceBundleID: String? = nil,
         isFromRemoteDevice: Bool = false) {
        self.copiedAt = copiedAt
        self.kind = kind
        self.fingerprint = fingerprint
        self.previewText = previewText
        self.thumbnailData = thumbnailData
        self.sourceBundleID = sourceBundleID
        self.isFromRemoteDevice = isFromRemoteDevice
    }

    /// Decoded representations, ready to write back to the pasteboard.
    var representations: [ClipArchive.Representation] {
        guard let archive = payload?.archive,
              let decoded = try? ClipArchive.decode(archive)
        else { return [] }
        return decoded.representations
    }
}

/// A clipping's pasteboard payload: every representation in one archive.
///
/// One row per clipping rather than one row per type. Restoring is then a
/// single fetch and one decode instead of an N-row join, and — more
/// importantly — the blob lives on a model the history view never touches, so
/// scrolling a list of clippings cannot fault megabytes of image data.
@Model
final class ClipPayload {
    @Attribute(.externalStorage) var archive: Data = Data()

    /// Optional and without `@Relationship` — the macro belongs on one side of
    /// the pair only, and it is on `ClipItem`.
    var item: ClipItem?

    init(archive: Data) {
        self.archive = archive
    }
}

/// The v1 shape: one row per pasteboard type.
///
/// Retained for exactly one schema version so the migration can fold existing
/// rows into `ClipPayload`. Dropping it outright would have made every
/// pre-existing clipping unpastable.
@Model
final class ClipRepresentation {
    var typeIdentifier: String = ""
    @Attribute(.externalStorage) var data: Data = Data()
    var item: ClipItem?

    init(typeIdentifier: String, data: Data) {
        self.typeIdentifier = typeIdentifier
        self.data = data
    }
}

// MARK: - Schema

/// One schema, listing the live models.
///
/// An earlier attempt declared a V1 and a V2 `VersionedSchema` with a custom
/// `MigrationStage` between them. That cannot work when both versions name the
/// same live classes — SwiftData has no way to tell the two apart, and building
/// the container threw an Objective-C exception that Swift's `catch` cannot
/// see, so the app launched with nothing initialised and no error anywhere.
///
/// Expressing it properly would mean duplicating every model inside two
/// namespaces. For a purely additive change that is not worth it: adding
/// `ClipPayload` and a couple of properties is an inferred lightweight
/// migration, and folding the old rows into the new shape is an idempotent
/// backfill in app code — see `PayloadBackfill`.
enum ClipSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [ClipItem.self, ClipPayload.self, ClipRepresentation.self]
    }
}

/// Folds v1's per-type rows into a single archive per clipping.
///
/// Idempotent and cheap to re-run: it only touches clippings that still have
/// legacy rows and no payload, so once the store is converted this is a single
/// empty fetch at launch. A clipping whose rows cannot be re-encoded keeps its
/// legacy rows rather than being emptied — losing the payload would leave a
/// card that pastes nothing.
enum PayloadBackfill {
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.payload == nil }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.legacyRepresentations]

        guard let candidates = try? context.fetch(descriptor), !candidates.isEmpty else {
            return 0
        }

        var converted = 0
        for item in candidates {
            let legacy = item.legacyRepresentations
            guard !legacy.isEmpty else { continue }

            let archive = ClipArchive(
                representations: legacy.map {
                    ClipArchive.Representation(typeIdentifier: $0.typeIdentifier, data: $0.data)
                }
            )
            guard let encoded = try? archive.encoded() else { continue }

            let payload = ClipPayload(archive: encoded)
            context.insert(payload)
            item.payload = payload
            legacy.forEach(context.delete)
            converted += 1
        }

        if converted > 0 { try? context.save() }
        return converted
    }
}
