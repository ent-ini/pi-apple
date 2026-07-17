import Foundation

public struct SubagentSession: Identifiable, Hashable, Sendable {
    public let id: String
    public let callId: String
    public let name: String
    public let model: String?
    public let task: String
    public let cwd: String?
    public let status: String
    public let output: String?
    public let isError: Bool
    public let lineIndex: Int
    public let events: [SessionEvent]

    public var displayModel: String {
        model?.nilIfBlank ?? "default model"
    }

    public var displayStatus: String {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (output == nil ? "running" : "completed") : value
    }

    public var taskPreview: String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No task text" }
        return trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Set `includeDetailEvents` to `false` to build lightweight rows without
    /// eagerly decoding nested transcripts stored in subagent tool results.
    public static func extract(from events: [SessionEvent], includeDetailEvents: Bool = true) -> [SubagentSession] {
        var calls: [(call: ToolCall, lineIndex: Int)] = []
        var subagentCallIDs = Set<String>()

        for event in events {
            guard case .toolCall(let call, let lineIndex) = event,
                  call.name == "subagent" else {
                continue
            }
            calls.append((call, lineIndex))
            subagentCallIDs.insert(call.id)
        }

        var resultsByCallId: [String: ToolResult] = [:]
        for event in events {
            guard case .toolResult(let result, _) = event,
                  result.toolName == "subagent" || subagentCallIDs.contains(result.callId) else {
                continue
            }
            resultsByCallId[result.callId] = result
        }

        return calls.flatMap { call, lineIndex in
            let specs = SubagentToolArguments.decode(from: call.arguments).expandedSpecs
            let result = resultsByCallId[call.id]
            var sections = includeDetailEvents ? SubagentOutputSection.parse(result?.output ?? "") : []
            let detailedEventsByIndex = includeDetailEvents
                ? subagentDetailEventsByIndex(from: result, callLineIndex: lineIndex)
                : [:]

            return specs.enumerated().map { index, spec in
                let matchedSectionIndex = sections.firstIndex { section in
                    section.name == spec.displayName && !section.isConsumed
                }
                let section = matchedSectionIndex.map { sections[$0] }
                if let matchedSectionIndex {
                    sections[matchedSectionIndex].isConsumed = true
                }

                let output = includeDetailEvents
                    ? (section?.body.nilIfBlank ?? fallbackOutput(for: result, index: index, total: specs.count))
                    : nil
                let status = result?.isError == true
                    ? "error"
                    : (includeDetailEvents
                        ? (section?.status.nilIfBlank ?? (result == nil ? "running" : "completed"))
                        : (result == nil ? "running" : "completed"))

                return SubagentSession(
                    id: "subagent:\(call.id):\(index)",
                    callId: call.id,
                    name: spec.displayName,
                    model: spec.displayModel,
                    task: spec.task ?? "",
                    cwd: spec.cwd,
                    status: status,
                    output: output,
                    isError: result?.isError ?? false,
                    lineIndex: lineIndex,
                    events: includeDetailEvents
                        ? (detailedEventsByIndex[index] ?? fallbackEvents(task: spec.task, output: output, model: spec.displayModel, idPrefix: "subagent:\(call.id):\(index)"))
                        : []
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex > rhs.lineIndex }
            return lhs.id > rhs.id
        }
    }

    private static func subagentDetailEventsByIndex(from result: ToolResult?, callLineIndex: Int) -> [Int: [SessionEvent]] {
        guard let detailsJSON = result?.detailsJSON,
              let data = detailsJSON.data(using: .utf8),
              let details = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = details["results"] as? [[String: Any]] else {
            return [:]
        }

        var output: [Int: [SessionEvent]] = [:]
        for (index, subagentResult) in results.enumerated() {
            guard let messages = subagentResult["messages"] as? [[String: Any]] else { continue }
            let events = messages.enumerated().flatMap { messageIndex, payload in
                Self.events(fromSubagentMessagePayload: payload, callLineIndex: callLineIndex, messageIndex: messageIndex, subagentIndex: index)
            }
            if !events.isEmpty {
                output[index] = events
            }
        }
        return output
    }

    private static func events(fromSubagentMessagePayload payload: [String: Any], callLineIndex: Int, messageIndex: Int, subagentIndex: Int) -> [SessionEvent] {
        var wrapper: [String: Any] = [
            "type": "message",
            "id": "subagent-detail:\(callLineIndex):\(subagentIndex):\(messageIndex)",
            "message": payload
        ]
        if let timestamp = payload["timestamp"] {
            wrapper["timestamp"] = timestamp
        }
        guard JSONSerialization.isValidJSONObject(wrapper),
              let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let raw = String(data: data, encoding: .utf8) else {
            return []
        }
        // Detail rows are synthetic and are never merged into the parent
        // session's JSONL timeline. Do not derive their line numbers from the
        // source call: live tool calls use a near-`Int.max` transient sentinel,
        // and multiplication would overflow and trap while opening the panel.
        return SessionEventParser.decodeAll(line: raw, at: messageIndex)
    }

    private static func fallbackEvents(task: String?, output: String?, model: String?, idPrefix: String) -> [SessionEvent] {
        var events: [SessionEvent] = [
            .message(
                Message(
                    id: "\(idPrefix):task",
                    role: .user,
                    content: [.text(task?.nilIfBlank ?? "Subagent task")],
                    model: nil,
                    timestamp: nil,
                    parentId: nil
                ),
                lineIndex: 0
            )
        ]
        events.append(
            .message(
                Message(
                    id: "\(idPrefix):output",
                    role: .assistant,
                    content: [.text(output?.nilIfBlank ?? "Waiting for subagent output…")],
                    model: model,
                    timestamp: nil,
                    parentId: nil
                ),
                lineIndex: 1
            )
        )
        return events
    }

    private static func fallbackOutput(for result: ToolResult?, index: Int, total: Int) -> String? {
        guard let result else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // For a single subagent older sessions sometimes store just the raw
        // subagent reply without per-agent markdown sections. For parallel
        // runs, avoid duplicating the whole combined payload into every row.
        return total == 1 ? trimmed : nil
    }
}

private struct SubagentToolArguments: Decodable {
    var task: String?
    var cwd: String?
    var temporaryAgent: SubagentTemporaryAgent?
    var name: String?
    var model: String?
    var description: String?
    var systemPrompt: String?
    var tools: [String]?
    var tasks: [SubagentTaskSpec]?

