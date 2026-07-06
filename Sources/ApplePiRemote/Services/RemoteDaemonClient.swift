import Foundation
import ApplePiCore

public struct RemoteDaemonClient: Sendable {
    public init() {}

    public func testConnection(host: PiHostConfiguration, tokenOverride: String? = nil) async throws -> String {
        let _: HealthResponse = try await send(
            host: host,
            path: "/healthz",
            tokenOverride: tokenOverride
        )
        let catalog: CatalogResponse = try await send(
            host: host,
            path: "/sessions",
            tokenOverride: tokenOverride
        )
        return "Connected. \(catalog.projects.count) projects, \(catalog.sessions.count) sessions."
    }

    /// Live subscription to the daemon's `/sessions/stream` SSE endpoint.
    /// Yields a full `PiCatalogSnapshot` every time the daemon emits a
    /// `snapshot` event. Non-snapshot events, heartbeats, and malformed
    /// frames are silently skipped — the stream only finishes (with an
    /// error) when the underlying HTTP request itself fails. The caller
    /// owns the reconnect cadence.
    public func streamCatalogSnapshots(
        host: PiHostConfiguration,
        tokenOverride: String? = nil
    ) -> AsyncThrowingStream<CatalogStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let request: URLRequest
            do {
                request = try makeLiveRequest(
                    host: host,
                    path: "/sessions/stream",
                    tokenOverride: tokenOverride,
                    accept: "text/event-stream"
                )
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let startedAt = Date()
            Self.logHTTPStart(request, category: "remote.catalog-sse")
            let worker = Task {
                do {
                    let (bytes, response) = try await Self.liveSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw RemoteDaemonError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var bodyData = Data()
                        for try await byte in bytes {
                            bodyData.append(byte)
                        }
                        let message = String(data: bodyData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let error = RemoteDaemonError.requestFailed(status: http.statusCode, body: message)
                        Self.logHTTPFailure(request, error: error, status: http.statusCode, body: message, startedAt: startedAt, category: "remote.catalog-sse")
                        throw error
                    }
                    var connectMetadata = Self.diagnosticMetadata(for: request)
                    connectMetadata["status"] = String(http.statusCode)
                    connectMetadata["connectMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
                    RemoteDiagnostics.log(level: "info", category: "remote.catalog-sse", message: "Catalog SSE connected", metadata: connectMetadata)

                    let parser = SSECatalogEventParser()
                    let decoder = Self.makeCatalogDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let event = parser.feed(line) else { continue }
                        if event.event == "error" {
                            let message = Self.decodeSSEErrorMessage(from: event.data) ?? "Catalog stream failed."
                            throw RemoteDaemonError.requestFailed(status: 0, body: message)
                        }
                        guard let data = event.data.data(using: .utf8) else { continue }
                        switch event.event {
                        case "snapshot":
                            if let response = try? Self.makeCatalogDecoder().decode(CatalogResponse.self, from: data) {
                                continuation.yield(.snapshot(Self.catalogSnapshot(from: response)))
                            }
                        case "session_updated":
                            if let record = try? decoder.decode(SessionRecord.self, from: data) {
                                continuation.yield(.sessionUpdated(Self.sessionSummary(from: record)))
                            }
                        case "session_removed":
                            if let object = try? decoder.decode(SessionRemovedPayload.self, from: data) {
                                continuation.yield(.sessionRemoved(sessionId: object.sessionId))
                            }
                        case "runtime_changed":
                            if let object = try? decoder.decode(RuntimeChangedPayload.self, from: data),
                               let payload = object.runtime {
                                let sessionId = object.sessionId ?? payload.sessionId ?? ""
                                continuation.yield(.runtimeChanged(sessionId: sessionId, runtime: payload.runtimeState))
                            }
                        default:
                            continuation.yield(.unknown(event.event, event.data))
                        }
                    }
                    RemoteDiagnostics.log(level: "info", category: "remote.catalog-sse", message: "Catalog SSE finished", metadata: Self.diagnosticMetadata(for: request))
                    continuation.finish()
                } catch {
                    Self.logHTTPFailure(request, error: error, startedAt: startedAt, category: "remote.catalog-sse")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                RemoteDiagnostics.log(level: "debug", category: "remote.catalog-sse", message: "Catalog SSE terminated", metadata: Self.diagnosticMetadata(for: request))
                worker.cancel()
            }
        }
    }

    private static func decodeCatalogSnapshot(from data: Data) -> PiCatalogSnapshot? {
        guard let response = try? makeCatalogDecoder().decode(CatalogResponse.self, from: data) else {
            return nil
        }
        return catalogSnapshot(from: response)
    }

