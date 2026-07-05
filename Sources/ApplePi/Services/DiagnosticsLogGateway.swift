import Foundation
@preconcurrency import Network
import ApplePiCore
import ApplePiRemote

struct DiagnosticsGatewayState: Equatable, Sendable {
    var isRunning: Bool = false
    var port: UInt16 = 8765
    var message: String = "Diagnostics gateway is off."

    var baseURL: String {
        "http://<this-mac-tailscale-ip>:\(port)"
    }
}

struct DiagnosticsLogRecord: Codable, Sendable {
    let timestamp: Date
    let level: String
    let category: String
    let message: String
    let metadata: [String: String]
}

final class DiagnosticsLogBuffer: @unchecked Sendable {
    static let shared = DiagnosticsLogBuffer()

    private let lock = NSLock()
    private let maxRecords: Int
    private var records: [DiagnosticsLogRecord] = []
    private let encoder: JSONEncoder

    init(maxRecords: Int = 2_000) {
        self.maxRecords = maxRecords
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func append(
        level: String,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let record = DiagnosticsLogRecord(
            timestamp: Date(),
            level: Self.redact(level),
            category: Self.redact(category),
            message: Self.redact(message),
            metadata: metadata.mapValues(Self.redact)
        )
        lock.lock()
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        let count = records.count
        lock.unlock()
        return count
    }

    func jsonLines(tail: Int?) -> String {
        lock.lock()
        let snapshot: [DiagnosticsLogRecord]
        if let tail, tail > 0, tail < records.count {
            snapshot = Array(records.suffix(tail))
        } else {
            snapshot = records
        }
        lock.unlock()

        return snapshot.compactMap { record in
            guard let data = try? encoder.encode(record) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n") + (snapshot.isEmpty ? "" : "\n")
    }

    private static func redact(_ value: String) -> String {
        var redacted = value
        redacted = redacted.replacingOccurrences(
            of: #"Bearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer <redacted>",
            options: [.regularExpression]
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(token|api[_-]?key|authorization|password|secret)\s*[:=]\s*[^\s,;}]+"#,
            with: "$1=<redacted>",
            options: [.regularExpression]
        )
        return redacted
    }
}

final class DiagnosticsHTTPGateway: @unchecked Sendable {
    typealias TokenProvider = () -> String?
    typealias StateHandler = (DiagnosticsGatewayState) -> Void

    private let logger: DiagnosticsLogBuffer
    private let queue = DispatchQueue(label: "com.dodoreach.applepi.diagnostics-gateway")
    private var listener: NWListener?
    private var tokenProvider: TokenProvider?
    private var stateHandler: StateHandler?
    private var port: UInt16 = 8765

    init(logger: DiagnosticsLogBuffer = .shared) {
        self.logger = logger
    }

    func start(
        port: UInt16 = 8765,
        tokenProvider: @escaping TokenProvider,
        stateHandler: @escaping StateHandler
    ) {
        stop()
        self.port = port
        self.tokenProvider = tokenProvider
        self.stateHandler = stateHandler

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            report(isRunning: false, message: "Invalid diagnostics port \(port).")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: nwPort)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            report(isRunning: false, message: "Diagnostics gateway failed: \(error.localizedDescription)")
            logger.append(level: "error", category: "diagnostics.gateway", message: "Failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        report(isRunning: false, message: "Diagnostics gateway is off.")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.append(level: "info", category: "diagnostics.gateway", message: "Diagnostics gateway listening on port \(port)")
            report(isRunning: true, message: "Diagnostics gateway is listening on port \(port).")
        case .failed(let error):
            logger.append(level: "error", category: "diagnostics.gateway", message: "Listener failed: \(error.localizedDescription)")
            report(isRunning: false, message: "Diagnostics gateway failed: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
        case .cancelled:
            report(isRunning: false, message: "Diagnostics gateway is off.")
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.logger.append(level: "warn", category: "diagnostics.gateway", message: "Connection receive failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            self.respond(to: data, on: connection)
        }
    }

    private func respond(to data: Data, on connection: NWConnection) {
        guard let request = HTTPRequest(data: data) else {
            send(status: 400, contentType: "text/plain; charset=utf-8", body: "bad request\n", on: connection)
            return
        }

        guard request.method == "GET" else {
            send(status: 405, contentType: "text/plain; charset=utf-8", body: "method not allowed\n", on: connection)
            return
        }

        guard let token = tokenProvider?()?.nilIfBlank else {
            send(status: 503, contentType: "text/plain; charset=utf-8", body: "diagnostics token is not configured\n", on: connection)
            return
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            send(status: 401, contentType: "text/plain; charset=utf-8", body: "unauthorized\n", extraHeaders: ["WWW-Authenticate": "Bearer"], on: connection)
            return
        }

        logger.append(level: "debug", category: "diagnostics.gateway", message: "\(request.method) \(request.path)")

        switch request.path {
        case "/diagnostics/health":
            let body = "{\"ok\":true,\"app\":\"pi-app\",\"records\":\(logger.count())}\n"
            send(status: 200, contentType: "application/json; charset=utf-8", body: body, on: connection)
        case "/diagnostics/logs":
            let tail = request.queryItems["tail"].flatMap(Int.init)
            send(status: 200, contentType: "application/x-ndjson; charset=utf-8", body: logger.jsonLines(tail: tail), on: connection)
        default:
            send(status: 404, contentType: "text/plain; charset=utf-8", body: "not found\n", on: connection)
        }
    }

    private func send(
        status: Int,
        contentType: String,
        body: String,
        extraHeaders: [String: String] = [:],
        on connection: NWConnection
    ) {
        let reason = Self.reasonPhrase(for: status)
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.utf8.count)",
            "Cache-Control: no-store",
            "Connection: close"
        ]
        for (key, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headers.append("\(key): \(value)")
        }
        let response = headers.joined(separator: "\r\n") + "\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func report(isRunning: Bool, message: String) {
        stateHandler?(DiagnosticsGatewayState(isRunning: isRunning, port: port, message: message))
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        method = parts[0]

        let target = parts[1]
        let components = URLComponents(string: "http://localhost\(target)")
        path = components?.path.nilIfBlank ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        queryItems = query

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            let headerParts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard headerParts.count == 2 else { continue }
            parsedHeaders[headerParts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = headerParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        headers = parsedHeaders
    }
}
