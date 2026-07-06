import Foundation

/// Decodes a Pi `.jsonl` session file into a typed `[SessionEvent]` array.
/// We deliberately read the whole file at once for the read-only chat view;
/// the live tail in `ChatSession` will append events incrementally using
/// the same `decode(line:at:)` entry point.
package enum SessionEventParser {
    /// Read every line from disk and parse it.
    package static func parse(fileURL: URL) throws -> [SessionEvent] {
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return parse(lines: lines)
    }

    /// Parse a list of raw lines. Blank lines are skipped silently.
    package static func parse(lines: [String]) -> [SessionEvent] {
        var events: [SessionEvent] = []
        events.reserveCapacity(lines.count)

        for (index, raw) in lines.enumerated() {
            events.append(contentsOf: decodeAll(line: raw, at: index))
        }
        return events
    }

    /// Decode a single line and return the primary event, or nil if
    /// the line is blank, malformed, or of a type we do not care about.
    /// A single line can in fact encode several events (e.g. an assistant
    /// message with embedded tool-call blocks plus its tool results on the
    /// same line) — callers that need every event for a line should use
    /// `decodeAll(line:at:)`. The `decode(line:at:)` entry point returns
    /// the first event only and is kept around for the live-tail path,
    /// which appends one event per appended line.
    package static func decode(line raw: String, at lineIndex: Int) -> SessionEvent? {
        let events = decodeAll(line: raw, at: lineIndex)
        if let message = events.first(where: {
            if case .message = $0 { return true }
            return false
        }) {
            return message
        }
        return events.first
    }

    /// Decode a single line and return *every* event encoded on it, in
    /// source order. Blank and malformed lines produce an empty array.
    package static func decodeAll(line raw: String, at lineIndex: Int) -> [SessionEvent] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }

        switch type {
        case "session", "session_info":
            guard let meta = decodeSessionMeta(from: object) else { return [] }
            return [.meta(meta, lineIndex: lineIndex)]
        case "message":
            return decodeMessageEvents(from: object, lineIndex: lineIndex)
        case "tool_use", "tool_call":
            guard let call = parseToolCall(object) else { return [] }
            return [.toolCall(call, lineIndex: lineIndex)]
        case "tool_result":
            guard let result = parseToolResult(object) else { return [] }
            return [.toolResult(result, lineIndex: lineIndex)]
        default:
            return [.other(type: type, lineIndex: lineIndex)]
        }
    }

    // MARK: - Field decoders

    package static func decodeSessionMeta(from object: [String: Any]) -> SessionMeta? {
        let id = stringValue(from: object, keys: ["sessionId", "sessionID", "id"])
        let cwd = stringValue(from: object, keys: ["cwd", "workingDirectory"])
        let parent = stringValue(from: object, keys: ["parentSession"])
        let name = stringValue(from: object, keys: ["name", "displayName", "title"])
        // Keep the meta block even if most fields are missing — the session
        // file's first line is usually the session declaration and we want
        // the working directory even when no session id is set yet.
        return SessionMeta(
            id: id ?? UUID().uuidString,
            workingDirectory: cwd,
            parentSession: parent,
            displayName: name
        )
    }

    /// Decode a `type: "message"` line into the events it represents. Pi
    /// stores tool-call blocks inline in the assistant content array and
    /// tool results as their own `role: "toolResult"` message, so a single
    /// line can expand to several events: the chat message itself plus
    /// zero or more tool calls. `role: "toolResult"` lines short-circuit
    /// to a single `SessionEvent.toolResult` so we never lose them.
    package static func decodeMessageEvents(from object: [String: Any], lineIndex: Int) -> [SessionEvent] {
        guard let payload = object["message"] as? [String: Any],
              let roleString = payload["role"] as? String
        else { return [] }

        if roleString == "toolResult" {
            guard let result = parseToolResultFromMessage(payload, parentID: object["id"] as? String) else {
                return []
            }
            return [.toolResult(result, lineIndex: lineIndex)]
        }

        guard let role = Message.Role(rawValue: roleString) else { return [] }

        let id = (object["id"] as? String)
            ?? (payload["id"] as? String)
            ?? (payload["responseId"] as? String)
            ?? (object["responseId"] as? String)
            ?? UUID().uuidString
        var content = parseContent(payload["content"])
        if content.isEmpty,
           role == .assistant,
           (payload["stopReason"] as? String) == "error",
           let errorMessage = (payload["errorMessage"] as? String)?.nilIfBlank {
            content = [.text("❌ \(errorMessage)")]
        }
        let model = (payload["model"] as? String) ?? (payload["modelId"] as? String)
        let parentId = (object["parentId"] as? String) ?? (payload["parentId"] as? String)
        let timestamp = parseTimestamp(object["timestamp"])
            ?? parseTimestamp(payload["timestamp"])

        let message = Message(
            id: id,
            role: role,
            content: content,
            model: model,
            timestamp: timestamp,
            parentId: parentId
        )

        guard role == .assistant,
              let rawBlocks = payload["content"] as? [[String: Any]] else {
            return [.message(message, lineIndex: lineIndex)]
        }

        let splitEvents = splitAssistantMessageEvents(
            baseID: id,
            rawBlocks: rawBlocks,
            role: role,
            model: model,
            timestamp: timestamp,
            parentId: parentId,
            lineIndex: lineIndex
        )
        return splitEvents.isEmpty ? [.message(message, lineIndex: lineIndex)] : splitEvents
    }

    /// Backwards-compatible wrapper that returns only the chat message for
    /// a `type: "message"` line. `toolResult` roles and inline tool-call
    /// blocks are dropped here; callers that care about every event on
    /// the line should use `decodeMessageEvents` instead.
    package static func decodeMessage(from object: [String: Any]) -> Message? {
        let events = decodeMessageEvents(from: object, lineIndex: 0)
        for event in events {
            if case .message(let message, _) = event { return message }
        }
        return nil
    }

    private static func parseContent(_ value: Any?) -> [ContentBlock] {
        if let text = value as? String {
            return text.isEmpty ? [] : [.text(text)]
        }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap(parseContentBlock)
        }
        return []
    }

    private static func splitAssistantMessageEvents(
        baseID: String,
        rawBlocks: [[String: Any]],
        role: Message.Role,
        model: String?,
        timestamp: Date?,
        parentId: String?,
        lineIndex: Int
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        var fragmentBlocks: [ContentBlock] = []
        var fragmentStartIndex: Int?
        let hasToolCall = rawBlocks.contains { parseToolCallFromContentBlock($0) != nil }

        func flushFragment() {
            guard !fragmentBlocks.isEmpty else { return }
            let startIndex = fragmentStartIndex ?? 0
            let fragmentID: String
            if hasToolCall, startIndex > 0 {
                fragmentID = "\(baseID)#block-\(startIndex)"
            } else {
                fragmentID = baseID
            }
            events.append(
                .message(
                    Message(
                        id: fragmentID,
                        role: role,
                        content: fragmentBlocks,
                        model: model,
                        timestamp: timestamp,
                        parentId: parentId
                    ),
                    lineIndex: lineIndex
                )
            )
            fragmentBlocks = []
            fragmentStartIndex = nil
        }

        for (blockIndex, block) in rawBlocks.enumerated() {
            if let call = parseToolCallFromContentBlock(block) {
                flushFragment()
                events.append(.toolCall(call, lineIndex: lineIndex))
                continue
            }
            if let contentBlock = parseContentBlock(block) {
                if fragmentStartIndex == nil {
                    fragmentStartIndex = blockIndex
                }
                fragmentBlocks.append(contentBlock)
            }
        }

        flushFragment()
        return events
    }

    private static func parseContentBlock(_ block: [String: Any]) -> ContentBlock? {
        let type = block["type"] as? String
        if type == "text", let text = block["text"] as? String {
            return text.isEmpty ? nil : .text(text)
        }
        if type == "thinking" {
            let thinking = (block["thinking"] as? String) ?? ""
            let signature = (block["thinkingSignature"] as? String) ?? (block["signature"] as? String)
            return .thinking(thinking, signature: signature)
        }
        if type == "image" {
            let blockMime = (block["mimeType"] as? String) ?? (block["media_type"] as? String)
            if let source = block["source"] as? [String: Any],
               let path = source["path"] as? String {
                let sourceMime = (source["mimeType"] as? String) ?? (source["media_type"] as? String)
                return .image(path: path, mime: sourceMime ?? blockMime)
            }
            if let path = block["path"] as? String {
                return .image(path: path, mime: blockMime)
            }
            if let fileName = block["fileName"] as? String {
                return .image(path: fileName, mime: blockMime)
            }
            if let source = block["source"] as? [String: Any],
               let data = source["data"] as? String {
                let sourceMime = (source["mimeType"] as? String) ?? (source["media_type"] as? String)
                let mime = sourceMime ?? blockMime ?? "image/png"
                return .image(path: "data:\(mime);base64,\(data)", mime: mime)
            }
            if let data = block["data"] as? String {
                let mime = blockMime ?? "image/png"
                return .image(path: "data:\(mime);base64,\(data)", mime: mime)
            }
        }
        if let text = block["text"] as? String {
            return text.isEmpty ? nil : .text(text)
        }
        return nil
    }

    private static func parseToolCall(_ object: [String: Any]) -> ToolCall? {
        let id = (object["id"] as? String) ?? UUID().uuidString
        let name = (object["name"] as? String) ?? (object["toolName"] as? String) ?? "tool"
        let arguments = stringifyArguments(object["input"] ?? object["arguments"])
        return .function(id: id, name: name, arguments: arguments)
    }

    /// Parse a `toolCall` content block embedded inside an assistant
    /// message. Pi uses `id`, `name`, and `arguments` (an object) inside
    /// content blocks — distinct from the top-level `tool_use` shape which
    /// exposes the payload as `input`.
    private static func parseToolCallFromContentBlock(_ block: [String: Any]) -> ToolCall? {
        guard (block["type"] as? String) == "toolCall" else { return nil }
        let id = (block["id"] as? String) ?? UUID().uuidString
        let name = (block["name"] as? String) ?? "tool"
        let arguments = stringifyArguments(block["arguments"] ?? block["input"])
        return .function(id: id, name: name, arguments: arguments)
    }

    private static func stringifyArguments(_ value: Any?) -> String {
        guard let value else { return "" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
           ),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(value)"
    }

    private static func parseToolResult(_ object: [String: Any]) -> ToolResult? {
        let callId = (object["toolCallId"] as? String) ?? (object["callId"] as? String) ?? ""
        let id = (object["id"] as? String) ?? stableToolResultID(for: callId)
        let toolName = (object["toolName"] as? String)
        let isError = (object["isError"] as? Bool) ?? false
        let details = object["details"]
        let output = outputWithDetails(
            text: stringifyToolResultContent(object["content"]),
            details: details
        )
        return .result(id: id, callId: callId, toolName: toolName, output: output, isError: isError, detailsJSON: detailsJSONString(details))
    }

    /// Parse a `role: "toolResult"` line that lives inside a `type: "message"`
    /// wrapper. The fields on the message payload mirror `ToolResultMessage`
    /// (`toolCallId`, `toolName`, `content`, `isError`, `timestamp`). The
    /// event id is taken from the outer message id when present so the chat
    /// view can de-duplicate against the live tail.
    private static func parseToolResultFromMessage(_ payload: [String: Any], parentID: String?) -> ToolResult? {
        let callId = (payload["toolCallId"] as? String) ?? (payload["callId"] as? String) ?? ""
        let id = parentID ?? (payload["id"] as? String) ?? stableToolResultID(for: callId)
        let toolName = (payload["toolName"] as? String)
        let isError = (payload["isError"] as? Bool) ?? false
        let details = payload["details"]
        let output = outputWithDetails(
            text: stringifyToolResultContent(payload["content"]),
            details: details
        )
        return .result(id: id, callId: callId, toolName: toolName, output: output, isError: isError, detailsJSON: detailsJSONString(details))
    }

    private static func stableToolResultID(for callId: String) -> String {
        callId.isEmpty ? UUID().uuidString : "toolResult:\(callId)"
    }

    private static func detailsJSONString(_ details: Any?) -> String? {
        guard let details,
              JSONSerialization.isValidJSONObject(details),
              let data = try? JSONSerialization.data(
                withJSONObject: details,
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func outputWithDetails(text: String, details: Any?) -> String {
        guard let details = details as? [String: Any],
              let diff = details["diff"] as? String,
              !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }
        return text + toolResultDiffSeparator + diff
    }

    private static func stringifyToolResultContent(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String {
            return text
        }
        if let blocks = value as? [[String: Any]] {
            let textBlocks = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            if !textBlocks.isEmpty {
                return textBlocks.joined(separator: "\n")
            }
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(value)"
    }

    private static func stringValue(from object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            return timestampParsers.parse(string)
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        case let integer as Int:
            return Date(timeIntervalSince1970: Double(integer) / 1000)
        case let double as Double:
            return Date(timeIntervalSince1970: double / 1000)
        default:
            return nil
        }
    }

    private static let timestampParsers = TimestampParsers()
}

private final class TimestampParsers: @unchecked Sendable {
    private let lock = NSLock()
    private let withFractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.withFractional = withFractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        self.plain = plain
    }

    func parse(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = withFractional.date(from: value) { return date }
        return plain.date(from: value)
    }
}
