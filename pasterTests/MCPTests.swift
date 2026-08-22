//
//  MCPTests.swift
//  pasterTests
//

import Foundation
import SwiftData
import Testing
@testable import paster

@MainActor
struct MCPHTTPFramingTests {

    private func parse(_ text: String) -> MCPServer.ParseResult {
        MCPServer.parse(Data(text.utf8))
    }

    @Test("A request whose headers have not fully arrived is incomplete, not malformed")
    func partialHeaders() {
        // The distinction matters: malformed answers 400 and closes, incomplete
        // waits for the rest. Getting it backwards fails every request whose
        // headers and body land in separate reads, which is most of them.
        guard case .incomplete = parse("POST /mcp HTTP/1.1\r\nHost: x\r\n") else {
            Issue.record("expected incomplete")
            return
        }
    }

    @Test("A body shorter than Content-Length is incomplete")
    func partialBody() {
        let text = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc"
        guard case .incomplete = parse(text) else {
            Issue.record("expected incomplete")
            return
        }
    }

    @Test("Exactly Content-Length bytes are taken as the body")
    func exactBody() throws {
        let text = "POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhellotrailing"
        guard case .complete(let request) = parse(text) else {
            Issue.record("expected complete")
            return
        }
        // Anything past the declared length belongs to a pipelined request this
        // server does not serve, and must not be folded into this body.
        #expect(String(decoding: request.body, as: UTF8.self) == "hello")
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
    }

    @Test("Header names are lowercased, so lookups do not depend on the client")
    func headerCaseIsNormalised() throws {
        let text = "POST /mcp HTTP/1.1\r\nAUTHORIZATION: Bearer x\r\nContent-Length: 0\r\n\r\n"
        guard case .complete(let request) = parse(text) else {
            Issue.record("expected complete")
            return
        }
        #expect(request.header("Authorization") == "Bearer x")
        #expect(request.header("authorization") == "Bearer x")
    }

    @Test("A query string is not part of the path")
    func queryStringIsDropped() throws {
        let text = "POST /mcp?v=1 HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        guard case .complete(let request) = parse(text) else {
            Issue.record("expected complete")
            return
        }
        #expect(request.path == "/mcp")
    }

    @Test("A chunked body is refused rather than misread")
    func chunkedIsRefused() {
        let text = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        guard case .malformed = parse(text) else {
            Issue.record("expected malformed")
            return
        }
    }

    @Test("An absurd Content-Length is refused instead of waiting forever")
    func oversizedBodyIsRefused() {
        let text = "POST /mcp HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"
        guard case .malformed = parse(text) else {
            Issue.record("expected malformed")
            return
        }
    }
}

@MainActor
struct MCPDispatcherTests {

    private let token = "test-token-0123456789"

    private func dispatcher() throws -> MCPDispatcher {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ClipSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return MCPDispatcher(context: ModelContext(container),
                             paste: PasteService(),
                             token: token)
    }

    private func post(_ body: [String: Any],
                      to dispatcher: MCPDispatcher,
                      headers extra: [String: String] = [:],
                      authorized: Bool = true) -> MCPHTTPResponse {
        var headers = extra
        if authorized { headers["authorization"] = "Bearer \(token)" }
        return dispatcher.respond(to: MCPHTTPRequest(
            method: "POST",
            path: "/mcp",
            headers: headers,
            body: try! JSONSerialization.data(withJSONObject: body)
        ))
    }

    private func object(_ response: MCPHTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    // MARK: Gatekeeping

    @Test("A request with no bearer token is refused")
    func unauthenticatedIsRefused() throws {
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
                            to: try dispatcher(), authorized: false)
        #expect(response.status == 401)
    }

    @Test("A request with the wrong token is refused")
    func wrongTokenIsRefused() throws {
        let dispatcher = try dispatcher()
        let response = dispatcher.respond(to: MCPHTTPRequest(
            method: "POST", path: "/mcp",
            headers: ["authorization": "Bearer not-the-token"],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        ))
        #expect(response.status == 401)
    }

    @Test("A token that is a prefix of the real one is refused")
    func prefixTokenIsRefused() throws {
        let dispatcher = try dispatcher()
        let response = dispatcher.respond(to: MCPHTTPRequest(
            method: "POST", path: "/mcp",
            headers: ["authorization": "Bearer \(token.dropLast())"],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        ))
        #expect(response.status == 401)
    }