    /// Live subscription to a single session's persisted JSONL tail. The
    /// daemon first replays all records after `after`, then keeps the SSE
    /// connection open and emits every newly appended JSONL line as an
    /// `event` frame. The caller still owns history pagination (`before`) and
    /// reconnect cadence; this stream is the fast path for live catch-up.
    public func streamSessionEventPages(
        host: PiHostConfiguration,
        sessionID: String,
        after: Int,
        tokenOverride: String? = nil
    ) -> AsyncThrowingStream<SessionEventsPage, Error> {
        AsyncThrowingStream { continuation in
            let request: URLRequest
            do {
                request = try makeLiveRequest(
                    host: host,
                    path: "/sessions/\(encodedPathComponent(sessionID))/stream",
                    queryItems: [URLQueryItem(name: "after", value: String(after))],
                    tokenOverride: tokenOverride,
                    accept: "text/event-stream"
                )
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let startedAt = Date()
            Self.logHTTPStart(request, category: "remote.session-sse")
            let worker = Task {
                do {
                    let (bytes, response) = try await Self.liveSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw RemoteDaemonError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var bodyData = Data()
                        for try await byte in bytes {
                            bodyData.append(byte)
                        }
                        let message = String(data: bodyData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let error = RemoteDaemonError.requestFailed(status: http.statusCode, body: message)
                        Self.logHTTPFailure(request, error: error, status: http.statusCode, body: message, startedAt: startedAt, category: "remote.session-sse")
                        throw error
                    }
                    var connectMetadata = Self.diagnosticMetadata(for: request)
                    connectMetadata["status"] = String(http.statusCode)
                    connectMetadata["connectMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
                    connectMetadata["sessionID"] = sessionID
                    connectMetadata["after"] = String(after)
                    RemoteDiagnostics.log(level: "info", category: "remote.session-sse", message: "Session SSE connected", metadata: connectMetadata)

                    let parser = SSECatalogEventParser()
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let event = parser.feed(line) else { continue }
                        if event.event == "error" {
                            let message = Self.decodeSSEErrorMessage(from: event.data) ?? "Session stream failed."
                            throw RemoteDaemonError.requestFailed(status: 0, body: message)
                        }
                        guard event.event == "event",
                              let data = event.data.data(using: .utf8),
                              let record = try? decoder.decode(RawEventRecord.self, from: data) else {
                            continue
                        }
                        let events = SessionEventParser.decodeAll(line: record.raw, at: record.line)
                        guard !events.isEmpty else { continue }
                        RemoteDiagnostics.log(
                            level: "debug",
                            category: "remote.session-sse.event",
                            message: "Received session SSE event",
                            metadata: ["sessionID": sessionID, "line": String(record.line), "decodedEvents": String(events.count)]
                        )
                        continuation.yield(
                            SessionEventsPage(
                                events: events,
                                firstLine: record.line,
                                lastLine: record.line,
                                hasMoreBefore: false,
                                hasMoreAfter: false
                            )
                        )
                    }
                    RemoteDiagnostics.log(level: "info", category: "remote.session-sse", message: "Session SSE finished", metadata: ["sessionID": sessionID, "after": String(after)])
                    continuation.finish()
                } catch {
                    Self.logHTTPFailure(request, error: error, startedAt: startedAt, category: "remote.session-sse")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                RemoteDiagnostics.log(level: "debug", category: "remote.session-sse", message: "Session SSE terminated", metadata: ["sessionID": sessionID, "after": String(after)])
                worker.cancel()
            }
        }
    }

    private static func decodeSSEErrorMessage(from data: String) -> String? {
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return data.nilIfBlank
        }
        return (object["error"] as? String)?.nilIfBlank ?? data.nilIfBlank
    }

    public func loadCatalog(host: PiHostConfiguration, activeProjectDirectory: String?, tokenOverride: String? = nil) async throws -> PiCatalogSnapshot {
        let response: CatalogResponse = try await send(
            host: host,
            path: "/sessions",
            queryItems: activeProjectDirectory?.nilIfBlank.map { [URLQueryItem(name: "projectDirectory", value: $0)] } ?? [],
            tokenOverride: tokenOverride
        )
        return Self.catalogSnapshot(from: response)
    }

    public func loadSessionEventPage(
        host: PiHostConfiguration,
        sessionID: String,
        limit: Int? = 60,
        after: Int? = nil,
        before: Int? = nil,
        tokenOverride: String? = nil
    ) async throws -> SessionEventsPage {
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let after {
            queryItems.append(URLQueryItem(name: "after", value: String(after)))
        }
        if let before {
            queryItems.append(URLQueryItem(name: "before", value: String(before)))
        }

        let cacheKey = Self.sessionEventPageCacheKey(
            host: host,
            sessionID: sessionID,
            limit: limit,
            before: before
        )
        // Older history pages (`before`) are immutable for append-only JSONL
        // sessions, so keep them in a large in-process Mac cache. Do not cache
        // the latest page: force reloads after a send must always hit the daemon.
        let canUseEventPageCache = after == nil && before != nil && tokenOverride == nil
        if canUseEventPageCache,
           let cached = await Self.sessionEventPageCache.page(for: cacheKey) {
            return cached
        }

        let response: EventPageResponse = try await send(
            host: host,
            path: "/sessions/\(encodedPathComponent(sessionID))/events",
            queryItems: queryItems,
            tokenOverride: tokenOverride
        )
        let page = SessionEventsPage(
            events: response.events.flatMap { SessionEventParser.decodeAll(line: $0.raw, at: $0.line) },
            firstLine: response.page?.firstLine,
            lastLine: response.page?.lastLine,
            hasMoreBefore: response.page?.hasMoreBefore ?? false,
            hasMoreAfter: response.page?.hasMoreAfter ?? false
        )
        if canUseEventPageCache {
            await Self.sessionEventPageCache.store(page, for: cacheKey)
        }
        return page
    }

    public func loadSessionEvents(
        host: PiHostConfiguration,
        sessionID: String,
        limit: Int? = 60,
        after: Int? = nil,
        before: Int? = nil,
        tokenOverride: String? = nil
    ) async throws -> [SessionEvent] {
        let page = try await loadSessionEventPage(
            host: host,
            sessionID: sessionID,
            limit: limit,
            after: after,
            before: before,
            tokenOverride: tokenOverride
        )
        return page.events
    }

    public func loadSessionDefaults(host: PiHostConfiguration, workingDirectory: String?, tokenOverride: String? = nil) async throws -> SessionDefaultsSnapshot {
        let response: SessionDefaultsResponse = try await send(
            host: host,
            path: "/runtime/defaults",
            queryItems: workingDirectory?.nilIfBlank.map { [URLQueryItem(name: "cwd", value: $0)] } ?? [],
            tokenOverride: tokenOverride
        )
        return SessionDefaultsSnapshot(
            runtimeState: response.runtime.runtimeState,
            availableModels: response.models.map(\.piModelOption)
        )
    }

    public func loadSessionRuntime(host: PiHostConfiguration, sessionID: String, tokenOverride: String? = nil) async throws -> SessionRuntimeState {
        let response: SessionRuntimeResponse = try await send(
            host: host,
            path: "/sessions/\(encodedPathComponent(sessionID))/runtime",
            tokenOverride: tokenOverride
        )
        return response.runtimeState
    }

    public func loadAvailableModels(host: PiHostConfiguration, sessionID: String? = nil, tokenOverride: String? = nil) async throws -> [PiModelOption] {
        let response: AvailableModelsResponse = try await send(
            host: host,
            path: "/models",
            tokenOverride: tokenOverride
        )
        return response.models.map(\.piModelOption)
    }

    public func setSessionModel(
        host: PiHostConfiguration,
        sessionID: String,
        provider: String,
        modelID: String,
        tokenOverride: String? = nil
    ) async throws -> SessionRuntimeState {
        let response: SessionRuntimeResponse = try await send(
            host: host,
            path: "/sessions/\(encodedPathComponent(sessionID))/model",
            method: "POST",
            tokenOverride: tokenOverride,
            body: SetModelRequestBody(provider: provider, modelId: modelID),
            accept: "application/json"
        )
        return response.runtimeState
    }

    public func setSessionThinkingLevel(
        host: PiHostConfiguration,
        sessionID: String,
        level: String,
        tokenOverride: String? = nil
    ) async throws -> SessionRuntimeState {
        let response: SessionRuntimeResponse = try await send(
            host: host,
            path: "/sessions/\(encodedPathComponent(sessionID))/thinking",
            method: "POST",
            tokenOverride: tokenOverride,
            body: SetThinkingLevelRequestBody(level: level),
            accept: "application/json"
        )
        return response.runtimeState
    }

    public func renameSession(
        host: PiHostConfiguration,
        sessionID: String,
        name: String,
        tokenOverride: String? = nil
    ) async throws -> PiSessionSummary {
        let response: SessionRecord = try await send(
            host: host,
            path: "/sessions/\(encodedPathComponent(sessionID))/name",
            method: "POST",
            tokenOverride: tokenOverride,
            body: RenameSessionRequestBody(name: name),
            accept: "application/json"
        )
        return Self.sessionSummary(from: response)
    }

    public func listDirectories(host: PiHostConfiguration, path: String?, tokenOverride: String? = nil) async throws -> RemoteDirectoryListing {
        let response: FileListResponse = try await send(
            host: host,
            path: "/files",
            queryItems: path?.nilIfBlank.map { [URLQueryItem(name: "path", value: $0)] } ?? [],
            tokenOverride: tokenOverride
        )
        return RemoteDirectoryListing(
            path: response.path,
            parent: response.parent,
            directories: response.items.filter(\.isDirectory).map {
                RemoteDirectoryEntry(name: $0.name, path: $0.path)
            }
        )
    }

    public func streamNewSession(
        host: PiHostConfiguration,
        request: PiLaunchRequest,
        prompt: String,
        attachments: [UploadedAttachmentReference] = [],
        onEvent: @escaping @Sendable (PiTurnStreamEvent) async -> Void
    ) async throws {
        let body = InputRequestBody(
            sessionId: nil,
            workingDirectory: request.workingDirectory,
            sessionName: request.sessionName,
            isTemporary: request.isEphemeral,
            prompt: prompt,
            forkPath: request.forkPath,
            attachments: attachments,
            initialModelProvider: request.initialModelProvider,
            initialModelId: request.initialModelID,
            initialThinkingLevel: request.initialThinkingLevel
        )
        try await stream(
            host: host,
            path: "/input",
            method: "POST",
            body: body,
            onEvent: onEvent
        )
    }

    public func streamSend(
        host: PiHostConfiguration,
        sessionID: String,
        prompt: String,
        attachments: [UploadedAttachmentReference] = [],
        onEvent: @escaping @Sendable (PiTurnStreamEvent) async -> Void
    ) async throws {
        let body = InputRequestBody(sessionId: sessionID, prompt: prompt, attachments: attachments)
        var attempt = 0
        while true {
            do {
                try await stream(
                    host: host,
                    path: "/input",
                    method: "POST",
                    body: body,
                    onEvent: onEvent
                )
                return
            } catch RemoteDaemonError.requestFailed(let status, _) where status == 409 && attempt < 6 {
                let backoffMilliseconds = 200 * (1 << attempt)
                attempt += 1
                try await Task.sleep(for: .milliseconds(backoffMilliseconds))
            } catch {
                throw error
            }
        }
    }

    public func abortSession(host: PiHostConfiguration, sessionID: String, tokenOverride: String? = nil) async throws {
        let _: EmptyOKResponse = try await send(
            host: host,
            path: "/sessions/\(encodedPathComponent(sessionID))/abort",
            method: "POST",
            tokenOverride: tokenOverride,
            body: EmptyRequestBody(),
            accept: "application/json"
        )
    }

    public func submitSessionInput(
        host: PiHostConfiguration,
        sessionID: String,
        prompt: String,
        attachments: [UploadedAttachmentReference] = [],
        tokenOverride: String? = nil
    ) async throws {
        let body = InputRequestBody(sessionId: sessionID, prompt: prompt, attachments: attachments)
        try await stream(
            host: host,
            path: "/input",
            method: "POST",
            body: body,
            tokenOverride: tokenOverride,
            onEvent: { _ in }
        )
    }

    public func compactSession(
        host: PiHostConfiguration,
        sessionID: String,
        instructions: String = "",
        tokenOverride: String? = nil
    ) async throws {
        let _: EmptyOKResponse = try await send(
            host: host,
            path: "/sessions/\(encodedPathComponent(sessionID))/compact",
            method: "POST",
            tokenOverride: tokenOverride,
            body: SendSessionRequestBody(prompt: instructions, attachments: []),
            accept: "application/json"
        )
    }

    public func downloadFile(host: PiHostConfiguration, path: String, baseDirectory: String? = nil, tokenOverride: String? = nil) async throws -> RemoteFileDownload {
        var queryItems = [URLQueryItem(name: "path", value: path)]
        if let baseDirectory = baseDirectory?.nilIfBlank {
            queryItems.append(URLQueryItem(name: "base", value: baseDirectory))
        }
        let request = try makeRequest(
            host: host,
            path: "/file",
            queryItems: queryItems,
            tokenOverride: tokenOverride,
            accept: "*/*"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteDaemonError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
        }
        return RemoteFileDownload(
            data: data,
            fileName: Self.fileNameFromContentDisposition(httpResponse.value(forHTTPHeaderField: "Content-Disposition"))
                ?? URL(fileURLWithPath: path).lastPathComponent,
            mimeType: httpResponse.value(forHTTPHeaderField: "Content-Type")
        )
    }

    public func uploadAttachment(host: PiHostConfiguration, attachment: ChatAttachment) async throws -> UploadedAttachmentReference {
        let boundary = "ApplePiBoundary-\(UUID().uuidString)"
        var request = try makeRequest(
            host: host,
            path: "/uploads",
            method: "POST",
            accept: "application/json"
        )
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // The filename is embedded directly in a
        // `Content-Disposition: form-data; name="file"; filename="…"`
        // header. Apply a strict whitelist so unusual Unicode, control
        // bytes, or semicolons cannot confuse the server's multipart
        // parser or smuggle additional header parameters.
        let multipartFileName = MultipartFilenameSanitizer.sanitize(
            attachment.displayName,
            placeholder: "attachment"
        )

        let fileData = try Data(contentsOf: attachment.fileURL)
        request.httpBody = Self.makeUploadMultipartBody(
            fileName: multipartFileName,
            mimeType: attachment.mimeType,
            fileData: fileData,
            boundary: boundary
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteDaemonError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
        }
        do {
            return try JSONDecoder().decode(UploadedAttachmentReference.self, from: data)
        } catch {
            throw RemoteDaemonError.decodingFailed(error.localizedDescription)
        }
    }

    public func transcribeAudio(host: PiHostConfiguration, fileURL: URL, language: String = "ru", tokenOverride: String? = nil) async throws -> String {
        let boundary = "ApplePiTranscribeBoundary-\(UUID().uuidString)"
        var request = try makeRequest(
            host: host,
            path: "/transcribe",
            method: "POST",
            tokenOverride: tokenOverride,
            accept: "application/json"
        )
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileName = MultipartFilenameSanitizer.sanitize(fileURL.lastPathComponent, placeholder: "audio")
        let fileData = try Data(contentsOf: fileURL)
        request.httpBody = Self.makeTranscriptionMultipartBody(
            fileName: fileName,
            mimeType: Self.audioMimeType(for: fileURL),
            fileData: fileData,
            language: language,
            boundary: boundary
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteDaemonError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
        }
        do {
            let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw RemoteDaemonError.decodingFailed("empty transcription")
            }
            return text
        } catch let error as RemoteDaemonError {
            throw error
        } catch {
            throw RemoteDaemonError.decodingFailed(error.localizedDescription)
        }
    }

