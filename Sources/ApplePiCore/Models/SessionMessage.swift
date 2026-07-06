import Foundation

public let toolResultDiffSeparator = "\n\n__PI_APP_TOOL_DIFF__\n"

/// Metadata extracted from a `type: "session"` line in a Pi `.jsonl` file.
public struct SessionMeta: Hashable, Sendable {
    public let id: String
    public let workingDirectory: String?
    public let parentSession: String?
    public let displayName: String?

    public init(id: String, workingDirectory: String?, parentSession: String?, displayName: String?) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.parentSession = parentSession
        self.displayName = displayName
    }
}

/// One block inside a message's `content` array. Pi stores text and image
/// blocks the same way Claude does, so we mirror that shape.
public enum ContentBlock: Hashable, Sendable {
    case text(String)
    case thinking(String, signature: String?)
    case image(path: String, mime: String?)
}

/// A single user / assistant / system turn in a Pi session.
public struct Message: Identifiable, Hashable, Sendable {
    public let id: String
    public let role: Role
    public let content: [ContentBlock]
    public let model: String?
    public let timestamp: Date?
    public let parentId: String?

    public init(id: String, role: Role, content: [ContentBlock], model: String?, timestamp: Date?, parentId: String?) {
        self.id = id
        self.role = role
        self.content = content
        self.model = model
        self.timestamp = timestamp
        self.parentId = parentId
    }

    public enum Role: String, Hashable, Sendable {
        case user
        case assistant
        case system
    }
}

/// A tool invocation emitted by the assistant. Pi may use a few shapes
/// (`tool_use`, `tool_call`); we normalise to a single model here.
public enum ToolCall: Identifiable, Hashable, Sendable {
    case function(id: String, name: String, arguments: String)

    public var id: String {
        switch self {
        case .function(let id, _, _): return id
        }
    }

    public var name: String {
        switch self {
        case .function(_, let name, _): return name
        }
    }

    public var arguments: String {
        switch self {
        case .function(_, _, let arguments): return arguments
        }
    }
}

/// The outcome of a tool invocation, paired with the originating call id.
public enum ToolResult: Identifiable, Hashable, Sendable {
    case result(id: String, callId: String, toolName: String?, output: String, isError: Bool, detailsJSON: String? = nil)

    public var id: String {
        switch self {
        case .result(let id, _, _, _, _, _): return id
        }
    }

    public var callId: String {
        switch self {
        case .result(_, let callId, _, _, _, _): return callId
        }
    }

    public var toolName: String? {
        switch self {
        case .result(_, _, let toolName, _, _, _): return toolName
        }
    }

    public var output: String {
        switch self {
        case .result(_, _, _, let output, _, _): return output
        }
    }

    public var isError: Bool {
        switch self {
        case .result(_, _, _, _, let isError, _): return isError
        }
    }

    public var detailsJSON: String? {
        switch self {
        case .result(_, _, _, _, _, let detailsJSON): return detailsJSON
        }
    }
}

/// Every meaningful line in a Pi session, decoded once into a typed value.
/// The chat view filters and lays these out; non-message events can be
/// rendered as collapsible tool blocks or simply skipped during read-only
/// rendering.
public enum SessionEvent: Identifiable, Hashable, Sendable {
    case meta(SessionMeta, lineIndex: Int)
    case message(Message, lineIndex: Int)
    case toolCall(ToolCall, lineIndex: Int)
    case toolResult(ToolResult, lineIndex: Int)
    case other(type: String, lineIndex: Int)

    /// The line in the source `.jsonl` file this event came from. Used for
    /// pagination and source ordering; SwiftUI identity is based on the
    /// event payload so streamed rows do not flicker when a persisted line
    /// receives its final index.
    public var lineIndex: Int {
        switch self {
        case .meta(_, let index),
             .message(_, let index),
             .toolCall(_, let index),
             .toolResult(_, let index),
             .other(_, let index):
            return index
        }
    }

    /// Whether this event should appear as a transcript row. Runtime
    /// bookkeeping is still parsed and stored so model/thinking/context chips
    /// can use it, but the chat feed should stay focused on messages and
    /// meaningful tool/bookmark events.
    public var isVisibleInTranscript: Bool {
        switch self {
        case .meta:
            return false
        case .other(let type, _):
            return !Self.hiddenTranscriptEventTypes.contains(type)
        case .message(let message, _):
            return message.hasVisibleTranscriptContent
        case .toolCall, .toolResult:
            return true
        }
    }

    private static let hiddenTranscriptEventTypes: Set<String> = [
        "model_change",
        "thinking_level_change",
        "session_info",
        "compaction",
        "compaction_start",
        "compaction_end"
    ]

    public var id: String {
        switch self {
        case .meta(let meta, _): return "meta:\(meta.id)"
        case .message(let msg, _): return "message:\(msg.id)"
        case .toolCall(let call, _): return "toolCall:\(call.id)"
        case .toolResult(let result, _): return "toolResult:\(result.id)"
        case .other(let type, let index): return "other:\(type):\(index)"
        }
    }
}

private extension Message {
    var hasVisibleTranscriptContent: Bool {
        content.contains { block in
            switch block {
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image:
                return true
            case .thinking(let text, _):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }
}