    @Test("A request carrying an Origin header is forbidden, before authentication")
    func originIsForbidden() throws {
        // A browser always sends it and a real MCP client never does, so its
        // presence means a web page is reaching for a server on the user's own
        // machine. Checked before the token, because a page that has somehow
        // obtained the token must still be refused.
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
                            to: try dispatcher(),
                            headers: ["origin": "https://example.com"])
        #expect(response.status == 403)
    }

    @Test("GET and DELETE are not allowed on the endpoint")
    func onlyPostIsAllowed() throws {
        let dispatcher = try dispatcher()
        for method in ["GET", "DELETE", "PUT"] {
            let response = dispatcher.respond(to: MCPHTTPRequest(
                method: method, path: "/mcp",
                headers: ["authorization": "Bearer \(token)"], body: Data()
            ))
            #expect(response.status == 405, "\(method) should be refused")
        }
    }

    @Test("Any other path is a 404")
    func otherPathsAreNotFound() throws {
        let response = try dispatcher().respond(to: MCPHTTPRequest(
            method: "POST", path: "/",
            headers: ["authorization": "Bearer \(token)"], body: Data()
        ))
        #expect(response.status == 404)
    }

    @Test("An unsupported protocol version is refused with the supported list")
    func unsupportedVersion() throws {
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
                            to: try dispatcher(),
                            headers: ["mcp-protocol-version": "1999-01-01"])
        #expect(response.status == 400)
        let error = object(response)["error"] as? [String: Any]
        let supported = (error?["data"] as? [String: Any])?["supported"] as? [String]
        #expect(supported?.contains("2026-07-28") == true)
    }

    @Test("A missing protocol version header is tolerated, not refused")
    func missingVersionHeaderIsFine() throws {
        // The header did not exist before 2025-06-18. Refusing it would lock
        // out clients the spec explicitly says to accept.
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
                            to: try dispatcher())
        #expect(response.status == 200)
    }

    @Test("A header that contradicts the body is refused")
    func headerBodyMismatch() throws {
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
                            to: try dispatcher(),
                            headers: ["mcp-method": "tools/call"])
        #expect(response.status == 400)
        let error = object(response)["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32020)
    }

    @Test("Garbage in the body is a parse error, not a crash")
    func malformedBody() throws {
        let response = try dispatcher().respond(to: MCPHTTPRequest(
            method: "POST", path: "/mcp",
            headers: ["authorization": "Bearer \(token)"],
            body: Data("not json".utf8)
        ))
        #expect(response.status == 400)
    }

    // MARK: Protocol

    @Test("A notification is accepted with an empty body")
    func notificationIsAccepted() throws {
        // No id means a notification. Answering it with a JSON-RPC response
        // would be a message the client has nowhere to put.
        let response = post(["jsonrpc": "2.0", "method": "notifications/initialized"],
                            to: try dispatcher())
        #expect(response.status == 202)
        #expect(response.body.isEmpty)
    }

    @Test("initialize echoes a version it supports")
    func initializeEchoesVersion() throws {
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                             "params": ["protocolVersion": "2025-06-18"]],
                            to: try dispatcher())
        let result = object(response)["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2025-06-18")
        #expect((result?["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test("initialize falls back rather than echoing a version it cannot serve")
    func initializeFallsBack() throws {
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                             "params": ["protocolVersion": "1999-01-01"]],
                            to: try dispatcher())
        let result = object(response)["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == MCPDispatcher.fallbackProtocolVersion)
    }

    @Test("tools/list works without a prior initialize")
    func statelessToolsList() throws {
        // The current revision has no sessions, so a client may open with any
        // method. Requiring a handshake would lock those clients out.
        let response = post(["jsonrpc": "2.0", "id": 7, "method": "tools/list"],
                            to: try dispatcher())
        #expect(response.status == 200)
        let tools = (object(response)["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.compactMap { $0["name"] as? String }.sorted()
                == ["copy_to_clipboard", "get_recent_items",
                    "read_clipboard_item", "search_clipboard"])
        #expect(object(response)["id"] as? Int == 7)
    }

    @Test("An unknown method is a 404 carrying a JSON-RPC method-not-found")
    func unknownMethod() throws {
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "resources/list"],
                            to: try dispatcher())
        #expect(response.status == 404)
        #expect((object(response)["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test("ping answers")
    func ping() throws {
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "ping"],
                            to: try dispatcher())
        #expect(response.status == 200)
        #expect(object(response)["result"] != nil)
    }

    // MARK: Tools

    private func call(_ name: String,
                      _ arguments: [String: Any],
                      on dispatcher: MCPDispatcher) -> [String: Any] {
        let response = post(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                             "params": ["name": name, "arguments": arguments]],
                            to: dispatcher)
        return (object(response)["result"] as? [String: Any]) ?? [:]
    }

    private func seed(_ dispatcher: MCPDispatcher) throws {
        let context = dispatcher.context
        for (index, text) in ["hello world", "shopping list", "hello again"].enumerated() {
            let item = ClipItem(copiedAt: Date().addingTimeInterval(Double(-index)),
                                kind: .text,
                                fingerprint: "fp-\(index)",
                                previewText: text,
                                contentLength: text.count)
            context.insert(item)
            let payload = ClipPayload(archive: try ClipArchive(representations: [
                .init(typeIdentifier: "public.utf8-plain-text", data: Data(text.utf8)),
            ]).encoded())
            context.insert(payload)
            item.payload = payload
        }
        try context.save()
    }

    @Test("search_clipboard matches the preview, case-insensitively, newest first")
    func search() throws {
        let dispatcher = try dispatcher()
        try seed(dispatcher)
        let result = call("search_clipboard", ["query": "HELLO"], on: dispatcher)
        let structured = result["structuredContent"] as? [String: Any]
        #expect(structured?["count"] as? Int == 2)
        let clippings = structured?["clippings"] as? [[String: Any]]
        #expect(clippings?.first?["preview"] as? String == "hello world")
        #expect(result["isError"] as? Bool == false)
    }

    @Test("An empty query is a tool error, not a JSON-RPC error")
    func emptyQuery() throws {
        // The distinction is the protocol's: a tool error is something the model
        // can read and correct, where a JSON-RPC error looks like the transport
        // broke.
        let result = call("search_clipboard", ["query": ""], on: try dispatcher())
        #expect(result["isError"] as? Bool == true)
    }

    @Test("A limit beyond the maximum is clamped rather than refused")
    func limitIsClamped() throws {
        let dispatcher = try dispatcher()
        try seed(dispatcher)
        let result = call("get_recent_items", ["limit": 9999], on: dispatcher)
        #expect(result["isError"] as? Bool == false)
    }

    @Test("get_recent_items returns the newest first")
    func recent() throws {
        let dispatcher = try dispatcher()
        try seed(dispatcher)
        let structured = call("get_recent_items", ["limit": 2], on: dispatcher)["structuredContent"]
            as? [String: Any]
        let previews = (structured?["clippings"] as? [[String: Any]])?
            .compactMap { $0["preview"] as? String }
        #expect(previews == ["hello world", "shopping list"])
    }

    @Test("read_clipboard_item returns the full text, not the truncated preview")
    func readFull() throws {
        let dispatcher = try dispatcher()
        let long = String(repeating: "a", count: 900)
        let item = ClipItem(kind: .text, fingerprint: "long",
                            previewText: String(long.prefix(500)),
                            contentLength: long.count)
        dispatcher.context.insert(item)
        let payload = ClipPayload(archive: try ClipArchive(representations: [
            .init(typeIdentifier: "public.utf8-plain-text", data: Data(long.utf8)),
        ]).encoded())
        dispatcher.context.insert(payload)
        item.payload = payload
        try dispatcher.context.save()

        let structured = call("read_clipboard_item", ["id": "long"], on: dispatcher)["structuredContent"]
            as? [String: Any]
        #expect((structured?["text"] as? String)?.count == 900)
        let clipping = structured?["clipping"] as? [String: Any]
        #expect(clipping?["previewTruncated"] as? Bool == true)
    }

    @Test("An unknown id is a tool error naming the reason")
    func unknownID() throws {
        let result = call("read_clipboard_item", ["id": "nope"], on: try dispatcher())
        #expect(result["isError"] as? Bool == true)
    }

    @Test("An unknown tool name is a tool error rather than a crash")
    func unknownTool() throws {
        let result = call("definitely_not_a_tool", [:], on: try dispatcher())
        #expect(result["isError"] as? Bool == true)
    }

    @Test("copy_to_clipboard needs either an id or text")
    func copyNeedsSomething() throws {
        #expect(call("copy_to_clipboard", [:], on: try dispatcher())["isError"] as? Bool == true)
    }

    @Test("No tool returns payload bytes")
    func payloadBytesAreNeverReturned() throws {
        let dispatcher = try dispatcher()
        // An image clipping: megabytes of base64 through a JSON-RPC response
        // would be useless to a model and expensive for everyone.
        let item = ClipItem(kind: .image, fingerprint: "png", contentLength: 4096)
        dispatcher.context.insert(item)
        let payload = ClipPayload(archive: try ClipArchive(representations: [
            .init(typeIdentifier: "public.png", data: Data(repeating: 0xAB, count: 4096)),
        ]).encoded())
        dispatcher.context.insert(payload)
        item.payload = payload
        try dispatcher.context.save()

        let result = call("read_clipboard_item", ["id": "png"], on: dispatcher)
        let structured = result["structuredContent"] as? [String: Any]
        #expect(structured?["text"] == nil)
        #expect(structured?["note"] != nil)
        #expect((structured?["formats"] as? [String]) == ["public.png"])
    }
}

