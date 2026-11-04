//
//  TerminalBridgeTests.swift
//  pasterTests
//

import AppKit
import Foundation
import Testing
@testable import paster

@MainActor
struct TerminalBridgeTests {

    private let snapshot = TerminalBridge.Snapshot(
        paths: ["/Users/me/Library/Application Support/CleanShot/media/a b@2x.png"],
        text: "第一行\nsecond line  "
    )

    private func request(method: String = "GET",
                         path: String = "/clipboard",
                         headers: [String: String] = ["host": "host.docker.internal:4258"]) -> MCPHTTPRequest {
        MCPHTTPRequest(method: method, path: path, headers: headers, body: Data())
    }

    private func call(_ request: MCPHTTPRequest) -> (MCPHTTPResponse, Bool) {
        var read = false
        let response = TerminalBridge.respond(to: request) {
            read = true
            return snapshot
        }
        return (response, read)
    }

    private func object(_ response: MCPHTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    @Test("A container caller gets the paths and the text, unaltered")
    func servesSnapshot() {
        let (response, read) = call(request())
        #expect(response.status == 200)
        #expect(read)
        let body = object(response)
        #expect(body["paths"] as? [String] == snapshot.paths)
        // Trailing whitespace and the newline survive: a terminal paste has to
        // be byte-for-byte what was copied.
        #expect(body["text"] as? String == snapshot.text)
    }

    @Test("Loopback names are accepted, with or without a port", arguments: [
        "127.0.0.1:4258", "localhost:4258", "LOCALHOST", "host.docker.internal",
    ])
    func acceptsLocalHosts(host: String) {
        #expect(call(request(headers: ["host": host])).0.status == 200)
    }

    @Test("Any other Host is refused before the pasteboard is read", arguments: [
        "evil.example:4258", "172.16.1.153:4258", "[::1]:4258", "",
    ])
    func refusesOtherHosts(host: String) {
        let (response, read) = call(request(headers: ["host": host]))
        #expect(response.status == 403)
        // Refused means not read, not read-and-discarded.
        #expect(!read)
    }

    @Test("A missing Host is refused")
    func refusesMissingHost() {
        let (response, read) = call(request(headers: [:]))
        #expect(response.status == 403)
        #expect(!read)
    }

    @Test("A request carrying Origin is refused, even from an allowed Host")
    func refusesOrigin() {
        // What a web page reaching loopback looks like: it cannot leave Origin off.
        let (response, read) = call(request(headers: ["host": "127.0.0.1:4258",
                                                      "origin": "https://evil.example"]))
        #expect(response.status == 403)
        #expect(!read)
    }

    @Test("Only GET /clipboard is served")
    func onlyGetClipboard() {
        #expect(call(request(path: "/mcp")).0.status == 404)
        #expect(call(request(method: "POST")).0.status == 405)
        #expect(!call(request(method: "POST")).1)
    }

    @Test("The live pasteboard is read as file paths plus plain text")
    func readsPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paster-terminal-bridge-test"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        let file = URL(fileURLWithPath: "/tmp/a b.png")
        pasteboard.writeObjects([file as NSURL])
        #expect(TerminalBridge.readPasteboard(pasteboard).paths == ["/tmp/a b.png"])

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        #expect(TerminalBridge.readPasteboard(pasteboard) == .init(paths: [], text: "hello"))
    }
}

@MainActor
struct TerminalBridgeSettingTests {
    @Test("The bridge is on by default")
    func onByDefault() {
        let suite = "paster-terminal-bridge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings(defaults: defaults).terminalBridgeEnabled)
    }
}
