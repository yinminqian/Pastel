//
//  MCPDispatcher.swift
//  paster
//
//  Created by yinminqian on 22/8/2026.
//

import Foundation
import SwiftData

/// One HTTP request, already framed.
struct MCPHTTPRequest {
    var method: String
    var path: String
    /// Keys lowercased, because HTTP field names are case-insensitive and
    /// comparing them as they arrived is a bug that only shows up with one
    /// particular client.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct MCPHTTPResponse {
    var status: Int
    var reason: String
    var contentType: String?
    var body: Data

    static func json(_ object: Any, status: Int = 200, reason: String = "OK") -> MCPHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return MCPHTTPResponse(status: status, reason: reason,
                              contentType: "application/json", body: data)
    }

    static func empty(status: Int, reason: String) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, reason: reason, contentType: nil, body: Data())
    }
}

/// Turns an HTTP request into a response. No sockets.
///
/// Split out from the listener so authentication, the origin check, the version
/// check and every JSON-RPC method are testable by value — which is the only way
/// to have confidence in an auth check that guards the user's clipboard.
///
/// Deliberately **stateless**: no session is minted and none is required. The
/// 2026-07-28 revision removed protocol-level sessions, and answering
/// `tools/list` without a prior `initialize` is what lets one implementation
/// serve both eras of client. `initialize` is still answered, because every
/// client shipping today opens with it.
@MainActor
struct MCPDispatcher {
    let context: ModelContext
    let paste: PasteService
    /// Compared against the `Authorization: Bearer` header.
    let token: String

    static let endpointPath = "/mcp"
    static let serverName = "paster"

    /// Newest first. Echoed back to a client that asks for one of these;
    /// anything else is refused with the list, which is what lets a client
    /// re-ask rather than guess.
    static let supportedProtocolVersions = ["2026-07-28", "2025-11-25",
                                            "2025-06-18", "2025-03-26"]
    /// What `initialize` answers when the client asks for something outside the
    /// list. The last revision with the handshake this method belongs to.
    static let fallbackProtocolVersion = "2025-06-18"

    // MARK: Entry point

