//
//  MCPServer.swift
//  paster
//
//  Created by yinminqian on 22/8/2026.
//

import Foundation
import Network

/// A minimal HTTP/1.1 listener on the loopback interface.
///
/// Hand-rolled rather than pulled in: the surface an MCP endpoint needs is one
/// POST with a `Content-Length` body, and a dependency that can serve the rest
/// of HTTP is a dependency whose bugs are also this app's. Keep-alive,
/// pipelining, chunked bodies and compression are all refused rather than
/// half-implemented.
///
/// Everything runs on the main queue, so `MCPDispatcher` can touch the SwiftData
/// context directly. Traffic is a handful of requests when a model asks a
/// question; a background queue would buy nothing and cost every cross-actor
/// hop in the tool implementations.
@MainActor
final class MCPServer {
    /// A body larger than this is refused. A clipboard tool call is a few
    /// hundred bytes; anything near a megabyte is a mistake or an attempt to
    /// make the process hold onto memory.
    private static let maximumBodyBytes = 1 << 20

    /// What the listener is doing.
    ///
    /// Reported through a callback rather than exposed as a property to poll:
    /// `NWListener` reports failure asynchronously, so the interesting value —
    /// "port 4257 is already in use" — arrives well after `start` returns. A
    /// property read once by a SwiftUI view would show `nil` forever, which is
    /// how a server the user switched on and that is not running ends up being
    /// discovered from a client's error message half an hour later.
    enum State: Equatable {
        case idle
        case listening(UInt16)
        case failed(String)
    }

    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private let respond: (MCPHTTPRequest) -> MCPHTTPResponse
    private let onStateChange: (State) -> Void

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange(state)
        }
    }

    init(onStateChange: @escaping (State) -> Void,
         respond: @escaping (MCPHTTPRequest) -> MCPHTTPResponse) {
        self.onStateChange = onStateChange
        self.respond = respond
    }

    // MARK: Lifecycle

    func start(port requested: UInt16) {
        stop()

        guard let endpointPort = NWEndpoint.Port(rawValue: requested) else {
            state = .failed(String(localized: "Port \(requested) is not usable."))
            return
        }

        let parameters = NWParameters.tcp
        // The loopback address, stated rather than assumed. Without this the
        // listener binds every interface, and a clipboard history reachable from
        // the local network is a different product than the one intended.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                              port: endpointPort)
        parameters.allowLocalEndpointReuse = false

        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.handle(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.requestedPort = requested
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops listening, and calls `then` once the port is actually free.
    ///
    /// The callback is the whole point. `NWListener.cancel()` releases the
    /// socket *asynchronously*, so binding a replacement to the same port in
    /// the same turn fails with "address already in use" — measured, not
    /// assumed: a 300 ms gap is enough and no gap is not. Anything that
    /// restarts on the same port has to wait for this rather than hope.
    func stop(then continuation: (() -> Void)? = nil) {
        guard let listener else {
            // Never started, or already failed: there is nothing to wait for,
            // and waiting for a `.cancelled` that will never arrive would leave
            // the replacement unstarted forever.
            cancelListener()
            state = .idle
            continuation?()
            return
        }
        onCancelled = continuation
        self.listener = nil
        connections.removeAll()
        state = .idle
        listener.cancel()
    }

    private var onCancelled: (() -> Void)?

    /// Releases the socket without reporting anything.
    ///
    /// Separate from `stop()` so `deinit` can use it: a discarded server must
    /// not push a state into the service, which by then is tracking its
    /// replacement.
    private func cancelListener() {
        listener?.cancel()
        listener = nil
        connections.removeAll()
    }

    /// `isolated deinit` because `NWListener` is an explicitly-managed resource
    /// and dealloc is not a documented cancel.
    ///
    /// Without this a dropped server left its socket bound, so the replacement
    /// listening on the same port failed with "address already in use" — the
    /// other program holding the port being this app. Regenerating the token
    /// took the endpoint down entirely and blamed something else for it.
    isolated deinit {
        cancelListener()
    }

    private var requestedPort: UInt16?

    /// Plain language for the one failure that actually happens.
    ///
    /// `NWError`'s own description is "The operation couldn't be completed.
    /// (Network.NWError error 48 – Address already in use)", which tells a user
    /// nothing about what to do and buries the only actionable word in
    /// parentheses. Everything else falls through to the system message rather
    /// than being guessed at.
    private static func describe(_ error: NWError, port: UInt16?) -> String {
        guard case .posix(.EADDRINUSE) = error else { return error.localizedDescription }
        if let port {
            return String(localized: "Port \(port) is already used by another program. Pick a different one.")
        }
        return String(localized: "That port is already used by another program. Pick a different one.")
    }

    private func handle(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            state = .listening(requestedPort ?? 0)
        case .failed(let error):
            state = .failed(Self.describe(error, port: requestedPort))
            listener = nil
        case .cancelled:
            listener = nil
            let continuation = onCancelled
            onCancelled = nil
            continuation?()
        default:
            break
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connections.insert(ObjectIdentifier(connection))
        connection.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            MainActor.assumeIsolated {
                // Discarded explicitly: `Set.remove` returns the element it
                // took out, which nothing here wants.
                _ = self?.connections.remove(ObjectIdentifier(connection))
            }
        }
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    /// Accumulates until the headers and the declared body have both arrived.
    ///
    /// A single `receive` is not enough: TCP is a byte stream and a POST's
    /// headers and body routinely land in separate reads.
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let chunk { buffer.append(chunk) }

                if error != nil {
                    connection.cancel()
                    return
                }

                if buffer.count > Self.maximumBodyBytes {
                    self.send(.empty(status: 413, reason: "Payload Too Large"), on: connection)
                    return
                }

                switch Self.parse(buffer) {
                case .complete(let request):
                    self.send(self.respond(request), on: connection)
                case .malformed(let reason):
                    self.send(.json(MCPDispatcher.error(code: -32600, message: reason),
                                    status: 400, reason: "Bad Request"),
                              on: connection)
                case .incomplete:
                    if isComplete {
                        // The peer closed mid-request; there is nothing to answer.
                        connection.cancel()
                    } else {
                        self.read(connection, buffer: buffer)
                    }
                }
            }
        }
    }

    /// One response, then close.
    ///
    /// `Connection: close` and an actual close, rather than keep-alive: with one
    /// request per connection there is no second message to frame, and the
    /// pipelining bugs that come with reuse are the main reason hand-written
    /// HTTP servers misbehave.
    private func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        if let contentType = response.contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        // Nothing here is for a browser, and a permissive CORS header is how a
        // local server accidentally becomes reachable from a web page.
        head += "Cache-Control: no-store\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Framing

    enum ParseResult {
        case incomplete
        case complete(MCPHTTPRequest)
        case malformed(String)
    }

    /// Splits the request line, the headers and exactly `Content-Length` bytes.
    ///
    /// `static` and pure so the framing can be tested without a socket — an
    /// off-by-one here is the difference between answering a request and hanging
    /// on it forever.
    static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return .incomplete }

        let headText = String(decoding: buffer[buffer.startIndex ..< headerEnd.lowerBound],
                              as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed("Empty request.") }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .malformed("Malformed request line.") }
        let method = String(parts[0])
        // Query string dropped: this endpoint takes no parameters that way, and
        // matching "/mcp?x=1" against "/mcp" as unequal would be a confusing
        // 404 for a client that appended something harmless.
        let path = String(parts[1].split(separator: "?", maxSplits: 1)[0])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex ..< colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Refused rather than parsed. A chunked body is a real parser, and a
        // server that ignores the header would read the chunk-size line as
        // content and answer nonsense.
        if headers["transfer-encoding"] != nil {
            return .malformed("Chunked request bodies are not supported.")
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maximumBodyBytes else {
            return .malformed("Declared body length is out of range.")
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return .incomplete }

        let body = buffer[bodyStart ..< buffer.index(bodyStart, offsetBy: length)]
        return .complete(MCPHTTPRequest(method: method,
                                        path: path,
                                        headers: headers,
                                        body: Data(body)))
    }
}