    /// Builds the multipart body for `/uploads`. Exposed as a static
    /// helper so the test suite can pin the exact wire format (in
    /// particular the sanitised filename and the `Content-Disposition`
    /// header) without having to mock `URLSession`.
    public static func makeUploadMultipartBody(
        fileName: String,
        mimeType: String?,
        fileData: Data,
        boundary: String
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        if let mimeType {
            body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        } else {
            body.append(Data("\r\n".utf8))
        }
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    public static func makeTranscriptionMultipartBody(
        fileName: String,
        mimeType: String,
        fileData: Data,
        language: String,
        boundary: String
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        body.append(Data("whisper-large-v3\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n".utf8))
        body.append(Data("\(language)\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func audioMimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }

    private func send<Response: Decodable>(
        host: PiHostConfiguration,
        path: String,
        queryItems: [URLQueryItem] = [],
        tokenOverride: String? = nil
    ) async throws -> Response {
        let request = try makeRequest(
            host: host,
            path: path,
            queryItems: queryItems,
            tokenOverride: tokenOverride,
            accept: "application/json"
        )

        let startedAt = Date()
        Self.logHTTPStart(request)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RemoteDaemonError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let error = RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
                Self.logHTTPFailure(request, error: error, status: httpResponse.statusCode, body: message, startedAt: startedAt)
                throw error
            }

            let decoder = Self.makeCatalogDecoder()
            do {
                let decoded = try decoder.decode(Response.self, from: data)
                Self.logHTTPSuccess(request, status: httpResponse.statusCode, startedAt: startedAt)
                return decoded
            } catch {
                let wrapped = RemoteDaemonError.decodingFailed(error.localizedDescription)
                Self.logHTTPFailure(request, error: wrapped, status: httpResponse.statusCode, startedAt: startedAt)
                throw wrapped
            }
        } catch {
            Self.logHTTPFailure(request, error: error, startedAt: startedAt)
            throw error
        }
    }

    private func send<Response: Decodable, Body: Encodable>(
        host: PiHostConfiguration,
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        tokenOverride: String? = nil,
        body: Body,
        accept: String
    ) async throws -> Response {
        let request = try makeRequest(
            host: host,
            path: path,
            method: method,
            queryItems: queryItems,
            tokenOverride: tokenOverride,
            body: body,
            accept: accept
        )

        let startedAt = Date()
        Self.logHTTPStart(request)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RemoteDaemonError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let error = RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
                Self.logHTTPFailure(request, error: error, status: httpResponse.statusCode, body: message, startedAt: startedAt)
                throw error
            }

            let decoder = Self.makeCatalogDecoder()
            do {
                let decoded = try decoder.decode(Response.self, from: data)
                Self.logHTTPSuccess(request, status: httpResponse.statusCode, startedAt: startedAt)
                return decoded
            } catch {
                let wrapped = RemoteDaemonError.decodingFailed(error.localizedDescription)
                Self.logHTTPFailure(request, error: wrapped, status: httpResponse.statusCode, startedAt: startedAt)
                throw wrapped
            }
        } catch {
            Self.logHTTPFailure(request, error: error, startedAt: startedAt)
            throw error
        }
    }

