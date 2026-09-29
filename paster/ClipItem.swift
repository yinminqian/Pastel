//
//  ClipItem.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

/// What a clipping mainly is, chosen from the representations it carries.
/// Used for card layout, so it is stored rather than computed — computed
/// properties cannot appear in predicates if this ever needs filtering.
enum ClipKind: String, Codable, CaseIterable {
    case text
    case richText
    case image
    case fileURL
    /// Plain text that is a single URL. Its own kind because a link wants an
    /// entirely different card — the host read large, the path small — rather
    /// than a line of wrapped monospace.
    case link
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

    /// Characters for text-like clippings, bytes for binary ones — the kind
    /// tells them apart, so one field does for both.
    ///
    /// Stored rather than counted from `previewText`, which is truncated at 500
    /// characters: counting the preview would confidently report "500
    /// characters" for anything longer, which is worse than showing nothing.
    var contentLength: Int = 0

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

    /// Kept regardless of the history limit or the age limit.
    ///
    /// A pin is a promise, so it has to win over *both* retention axes — a pin
    /// that survives the row cap but quietly expires after thirty days is worse
    /// than no pin at all. Pinned rows are also excluded from the count the
    /// limit is compared against, so pinning does not evict unpinned history.
    ///
    /// Survives a repeat copy: dedup fetches the existing row by fingerprint
    /// and only moves its timestamp, rather than replacing it.
    var isPinned: Bool = false

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
         contentLength: Int = 0,
         thumbnailData: Data? = nil,
         sourceBundleID: String? = nil,
         isFromRemoteDevice: Bool = false) {
        self.copiedAt = copiedAt
        self.kind = kind
        self.fingerprint = fingerprint
        self.previewText = previewText
        self.contentLength = contentLength
        self.thumbnailData = thumbnailData
        self.sourceBundleID = sourceBundleID
        self.isFromRemoteDevice = isFromRemoteDevice
    }

    /// The kind spelled out.
    ///
    /// A word rather than a glyph: at this size a label reads instantly and
    /// unambiguously, where a symbol has to be learned, and the metadata band
    /// is already carrying the app icon as its one piece of imagery.
    var kindLabel: String {
        switch kind {
        case .text: String(localized: "Text")
        case .richText: String(localized: "Rich Text")
        case .image: String(localized: "Image")
        case .fileURL: isImageFile ? String(localized: "Image") : String(localized: "File")
        case .link: String(localized: "Link")
        case .other: String(localized: "Data")
        }
    }

    /// The copied file, when this clipping is one.
    var fileURL: URL? {
        guard kind == .fileURL, let text = previewText,
              let url = URL(string: text), url.isFileURL
        else { return nil }
        return url
    }

    /// A copied file that is a picture — what a screenshot tool puts on the
    /// clipboard. Labelled an image, since that is what the user copied.
    var isImageFile: Bool {
        guard let url = fileURL,
              let type = UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .image)
    }

    /// A concrete datum for the card's footer.
    ///
    /// Deliberately a measurement rather than decoration — it is the kind of
    /// detail that makes a card read as a tool rather than as a mockup, and it
    /// is genuinely useful when deciding between two similar clippings.
    var lengthSummary: String? {
        guard contentLength > 0 else { return nil }
        switch kind {
        case .text, .richText, .link:
            return String(localized: "\(contentLength) characters")
        case .image, .fileURL, .other:
            return contentLength.formatted(.byteCount(style: .file))
        }
    }

    /// The stored representations in plain language, for the detail pane.
    ///
    /// Concrete and occasionally load-bearing: knowing a clipping still carries
    /// its RTF is the difference between pasting it into a document and pasting
    /// it as plain text on purpose.
    var formatSummary: String? {
        let names: [String: String] = [
            "public.utf8-plain-text": "plain text",
            "public.utf16-plain-text": "plain text",
            "public.text": "plain text",
            "public.rtf": "RTF",
            // The real identifier for RTFD; `public.rtfd` does not exist.
            "com.apple.flat-rtfd": "RTF",
            "public.html": "HTML",
            "public.png": "PNG",
            "public.tiff": "TIFF",
            "public.file-url": "file",
            "public.url": "URL",
        ]
        var seen: [String] = []
        for representation in representations {
            guard let name = names[representation.typeIdentifier],
                  !seen.contains(name) else { continue }
            seen.append(name)
        }
        return seen.isEmpty ? nil : seen.joined(separator: ", ")
    }

    /// Whether the preview should be rendered monospaced.
    ///
    /// Derived rather than stored, and deliberately a narrow test: a line that
    /// begins with indentation is a line where whitespace carries meaning, so
    /// the text is code, a diff, or tabular output. Guessing from punctuation
    /// density would mono-space ordinary prose that happens to contain
    /// brackets.
    var prefersMonospacedPreview: Bool {
        guard let text = previewText, text.contains("\n") else { return false }
        return text.split(separator: "\n", omittingEmptySubsequences: true).contains {
            $0.hasPrefix("  ") || $0.hasPrefix("\t")
        }
    }

    /// The URL this clipping is, when it is one.
    var linkURL: URL? {
        guard kind == .link, let text = previewText else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
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
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
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
    /// - Returns: the number of clippings changed. Counted per item, not per
    ///   field: an item needing both the payload fold and the length is one
    ///   conversion, and callers use this to decide whether to save.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.payload == nil || $0.contentLength == 0 }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.legacyRepresentations]

        guard let candidates = try? context.fetch(descriptor), !candidates.isEmpty else {
            return 0
        }

        var changed = 0
        for item in candidates {
            var touched = false

            // Fold first: computing the length reads the payload.
            if item.payload == nil {
                let legacy = item.legacyRepresentations
                if !legacy.isEmpty,
                   let encoded = try? ClipArchive(
                       representations: legacy.map {
                           ClipArchive.Representation(typeIdentifier: $0.typeIdentifier,
                                                      data: $0.data)
                       }
                   ).encoded() {
                    let payload = ClipPayload(archive: encoded)
                    context.insert(payload)
                    item.payload = payload
                    legacy.forEach(context.delete)
                    touched = true
                }
            }

            if item.contentLength == 0 {
                item.contentLength = length(of: item)
                if item.contentLength > 0 { touched = true }
            }

            if touched { changed += 1 }
        }

        if changed > 0 { try? context.save() }
        return changed
    }

    /// Characters for text-like clippings, bytes for binary ones.
    static func length(of item: ClipItem) -> Int {
        switch item.kind {
        case .text, .richText, .link:
            let plain = item.representations.first {
                $0.typeIdentifier == "public.utf8-plain-text"
            }
            guard let data = plain?.data, let text = String(data: data, encoding: .utf8) else {
                return 0
            }
            return text.count
        case .image, .fileURL, .other:
            return item.representations.reduce(0) { $0 + $1.data.count }
        }
    }
}