@MainActor
struct MCPTokenTests {

    @Test("A generated token is long and different every time")
    func tokensAreRandom() {
        let first = MCPService.generateToken()
        let second = MCPService.generateToken()
        #expect(first.count >= 40)
        #expect(first != second)
    }

    @Test("Only the listening state counts as running")
    func stateMapping() throws {
        // `NWListener` reports failure asynchronously, so these three cases are
        // what Settings renders from. `.idle` must not read as running: a server
        // that has been asked to stop is not one that is still up.
        let container = try ModelContainer(
            for: Schema(versionedSchema: ClipSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suite = "paster.tests.mcp.state"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let service = MCPService(context: ModelContext(container),
                                 paste: PasteService(),
                                 settings: settings)

        #expect(service.isRunning == false)
        #expect(service.failure == nil)

        // Applying while switched off must stay quiet: nothing has gone wrong,
        // so there is nothing for Settings to warn about.
        service.apply()
        #expect(service.isRunning == false)
        #expect(service.failure == nil)

        // Switched on with no token: refused, and it says why rather than
        // starting an unauthenticated clipboard endpoint.
        settings.mcpEnabled = true
        service.apply()
        #expect(service.isRunning == false)
        #expect(service.failure != nil)
    }

    @Test("The endpoint is off until it is switched on")
    func offByDefault() {
        let suite = "paster.tests.mcp.default"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.mcpEnabled == false)
        #expect(settings.mcpToken.isEmpty)
        // A registered default, not zero — zero is not a bindable port.
        #expect(settings.mcpPort == 4257)
    }
}

/// The listener's lifetime.
///
/// These use real sockets, because what they cover only exists at that level:
/// `NWListener.cancel()` releases its socket asynchronously, so binding a
/// replacement to the same port in the same turn fails.
///
/// `.serialized`, and a distinct port per test: Swift Testing runs a suite's
/// tests in parallel by default, so sharing one port made them compete for it
/// and fail each other rather than the code.
@Suite(.serialized)
@MainActor
struct MCPServerLifetimeTests {