    var expandedSpecs: [SubagentTaskSpec] {
        if let tasks, !tasks.isEmpty { return tasks }
        return [
            SubagentTaskSpec(
                task: task,
                cwd: cwd,
                temporaryAgent: temporaryAgent,
                name: name,
                model: model,
                description: description,
                systemPrompt: systemPrompt,
                tools: tools
            )
        ]
    }

    static func decode(from arguments: String) -> SubagentToolArguments {
        guard let data = arguments.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SubagentToolArguments.self, from: data) else {
            return SubagentToolArguments(task: nil, cwd: nil, temporaryAgent: nil, name: nil, model: nil, description: nil, systemPrompt: nil, tools: nil, tasks: nil)
        }
        return decoded
    }
}

private struct SubagentTaskSpec: Decodable, Hashable, Sendable {
    var task: String?
    var cwd: String?
    var temporaryAgent: SubagentTemporaryAgent?
    var name: String?
    var model: String?
    var description: String?
    var systemPrompt: String?
    var tools: [String]?

    var displayName: String {
        temporaryAgent?.name?.nilIfBlank
            ?? name?.nilIfBlank
            ?? description?.nilIfBlank
            ?? "Subagent"
    }

    var displayModel: String? {
        temporaryAgent?.model?.nilIfBlank ?? model?.nilIfBlank
    }
}

private struct SubagentTemporaryAgent: Decodable, Hashable, Sendable {
    var name: String?
    var description: String?
    var systemPrompt: String?
    var model: String?
    var tools: [String]?
}

private struct SubagentOutputSection: Hashable {
    var name: String
    var status: String
    var body: String
    var isConsumed = false

    static func parse(_ output: String) -> [SubagentOutputSection] {
        let pattern = #"(?ms)^### \[(.*?)\] ([^\n]+)\n\n(.*?)(?=\n---\n\n### \[|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(output.startIndex..., in: output)
        return regex.matches(in: output, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 4,
                  let nameRange = Range(match.range(at: 1), in: output),
                  let statusRange = Range(match.range(at: 2), in: output),
                  let bodyRange = Range(match.range(at: 3), in: output) else { return nil }
            return SubagentOutputSection(
                name: String(output[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                status: String(output[statusRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                body: cleanSectionBody(String(output[bodyRange]))
            )
        }
    }

    private static func cleanSectionBody(_ body: String) -> String {
        body
            .replacingOccurrences(of: #"\n---\s*\z"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
