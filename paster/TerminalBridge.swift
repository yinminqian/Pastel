//
//  TerminalBridge.swift
//  paster
//
//  Created by yinminqian on 4/11/2026.
//

import AppKit
import Foundation
import Observation

/// The current clipboard, read-only, on loopback — for terminals that cannot
/// read it themselves.
///
/// The case it exists for: a Rex session whose server runs in a container. Rex
/// hands ⌘V to the session's server, and a server in a container has no way to
/// read this Mac's pasteboard, so text pastes nothing and a screenshot — which
/// arrives as a file URL plus PNG, with no plain text at all — pastes nothing
/// either. The container's Rex config asks this endpoint instead and pastes the
/// file paths (the screenshot folder is mounted at the same path) or the text.
///
/// `GET /clipboard` → `{"paths": [...], "text": "..."}`. Nothing else.
///
/// What it is worth, stated so nobody has to guess: it serves exactly what
/// `pbpaste` gives any process running as this user, so it does not widen what
/// local code can read. What it must not do is widen it to a web page, so it
/// takes the MCP endpoint's defences — loopback only, a request carrying an
/// `Origin` header refused outright, and a `Host` that is not one of the names
/// a local caller uses refused too, which is what stops DNS rebinding. It never
/// reads the history and never writes the clipboard.
enum TerminalBridge {
    /// Next to the MCP endpoint's 4257, and fixed rather than configurable: the
    /// container side hard-codes it, and a port that can drift is a paste that
    /// silently stops working.
    static let port: UInt16 = 4258
    static let path = "/clipboard"

    /// The names a legitimate caller puts in `Host`. `host.docker.internal` is
    /// how a container reaches this Mac's loopback (OrbStack and Docker Desktop
    /// both forward it there). Anything else — notably an attacker's domain
    /// rebound to 127.0.0.1 — is refused.
    static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "host.docker.internal"]

    struct Snapshot: Equatable {
        var paths: [String]
        var text: String
    }

    /// Pure apart from `read`, so the access rules are testable without a
    /// pasteboard or a socket.
    static func respond(to request: MCPHTTPRequest, read: () -> Snapshot) -> MCPHTTPResponse {
        guard request.path == path else {
            return .json(["error": "Not found."], status: 404, reason: "Not Found")
        }
        guard request.method == "GET" else {
            return .json(["error": "Only GET."], status: 405, reason: "Method Not Allowed")
        }
        // A browser cannot send a request without `Origin` on a cross-origin
        // fetch, and nothing that legitimately calls this sends one.
        guard request.header("origin") == nil else {
            return .json(["error": "Requests with an Origin header are refused."],
                         status: 403, reason: "Forbidden")
        }
        guard let host = request.header("host").map(hostName), allowedHosts.contains(host) else {
            return .json(["error": "Host not allowed."], status: 403, reason: "Forbidden")
        }
        let snapshot = read()
        return .json(["paths": snapshot.paths, "text": snapshot.text])
    }

    /// The host part of a `Host` header, lowercased, without the port.
    static func hostName(_ header: String) -> String {
        let value = header.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("[") {
            // An IPv6 literal, `[::1]:4258`. Not in the allowlist, but parsed
            // properly so it is refused for being IPv6 rather than by accident.
            return String(value.prefix { $0 != "]" }.dropFirst())
        }
        return String(value.split(separator: ":", maxSplits: 1).first ?? "")
    }

    /// The live pasteboard, not the history: every file URL on it, as a path,
    /// and its plain-text flavour.
    @MainActor
    static func readPasteboard(_ pasteboard: NSPasteboard = .general) -> Snapshot {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return Snapshot(paths: urls.map(\.path),
                        text: pasteboard.string(forType: .string) ?? "")
    }
}

/// The bridge as a feature: on unless the user turned it off.
@MainActor
@Observable
final class TerminalBridgeService {
    private let settings: AppSettings
    private var server: MCPServer?
    /// A listener being shut down. Held until it reports the port free, because
    /// turning the switch off and on again in quick succession would otherwise
    /// bind a new listener to a port the old one still holds.
    private var retiring: MCPServer?

    private(set) var state: MCPServer.State = .idle

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isRunning: Bool {
        if case .listening = state { return true }
        return false
    }

    var failure: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    var endpointURL: String { "http://127.0.0.1:\(TerminalBridge.port)\(TerminalBridge.path)" }

    /// Brings the listener into line with the switch. Idempotent.
    func apply() {
        guard settings.terminalBridgeEnabled else {
            guard let outgoing = server else { return }
            server = nil
            retiring = outgoing
            outgoing.stop { [weak self] in
                guard let self else { return }
                self.retiring = nil
                // The switch may have gone back on while the port was freeing.
                self.apply()
            }
            return
        }
        guard server == nil, retiring == nil else { return }

        let server = MCPServer(
            onStateChange: { [weak self] state in
                MainActor.assumeIsolated { self?.state = state }
            },
            respond: { request in
                MainActor.assumeIsolated {
                    TerminalBridge.respond(to: request) { TerminalBridge.readPasteboard() }
                }
            }
        )
        // Assigned before starting, for the same reason as in `MCPService`: a
        // synchronous `.failed` would otherwise report for a server this
        // property does not yet hold.
        self.server = server
        server.start(port: TerminalBridge.port)
    }
}
