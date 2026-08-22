//
//  MCPService.swift
//  paster
//
//  Created by yinminqian on 22/8/2026.
//

import Foundation
import Observation
import Security
import SwiftData

/// The MCP endpoint as a feature: off unless the user turned it on.
///
/// Off by default and gated on an explicit switch, because the thing being
/// exposed is every password reset link, address and half-written message the
/// user has copied this month. An integration like that is worth having, but
/// only as something someone chose — never as a default that ships enabled.
@MainActor
@Observable
final class MCPService {
    private let context: ModelContext
    private let paste: PasteService
    private let settings: AppSettings
    private var server: MCPServer?

    /// Mirrored from the server so a SwiftUI view actually sees it change.
    ///
    /// `MCPServer` is a plain object; observation lives here, in the one type a
    /// view holds. Without this the port-in-use failure — which `NWListener`
    /// reports asynchronously, after `start` returns — was written to a
    /// property nothing was watching, and Settings kept saying the endpoint was
    /// listening while no client could reach it.
    private(set) var state: MCPServer.State = .idle

    init(context: ModelContext, paste: PasteService, settings: AppSettings) {
        self.context = context
        self.paste = paste
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

    var endpointURL: String { "http://127.0.0.1:\(settings.mcpPort)\(MCPDispatcher.endpointPath)" }

    /// Brings the server into line with the settings.
    ///
    /// Idempotent, and called after every change to the switch, the port or the
    /// token — restarting on a token change matters, since the running listener
    /// captured the old one.
    func apply() {
        guard settings.mcpEnabled else {
            server?.stop()
            server = nil
            state = .idle
            return
        }

        guard !settings.mcpToken.isEmpty else {
            // No token means no authentication, and an unauthenticated clipboard
            // endpoint is not a thing to start on the user's behalf.
            server?.stop()
            server = nil
            state = .failed("No access token. Generate one to start the server.")
            return
        }

        let port = UInt16(clamping: settings.mcpPort)

        // Already serving that port: leave it alone. The dispatcher reads the
        // token per request, so regenerating one needs no restart at all — which
        // matters because a restart on the *same* port has to wait for the old
        // listener's cancellation, and the path a user actually takes is the
        // Regenerate button.
        if case .listening(port) = state, server != nil { return }

        guard let outgoing = server else { return start(on: port) }

        // Held until it confirms the port is free. Dropping it here and binding
        // immediately is the bug this replaced: the new listener failed with
        // "address already in use", the program holding the port being this one.
        server = nil
        retiring = outgoing
        outgoing.stop { [weak self] in
            guard let self else { return }
            self.retiring = nil
            self.start(on: port)
        }
    }

    private var retiring: MCPServer?

    private func start(on port: UInt16) {
        let context = self.context
        let paste = self.paste
        let settings = self.settings
        let server = MCPServer(
            onStateChange: { [weak self] state in
                MainActor.assumeIsolated { self?.state = state }
            },
            respond: { request in
                MainActor.assumeIsolated {
                    // Built per request, so the token is whatever it is *now*.
                    // Capturing one at start time is what made a regenerated
                    // token need a restart.
                    MCPDispatcher(context: context,
                                  paste: paste,
                                  token: settings.mcpToken)
                        .respond(to: request)
                }
            }
        )
        // Assigned before starting: `NWListener` can report `.failed`
        // synchronously on `start`, and the callback would then be writing a
        // state for a server this property does not yet point at.
        self.server = server
        server.start(port: port)
    }

    /// The line to paste into a terminal to register this endpoint.
    ///
    /// Given as a command rather than a JSON blob because that is the form that
    /// cannot be pasted into the wrong file.
    var claudeCodeCommand: String {
        """
        claude mcp add --transport http paster \(endpointURL) \
        --header "Authorization: Bearer \(settings.mcpToken)"
        """
    }

    /// Copies the setup command, stamped so it is never stored.
    ///
    /// It contains the bearer token. Written with a plain `setString` it would
    /// be picked up by the next poll and sit in the history as a searchable
    /// plain-text copy of the credential — which is the opposite of what a pane
    /// about access control should do.
    func copySetupCommand() {
        paste.copy(text: claudeCodeCommand)
    }

    // MARK: Token

    /// A fresh token, from the system's random source.
    ///
    /// `SecRandomCopyBytes` rather than anything seeded: this is the only thing
    /// standing between a local process and the user's clipboard history.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Refuse rather than fall back to a weaker source: a token the app
            // could not generate securely is worse than no server.
            return ""
        }
        return Data(bytes).base64EncodedString()
    }

    func regenerateToken() {
        settings.mcpToken = Self.generateToken()
        apply()
    }
}