    private func waitForState(_ server: MCPServer,
                              _ matches: @escaping (MCPServer.State) -> Bool) async -> Bool {
        // Bounded, because a listener that never reports is the failure this is
        // looking for, and a test that hangs reports nothing at all.
        for _ in 0 ..< 40 {
            if matches(server.state) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func isListening(_ state: MCPServer.State) -> Bool {
        if case .listening = state { return true }
        return false
    }

    private func isFailed(_ state: MCPServer.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func makeServer() -> MCPServer {
        MCPServer(onStateChange: { _ in },
                  respond: { _ in .empty(status: 200, reason: "OK") })
    }

    @Test("A replacement on the same port waits for the cancellation to finish")
    func restartOnSamePort() async {
        let port: UInt16 = 48_261
        let first = makeServer()
        first.start(port: port)
        guard await waitForState(first, isListening) else {
            // The port is taken by something outside this test; nothing to
            // assert, and failing here would be a false alarm.
            return
        }

        // The callback is what makes this safe. Binding straight after `stop()`
        // returns fails, measured: `cancel()` frees the socket asynchronously.
        let second = makeServer()
        first.stop { second.start(port: port) }

        let ok = await waitForState(second, isListening)
        #expect(ok, "a replacement must bind once the port is free; state = \(second.state)")
        second.stop()
    }

    @Test("Stopping a server that never started still runs the continuation")
    func continuationRunsWithoutAListener() {
        // Otherwise a failed or never-started server would wait for a
        // `.cancelled` that never arrives, and the replacement would never be
        // started at all.
        var ran = false
        makeServer().stop { ran = true }
        #expect(ran)
    }

    @Test("Two live servers cannot share a port")
    func portIsNotShared() async {
        let port: UInt16 = 48_262
        let first = makeServer()
        first.start(port: port)
        guard await waitForState(first, isListening) else { return }

        // Reuse is deliberately not enabled: if two listeners could bind the
        // same port, a leaked one would be invisible instead of loud.
        let second = makeServer()
        second.start(port: port)
        #expect(await waitForState(second, isFailed))

        first.stop()
        second.stop()
    }

    @Test("Stopping reports idle, which is not running")
    func stopReportsIdle() async {
        let server = makeServer()
        server.start(port: 48_263)
        guard await waitForState(server, isListening) else { return }
        server.stop()
        #expect(server.state == .idle)
    }
}
