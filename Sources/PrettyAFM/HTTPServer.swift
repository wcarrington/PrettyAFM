import Foundation
import Network

/// A deliberately small HTTP/1.1 server built on Network.framework.
/// One request per connection (`Connection: close`), which keeps streaming simple:
/// a streamed body is terminated by closing the socket.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // lower-cased keys
    let body: Data

    func json() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

enum HTTPError: Error { case closed, tooLarge, malformed }

final class HTTPConnection: @unchecked Sendable {
    private let conn: NWConnection
    private var buffer = Data()
    private(set) var isClosed = false
    static let maxBody = 64 * 1024 * 1024   // images arrive base64-encoded

    init(_ conn: NWConnection) { self.conn = conn }

    func start(queue: DispatchQueue) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.isClosed = true
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if complete { cont.resume(throwing: HTTPError.closed); return }
                cont.resume(returning: Data())
            }
        }
    }

    func readRequest() async throws -> HTTPRequest {
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            buffer.append(try await receiveChunk())
            headerEnd = buffer.range(of: separator)
            if buffer.count > 64 * 1024 && headerEnd == nil { throw HTTPError.tooLarge }
        }
        guard let headerRange = headerEnd,
              let head = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else { throw HTTPError.malformed }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw HTTPError.malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPError.malformed }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { throw HTTPError.malformed }
            // Multiple Content-Length fields are a common source of request-boundary ambiguity.
            guard key != "content-length" || headers[key] == nil else { throw HTTPError.malformed }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = try Self.contentLength(headers["content-length"])
        // This tiny server intentionally supports fixed-length requests only.
        guard headers["transfer-encoding"] == nil else { throw HTTPError.malformed }
        var body = Data(buffer[headerRange.upperBound...])
        while body.count < length { body.append(try await receiveChunk()) }

        let target = String(requestLine[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        comps?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }

        return HTTPRequest(method: String(requestLine[0]),
                           path: comps?.path ?? target,
                           query: query,
                           headers: headers,
                           body: body.prefix(length))
    }

    static func contentLength(_ value: String?) throws -> Int {
        guard let value else { return 0 }
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let length = Int(value) else {
            throw HTTPError.malformed
        }
        guard length <= maxBody else { throw HTTPError.tooLarge }
        return length
    }

    func send(_ data: Data) async throws {
        if isClosed { throw HTTPError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func head(status: Int, contentType: String, length: Int?) -> Data {
        var h = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        h += "Content-Type: \(contentType)\r\n"
        if let length { h += "Content-Length: \(length)\r\n" }
        h += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        return Data(h.utf8)
    }

    func respond(status: Int = 200, contentType: String, body: Data) async {
        try? await send(head(status: status, contentType: contentType, length: body.count) + body)
        close()
    }

    func respondJSON(_ object: Any, status: Int = 200) async {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        await respond(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    // MARK: NDJSON streaming

    func beginStream() async throws {
        try await send(head(status: 200, contentType: "application/x-ndjson; charset=utf-8", length: nil))
    }

    func emit(_ event: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(0x0A)
        try await send(data)
    }

    func close() {
        isClosed = true
        conn.send(content: nil, isComplete: true, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"; case 400: "Bad Request"; case 404: "Not Found"
        case 405: "Method Not Allowed"; case 413: "Payload Too Large"; default: "Error"
        }
    }
}

final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, HTTPConnection) async -> Void
    private let listener: NWListener
    private let queue = DispatchQueue(label: "http.server")
    private let handler: Handler

    init(port: UInt16, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        // Bind to loopback only: this server exposes local models and must not be reachable from the network.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.handler = handler
    }

    func start(onReady: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable (Error) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onReady()
            case .failed(let error): onFailure(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [queue, handler] nw in
            let conn = HTTPConnection(nw)
            conn.start(queue: queue)
            Task {
                do {
                    let request = try await conn.readRequest()
                    await handler(request, conn)
                } catch HTTPError.tooLarge {
                    await conn.respondJSON(["error": "Request too large"], status: 413)
                } catch {
                    conn.close()
                }
            }
        }
        listener.start(queue: queue)
    }
}