    private func stream<Body: Encodable>(
        host: PiHostConfiguration,
        path: String,
        method: String,
        body: Body,
        tokenOverride: String? = nil,
        onEvent: @escaping @Sendable (PiTurnStreamEvent) async -> Void
    ) async throws {
        let request = try makeRequest(
            host: host,
            path: path,
            method: method,
            tokenOverride: tokenOverride,
            body: body,
            accept: "application/x-ndjson"
        )

        let startedAt = Date()
        Self.logHTTPStart(request, category: "remote.turn-stream")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RemoteDaemonError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                var bodyData = Data()
                for try await byte in bytes {
                    bodyData.append(byte)
                }
                let message = String(data: bodyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let error = RemoteDaemonError.requestFailed(status: httpResponse.statusCode, body: message)
                Self.logHTTPFailure(request, error: error, status: httpResponse.statusCode, body: message, startedAt: startedAt, category: "remote.turn-stream")
                throw error
            }

            var eventCount = 0
            for try await line in bytes.lines {
                if let event = PiTurnStreamParser.parseLine(line) {
                    eventCount += 1
                    let eventType = Self.turnStreamEventType(event)
                    // Streaming text can produce hundreds of `session_events`
                    // per turn. Log control events every time, but sample the
                    // high-volume payload events so the diagnostics ring buffer
                    // keeps useful context instead of becoming token spam.
                    if eventType != "session_events" || eventCount == 1 || eventCount.isMultiple(of: 25) {
                        RemoteDiagnostics.log(
                            level: "debug",
                            category: "remote.turn-stream.event",
                            message: "Received turn stream event",
                            metadata: [
                                "type": eventType,
                                "count": String(eventCount)
                            ]
                        )
                    }
                    await onEvent(event)
                    switch event {
                    case .streamError(let message):
                        let error = RemoteDaemonError.requestFailed(status: 0, body: message)
                        Self.logHTTPFailure(request, error: error, body: message, startedAt: startedAt, category: "remote.turn-stream")
                        throw error
                    case .outputComplete:
                        var metadata = Self.diagnosticMetadata(for: request)
                        metadata["status"] = String(httpResponse.statusCode)
                        metadata["durationMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
                        metadata["events"] = String(eventCount)
                        RemoteDiagnostics.log(level: "info", category: "remote.turn-stream", message: "Turn stream completed", metadata: metadata)
                        return
                    case .turnEnd, .agentEnd, .abort:
                        continue
                    case .sessionBound, .sessionHeader, .sessionEvents:
                        break
                    }
                }
            }
            var metadata = Self.diagnosticMetadata(for: request)
            metadata["status"] = String(httpResponse.statusCode)
            metadata["durationMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
            metadata["events"] = String(eventCount)
            RemoteDiagnostics.log(level: "warn", category: "remote.turn-stream", message: "Turn stream ended without output_complete", metadata: metadata)
        } catch {
            Self.logHTTPFailure(request, error: error, startedAt: startedAt, category: "remote.turn-stream")
            throw error
        }
    }

    private func makeRequest(
        host: PiHostConfiguration,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        tokenOverride: String? = nil,
        accept: String
    ) throws -> URLRequest {
        guard let baseURL = host.remoteDaemonBaseURL else {
            throw RemoteDaemonError.missingBaseURL
        }
        guard let token = tokenOverride?.nilIfBlank ?? RemoteDaemonTokenStore.readToken(for: host) else {
            throw RemoteDaemonError.missingToken
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RemoteDaemonError.invalidBaseURL
        }
        let basePath = components.percentEncodedPath
        components.percentEncodedPath = joinedPath(basePath: basePath, requestPath: path)
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw RemoteDaemonError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300
        return request
    }

    private func makeLiveRequest(
        host: PiHostConfiguration,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        tokenOverride: String? = nil,
        accept: String
    ) throws -> URLRequest {
        var request = try makeRequest(
            host: host,
            path: path,
            method: method,
            queryItems: queryItems,
            tokenOverride: tokenOverride,
            accept: accept
        )
        request.timeoutInterval = TimeInterval.infinity
        return request
    }

    private func makeRequest<Body: Encodable>(
        host: PiHostConfiguration,
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        tokenOverride: String? = nil,
        body: Body,
        accept: String
    ) throws -> URLRequest {
        var request = try makeRequest(
            host: host,
            path: path,
            method: method,
            queryItems: queryItems,
            tokenOverride: tokenOverride,
            accept: accept
        )
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func turnStreamEventType(_ event: PiTurnStreamEvent) -> String {
        switch event {
        case .sessionBound: return "session_bound"
        case .sessionHeader: return "session_header"
        case .sessionEvents: return "session_events"
        case .turnEnd: return "turn_end"
        case .agentEnd: return "agent_end"
        case .abort: return "abort"
        case .streamError: return "stream_error"
        case .outputComplete: return "output_complete"
        }
    }

    private static func logHTTPStart(_ request: URLRequest, category: String = "remote.http") {
        RemoteDiagnostics.log(
            level: "debug",
            category: category,
            message: "HTTP request started",
            metadata: diagnosticMetadata(for: request)
        )
    }

    private static func logHTTPSuccess(_ request: URLRequest, status: Int, startedAt: Date, category: String = "remote.http") {
        var metadata = diagnosticMetadata(for: request)
        metadata["status"] = String(status)
        metadata["durationMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
        RemoteDiagnostics.log(
            level: "debug",
            category: category,
            message: "HTTP request completed",
            metadata: metadata
        )
    }

    private static func logHTTPFailure(
        _ request: URLRequest,
        error: Error,
        status: Int? = nil,
        body: String? = nil,
        startedAt: Date,
        category: String = "remote.http"
    ) {
        var metadata = diagnosticMetadata(for: request)
        metadata["durationMs"] = String(Int(Date().timeIntervalSince(startedAt) * 1000))
        if let status { metadata["status"] = String(status) }
        if let body { metadata["body"] = truncated(body) }
        metadata["error"] = truncated(error.localizedDescription)
        RemoteDiagnostics.log(
            level: "warn",
            category: category,
            message: "HTTP request failed",
            metadata: metadata
        )
    }

    private static func diagnosticMetadata(for request: URLRequest) -> [String: String] {
        var metadata: [String: String] = [
            "method": request.httpMethod ?? "GET"
        ]
        if let url = request.url {
            metadata["host"] = url.host ?? ""
            metadata["path"] = url.path
            if let query = url.query, !query.isEmpty {
                metadata["query"] = query
            }
        }
        return metadata
    }

    private static func truncated(_ value: String, limit: Int = 500) -> String {
        if value.count <= limit { return value }
        return String(value.prefix(limit)) + "…"
    }

    private static func fileNameFromContentDisposition(_ value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"filename=\"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range]).nilIfBlank
    }

    private static func makeCatalogDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = RemoteDaemonDateParsers.shared.parse(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid daemon date: \(raw)"
            )
        }
        return decoder
    }

    private static func catalogSnapshot(from response: CatalogResponse) -> PiCatalogSnapshot {
        PiCatalogSnapshot(
            projects: response.projects.map { record in
                PiProject(
                    id: record.id,
                    title: record.title,
                    workingDirectory: record.workingDirectory,
                    sessionDirectory: record.sessionDirectory,
                    sessionCount: record.sessionCount,
                    lastActivity: record.lastActivity
                )
            },
            sessions: response.sessions.map { sessionSummary(from: $0) }
        )
    }

    private static func sessionSummary(from record: SessionRecord) -> PiSessionSummary {
        PiSessionSummary(
            id: record.id,
            filePath: record.filePath,
            projectID: record.projectID,
            title: record.title,
            workingDirectory: record.workingDirectory,
            messageCount: record.messageCount,
            modifiedAt: record.modifiedAt,
            displayName: record.displayName,
            parentSession: record.parentSession,
            branchCount: record.branchCount,
            labelCount: record.labelCount,
            branchSummaryCount: record.branchSummaryCount,
            latestModel: record.latestModel,
            isGenerating: record.isGenerating ?? false
        )
    }

    private static func sessionEventPageCacheKey(
        host: PiHostConfiguration,
        sessionID: String,
        limit: Int?,
        before: Int?
    ) -> String {
        [
            host.remoteDaemonBaseURL?.absoluteString ?? "",
            sessionID,
            limit.map(String.init) ?? "nil",
            before.map(String.init) ?? "nil"
        ].joined(separator: "\u{1f}")
    }

    private static let sessionEventPageCache = RemoteSessionEventPageMemoryCache()

    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = TimeInterval.infinity
        configuration.timeoutIntervalForResource = TimeInterval.infinity
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()
}

private actor RemoteSessionEventPageMemoryCache {
    private let maxEntries = 500
    private var entries: [String: SessionEventsPage] = [:]
    private var order: [String] = []

    func page(for key: String) -> SessionEventsPage? {
        entries[key]
    }

    func store(_ page: SessionEventsPage, for key: String) {
        if entries[key] == nil {
            order.append(key)
        }
        entries[key] = page
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

private func joinedPath(basePath: String, requestPath: String) -> String {
    let left = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let right = requestPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    switch (left.isEmpty, right.isEmpty) {
    case (true, true): return "/"
    case (true, false): return "/\(right)"
    case (false, true): return "/\(left)"
    case (false, false): return "/\(left)/\(right)"
    }
}

private func encodedPathComponent(_ value: String) -> String {
    value.addingPercentEncoding(
        withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    ) ?? value
}

private final class RemoteDaemonDateParsers: @unchecked Sendable {
    static let shared = RemoteDaemonDateParsers()

    private let lock = NSLock()
    private let withFractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    private init() {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.withFractional = withFractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        self.plain = plain
    }

    func parse(_ raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = withFractional.date(from: raw) { return date }
        return plain.date(from: raw)
    }
}

public enum RemoteDaemonError: LocalizedError {
    case missingBaseURL
    case invalidBaseURL
    case missingToken
    case invalidResponse
    case requestFailed(status: Int, body: String?)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Remote API URL is not configured."
        case .invalidBaseURL:
            return "Remote API URL is invalid."
        case .missingToken:
            return "Remote API token is not configured."
        case .invalidResponse:
            return "Remote API returned an invalid response."
        case .requestFailed(let status, let body):
            if status <= 0 {
                return body?.nilIfBlank ?? "Remote API stream failed."
            }
            if let body = body?.nilIfBlank {
                return "Remote API error \(status): \(body)"
            }
            return "Remote API error \(status)."
        case .decodingFailed(let detail):
            return "Could not decode remote API response: \(detail)"
        }
    }
}

private struct HealthResponse: Decodable {
    let ok: Bool
}

private struct EmptyOKResponse: Decodable {
    let ok: Bool?
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct CatalogResponse: Decodable {
    let projects: [ProjectRecord]
    let sessions: [SessionRecord]
}

private struct ProjectRecord: Decodable {
    let id: String
    let title: String
    let workingDirectory: String?
    let sessionDirectory: String
    let sessionCount: Int
    let lastActivity: Date?
}

private struct SessionRecord: Decodable {
    let id: String
    let filePath: String
    let projectID: String
    let title: String
    let workingDirectory: String?
    let messageCount: Int
    let modifiedAt: Date
    let displayName: String?
    let parentSession: String?
    let branchCount: Int
    let labelCount: Int
    let branchSummaryCount: Int
    let latestModel: String?
    let isGenerating: Bool?
}

private struct EventPageResponse: Decodable {
    let events: [RawEventRecord]
    let page: EventPageRecord?
}

private struct EventPageRecord: Decodable {
    let firstLine: Int
    let lastLine: Int
    let hasMoreBefore: Bool
    let hasMoreAfter: Bool
}

private struct RawEventRecord: Decodable {
    let line: Int
    let raw: String
}

private struct FileListResponse: Decodable {
    let path: String
    let parent: String?
    let items: [FileItemRecord]
}

private struct FileItemRecord: Decodable {
    let name: String
    let path: String
    let isDirectory: Bool
}

private struct SessionRuntimeResponse: Decodable {
    let sessionId: String?
    let sessionFile: String?
    let model: RuntimeModelRecord?
    let thinkingLevel: String
    let tokens: RuntimeTokenTotals
    let contextUsage: RuntimeContextUsage?

