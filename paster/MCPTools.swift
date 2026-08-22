//
//  MCPTools.swift
//  paster
//
//  Created by yinminqian on 22/8/2026.
//

import Foundation
import SwiftData

/// The clipboard as an MCP tool surface.
///
/// The three read-and-copy verbs are modelled on the clipboard MCP servers
/// people already run — `search_clipboard`, `get_recent_items`,
/// `copy_to_clipboard` is the shape `maccy-clipboard-mcp` established and the
/// one an agent will expect. `read_clipboard_item` is ours: the other two
/// return previews, and this app truncates previews at 500 characters, so
/// without it an agent asking for a long snippet would silently get a
/// fragment and no way to tell.
///
/// Kinds are the app's own, so a caller can filter on them without reading the
/// source. Nothing here returns payload bytes: an image clipping would be
/// megabytes of base64 through a JSON-RPC response for no benefit.
@MainActor
enum MCPTools {

    // MARK: Projections

    /// A clipping as it goes over the wire.
    ///
    /// A deliberate projection rather than the model: `ClipItem` is a SwiftData
    /// model bound to the main actor and its payload relationship would fault a
    /// blob per row. This is a value with only the fields a caller can act on.
    struct Clipping: Encodable {
        var id: String
        var kind: String
        var preview: String?
        var previewTruncated: Bool
        var copiedAt: String
        var sourceApp: String?
        var fromOtherDevice: Bool
        var pinned: Bool
        var size: String?

        @MainActor
        init(_ item: ClipItem) {
            // The fingerprint, not the persistent identifier: it is already
            // unique, it is stable across a store migration, and it is the same
            // string the dedup path uses, so a caller can hold onto one.
            self.id = item.fingerprint
            self.kind = item.kind.rawValue
            self.preview = item.previewText
            self.previewTruncated = (item.previewText?.count ?? 0) < item.contentLength
            self.copiedAt = item.copiedAt.formatted(.iso8601)
            self.sourceApp = item.isFromRemoteDevice ? nil : item.sourceBundleID
            self.fromOtherDevice = item.isFromRemoteDevice
            self.pinned = item.isPinned
            self.size = item.lengthSummary
        }
    }

    // MARK: Declarations

    static let maximumLimit = 100
    static let defaultLimit = 20