    func respond(to request: MCPHTTPRequest) -> MCPHTTPResponse {
        // Origin first, before authentication and before the body is looked at.
        // A browser cannot be talked out of sending it, and a real MCP client
        // never does — so its presence means a web page is trying to reach a
        // server on the user's own machine, which is the DNS-rebinding attack
        // the spec requires this check for. 403, per the spec.
        if request.header("origin") != nil {
            return .json(Self.error(code: -32600, message: "Origin is not allowed."),
                         status: 403, reason: "Forbidden")
        }

        guard request.path == Self.endpointPath else {
            return .empty(status: 404, reason: "Not Found")
        }

        // GET and DELETE were the old transport's session and standalone-stream
        // mechanics. Neither exists here, and the spec names 405 as the answer.
        guard request.method == "POST" else {
            return .empty(status: 405, reason: "Method Not Allowed")
        }

        guard authorized(request) else {
            return MCPHTTPResponse(status: 401, reason: "Unauthorized",
                                   contentType: "application/json",
                                   body: Data(#"{"error":"Bearer token required."}"#.utf8))
        }

        // Absent means an older client: the header did not exist before
        // 2025-06-18, and the spec says to assume 2025-03-26 rather than refuse.
        if let version = request.header("mcp-protocol-version"),
           !Self.supportedProtocolVersions.contains(version) {
            return .json(Self.error(code: -32600,
                                    message: "Unsupported protocol version \(version).",
                                    data: ["supported": Self.supportedProtocolVersions]),
                         status: 400, reason: "Bad Request")
        }

        guard let message = try? JSONSerialization.jsonObject(with: request.body)
                as? [String: Any],
              let method = message["method"] as? String
        else {
            return .json(Self.error(code: -32700, message: "Parse error."),
                         status: 400, reason: "Bad Request")
        }

        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // A message with no id is a notification: 202 and no body, per the spec.
        // Every notification in the protocol is informational to a server this
        // small, so there is nothing to do beyond accepting it.
        guard let id else { return .empty(status: 202, reason: "Accepted") }

        // The modern revision mirrors two body fields into headers so
        // intermediaries can route without parsing. Validated when present
        // rather than demanded, because clients on the older revisions do not
        // send them — but a mismatch is refused, since a header and a body that
        // disagree is exactly the split-brain the mirroring rule exists to stop.
        if let mismatch = Self.headerMismatch(in: request, method: method, params: params) {
            return .json(Self.error(id: id, code: -32020, message: mismatch),
                         status: 400, reason: "Bad Request")
        }

        switch method {
        case "initialize":
            return .json(Self.result(id: id, initializeResult(params)))
        case "ping":
            return .json(Self.result(id: id, [:]))
        case "tools/list":
            return .json(Self.result(id: id, ["tools": MCPTools.declarations]))
        case "tools/call":
            return toolCall(id: id, params: params)
        default:
            // 404 with a JSON-RPC error body, which is how the current revision
            // distinguishes an unknown method from a URL that is not an MCP
            // endpoint at all.
            return .json(Self.error(id: id, code: -32601,
                                    message: "Method not found: \(method)"),
                         status: 404, reason: "Not Found")
        }
    }

    // MARK: Authentication

    private func authorized(_ request: MCPHTTPRequest) -> Bool {
        guard !token.isEmpty,
              let value = request.header("authorization"),
              value.hasPrefix("Bearer ")
        else { return false }
        let presented = String(value.dropFirst("Bearer ".count))
        // Constant-time-ish: compares every byte regardless of where the first
        // difference is. The window here is small, but a token check that
        // returns early on the first wrong byte is a habit not worth keeping.
        guard presented.utf8.count == token.utf8.count else { return false }
        return zip(presented.utf8, token.utf8).reduce(into: UInt8(0)) { $0 |= $1.0 ^ $1.1 } == 0
    }

    // MARK: Methods

    private func initializeResult(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap {
            Self.supportedProtocolVersions.contains($0) ? $0 : nil
        } ?? Self.fallbackProtocolVersion

        return [
            "protocolVersion": version,
            // Only tools. No resources, no prompts and no logging: declaring a
            // capability this server does not implement makes a client ask for
            // something that is not there.
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": [
                "name": Self.serverName,
                "version": Bundle.main
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "0",
            ],
            "instructions": """
            Local clipboard history for this Mac. Search or list clippings, read \
            one in full by id, or put something on the clipboard for the user to \
            paste. Clipboard history can contain anything the user has copied, \
            so treat results as sensitive and do not repeat them beyond what the \
            user asked for.
            """,
        ]
    }

    private func toolCall(id: Any, params: [String: Any]) -> MCPHTTPResponse {
        guard let name = params["name"] as? String else {
            return .json(Self.error(id: id, code: -32602, message: "tools/call needs a name."))
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let output = MCPTools.call(name, arguments: arguments,
                                   context: context, paste: paste)

        // A tool that failed reports it inside a successful JSON-RPC result with
        // `isError`, not as a JSON-RPC error: the distinction is the protocol's,
        // and it is what lets the model read the failure and try something else
        // instead of the client treating it as a transport fault.
        var result: [String: Any] = [
            "content": [["type": "text", "text": output.text]],
            "isError": output.isError,
        ]
        if let structured = output.structured { result["structuredContent"] = structured }
        return .json(Self.result(id: id, result))
    }

    // MARK: Envelopes

    private static func headerMismatch(in request: MCPHTTPRequest,
                                       method: String,
                                       params: [String: Any]) -> String? {
        if let mirrored = request.header("mcp-method"), mirrored != method {
            return "Mcp-Method header '\(mirrored)' does not match body method '\(method)'."
        }
        if let mirrored = request.header("mcp-name"),
           let name = params["name"] as? String,
           decoded(mirrored) != name {
            return "Mcp-Name header '\(mirrored)' does not match body name '\(name)'."
        }
        return nil
    }

    /// Unwraps the `=?base64?…?=` sentinel the transport uses for header values
    /// that cannot be plain ASCII.
    private static func decoded(_ value: String) -> String {
        let prefix = "=?base64?"
        let suffix = "?="
        guard value.hasPrefix(prefix), value.hasSuffix(suffix), value.count > prefix.count + suffix.count
        else { return value }
        let inner = value.dropFirst(prefix.count).dropLast(suffix.count)
        guard let data = Data(base64Encoded: String(inner)) else { return value }
        return String(decoding: data, as: UTF8.self)
    }

    static func result(id: Any, _ result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: Any? = nil,
                     code: Int,
                     message: String,
                     data: [String: Any]? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        // `NSNull` rather than omitting the key: JSON-RPC wants an id on every
        // error, and null is the value for "could not be determined".
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error]
    }
}