    var runtimeState: SessionRuntimeState {
        SessionRuntimeState(
            sessionID: sessionId,
            sessionPath: sessionFile,
            provider: model?.provider,
            modelID: model?.id,
            modelName: model?.name,
            thinkingLevel: thinkingLevel,
            tokens: SessionTokenTotals(
                input: tokens.input,
                output: tokens.output,
                cacheRead: tokens.cacheRead,
                cacheWrite: tokens.cacheWrite,
                total: tokens.total
            ),
            contextUsage: contextUsage.map {
                SessionContextUsage(
                    tokens: $0.tokens,
                    contextWindow: $0.contextWindow,
                    percent: $0.percent
                )
            }
        )
    }
}

private struct RuntimeModelRecord: Decodable {
    let id: String
    let name: String?
    let provider: String
    let reasoning: Bool?
    let contextWindow: Int?

    var piModelOption: PiModelOption {
        PiModelOption(
            provider: provider,
            modelID: id,
            name: name,
            reasoning: reasoning ?? false,
            contextWindow: contextWindow
        )
    }
}

private struct RuntimeTokenTotals: Decodable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let total: Int
}

private struct RuntimeContextUsage: Decodable {
    let tokens: Int?
    let contextWindow: Int?
    let percent: Double?
}

public struct SessionDefaultsSnapshot: Sendable {
    public let runtimeState: SessionRuntimeState
    public let availableModels: [PiModelOption]