    /// The `tools/list` payload.
    ///
    /// Descriptions are written for a model that has no other context: each one
    /// says what comes back and what does not, because a tool an agent has to
    /// guess at is a tool it calls three times to find out.
    static var declarations: [[String: Any]] {
        [
            [
                "name": "search_clipboard",
                "description": """
                Search this Mac's clipboard history by text. Matches the stored \
                preview, case-insensitively. Returns newest first. Previews are \
                truncated; use read_clipboard_item for a full value.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Text to look for in the clipping.",
                        ],
                        "limit": limitSchema,
                        "kind": kindSchema,
                    ],
                    "required": ["query"],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "get_recent_items",
                "description": """
                List the most recent clippings, newest first. Pinned clippings \
                are included in date order, not moved to the front.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": ["limit": limitSchema, "kind": kindSchema],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "read_clipboard_item",
                "description": """
                Read one clipping in full by its id. Returns the complete text \
                for text, rich text and link clippings, and metadata only for \
                images, files and binary data — payload bytes are never returned.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "An id from a previous result."],
                    ],
                    "required": ["id"],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "copy_to_clipboard",
                "description": """
                Put something on this Mac's clipboard, ready for the user to \
                paste. Give either id, to restore a stored clipping with all its \
                formats, or text, to copy a literal string. Nothing is typed \
                into any app.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "A clipping to restore."],
                        "text": ["type": "string", "description": "Literal text to copy."],
                    ],
                ],
                // Not read-only and not idempotent: it replaces whatever the
                // user had on their clipboard, which they cannot get back if it
                // was never captured.
                "annotations": ["readOnlyHint": false, "idempotentHint": false],
            ],
        ]
    }

    private static var limitSchema: [String: Any] {
        [
            "type": "integer",
            "minimum": 1,
            "maximum": maximumLimit,
            "description": "How many to return. Defaults to \(defaultLimit).",
        ]
    }

    private static var kindSchema: [String: Any] {
        [
            "type": "string",
            "enum": ClipKind.allCases.map(\.rawValue),
            "description": "Restrict to one kind of clipping.",
        ]
    }

    // MARK: Execution

    /// What a tool produced: text for the model, plus the same thing structured.
    struct Output {
        var text: String
        var structured: Any?
        var isError: Bool = false
    }

    static func call(_ name: String,
                     arguments: [String: Any],
                     context: ModelContext,
                     paste: PasteService) -> Output {
        switch name {
        case "search_clipboard": return search(arguments, context: context)
        case "get_recent_items": return recent(arguments, context: context)
        case "read_clipboard_item": return read(arguments, context: context)
        case "copy_to_clipboard": return copy(arguments, context: context, paste: paste)
        default: return Output(text: "Unknown tool \(name).", isError: true)
        }
    }

    private static func search(_ arguments: [String: Any],
                               context: ModelContext) -> Output {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return Output(text: "search_clipboard needs a non-empty query.", isError: true)
        }
        // Filtered in memory rather than with a `#Predicate` on `localized
        // CaseInsensitiveContains`, which SwiftData cannot translate to SQL.
        // The history is capped in the hundreds, so this is a linear scan over
        // a list that fits in a cache line's worth of pages.
        let matches = fetch(kind: kind(from: arguments), context: context)
            .filter { $0.previewText?.localizedCaseInsensitiveContains(query) ?? false }
        return list(Array(matches.prefix(limit(from: arguments))),
                    describing: "matching \"\(query)\"")
    }

    private static func recent(_ arguments: [String: Any],
                               context: ModelContext) -> Output {
        list(Array(fetch(kind: kind(from: arguments), context: context)
                    .prefix(limit(from: arguments))),
             describing: "most recent")
    }

    private static func read(_ arguments: [String: Any],
                             context: ModelContext) -> Output {
        guard let id = arguments["id"] as? String else {
            return Output(text: "read_clipboard_item needs an id.", isError: true)
        }
        guard let item = item(id: id, context: context) else {
            return Output(text: "No clipping with id \(id). It may have been pruned.",
                          isError: true)
        }

        var payload: [String: Any] = [
            "clipping": dictionary(from: Clipping(item)),
            "formats": item.representations.map(\.typeIdentifier),
        ]
        if let text = plainText(of: item) {
            payload["text"] = text
        } else {
            payload["note"] = "This clipping has no text form; its bytes are not returned."
        }
        return Output(text: json(payload), structured: payload)
    }

    private static func copy(_ arguments: [String: Any],
                             context: ModelContext,
                             paste: PasteService) -> Output {
        // Both branches stamp the write as ours, so the poller does not record
        // it as something the user copied. An agent's own output appearing in
        // the history attributed to whatever app happened to be frontmost would
        // be worse than not appearing at all.
        if let id = arguments["id"] as? String {
            guard let item = item(id: id, context: context) else {
                return Output(text: "No clipping with id \(id).", isError: true)
            }
            paste.copy(item)
            let summary = ["copied": dictionary(from: Clipping(item))]
            return Output(text: json(summary), structured: summary)
        }
        if let text = arguments["text"] as? String {
            paste.copy(text: text)
            let summary: [String: Any] = ["copied": ["kind": "text",
                                                     "characters": text.count]]
            return Output(text: json(summary), structured: summary)
        }
        return Output(text: "copy_to_clipboard needs either id or text.", isError: true)
    }

    // MARK: Helpers

    private static func fetch(kind: ClipKind?, context: ModelContext) -> [ClipItem] {
        var descriptor = FetchDescriptor<ClipItem>(
            sortBy: [SortDescriptor(\.copiedAt, order: .reverse)]
        )
        if let kind {
            let raw = kind.rawValue
            descriptor.predicate = #Predicate { $0.kind.rawValue == raw }
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func item(id: String, context: ModelContext) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.fingerprint == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The plain-text flavour, whatever the clipping mainly is.
    ///
    /// Rich text and links both carry one, and it is what a caller actually
    /// wants: an agent asked to read a clipping wants the words, not RTF.
    private static func plainText(of item: ClipItem) -> String? {
        let preferred = ["public.utf8-plain-text", "public.text"]
        for identifier in preferred {
            if let data = item.representations.first(where: { $0.typeIdentifier == identifier })?.data,
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    private static func limit(from arguments: [String: Any]) -> Int {
        // Clamped rather than rejected: a caller asking for 5000 wants "as many
        // as you have", and failing the call teaches it nothing.
        guard let raw = arguments["limit"] as? Int else { return defaultLimit }
        return min(max(raw, 1), maximumLimit)
    }

    private static func kind(from arguments: [String: Any]) -> ClipKind? {
        (arguments["kind"] as? String).flatMap(ClipKind.init(rawValue:))
    }

    private static func list(_ items: [ClipItem], describing what: String) -> Output {
        let payload: [String: Any] = [
            "count": items.count,
            "clippings": items.map { dictionary(from: Clipping($0)) },
        ]
        guard !items.isEmpty else {
            return Output(text: "No clippings \(what).", structured: payload)
        }
        return Output(text: json(payload), structured: payload)
    }

    /// Round-trips the projection through `JSONEncoder` so the field names and
    /// the JSON are defined in exactly one place.
    private static func dictionary(from clipping: Clipping) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(clipping),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