    public init(runtimeState: SessionRuntimeState, availableModels: [PiModelOption]) {
        self.runtimeState = runtimeState
        self.availableModels = availableModels
    }
}

private struct SessionDefaultsResponse: Decodable {
    let runtime: SessionRuntimeResponse
    let models: [RuntimeModelRecord]
}

private struct AvailableModelsResponse: Decodable {
    let models: [RuntimeModelRecord]
}

public struct RemoteFileDownload: Sendable {
    public let data: Data
    public let fileName: String
    public let mimeType: String?

    public init(data: Data, fileName: String, mimeType: String?) {
        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
    }
}

public struct UploadedAttachmentReference: Codable, Hashable, Sendable {
    public let path: String
    public let fileName: String
    public let mimeType: String?
    public let size: Int64?

    public init(path: String, fileName: String, mimeType: String?, size: Int64?) {
        self.path = path
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
    }
}

private struct InputRequestBody: Encodable {
    let sessionId: String?
    let workingDirectory: String?
    let sessionName: String?
    let isTemporary: Bool
    let prompt: String
    let forkPath: String?
    let attachments: [UploadedAttachmentReference]
    let initialModelProvider: String?
    let initialModelId: String?
    let initialThinkingLevel: String?

    init(
        sessionId: String?,
        workingDirectory: String? = nil,
        sessionName: String? = nil,
        isTemporary: Bool = false,
        prompt: String,
        forkPath: String? = nil,
        attachments: [UploadedAttachmentReference],
        initialModelProvider: String? = nil,
        initialModelId: String? = nil,
        initialThinkingLevel: String? = nil
    ) {
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.sessionName = sessionName
        self.isTemporary = isTemporary
        self.prompt = prompt
        self.forkPath = forkPath
        self.attachments = attachments
        self.initialModelProvider = initialModelProvider
        self.initialModelId = initialModelId
        self.initialThinkingLevel = initialThinkingLevel
    }
}

private struct SendSessionRequestBody: Encodable {
    let prompt: String
    let attachments: [UploadedAttachmentReference]
}

private struct SetModelRequestBody: Encodable {
    let provider: String
    let modelId: String
}

private struct SetThinkingLevelRequestBody: Encodable {
    let level: String
}

private struct RenameSessionRequestBody: Encodable {
    let name: String
}

private struct EmptyRequestBody: Encodable {}
