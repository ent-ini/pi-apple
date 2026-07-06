import Foundation

public struct PiModelOption: Identifiable, Hashable, Codable, Sendable {
    public let provider: String
    public let modelID: String
    public let name: String?
    public let reasoning: Bool
    public let contextWindow: Int?

    public init(provider: String, modelID: String, name: String?, reasoning: Bool, contextWindow: Int?) {
        self.provider = provider
        self.modelID = modelID
        self.name = name
        self.reasoning = reasoning
        self.contextWindow = contextWindow
    }

    public var id: String { "\(provider)/\(modelID)" }
    public var displayName: String { id }
    public var shortLabel: String { modelID }
}

public struct DefaultModelPreference: Hashable, Codable, Sendable {
    public let provider: String
    public let modelID: String
    public var thinkingLevel: String?

    public init(provider: String, modelID: String, thinkingLevel: String? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
    }

    public var id: String { "\(provider)/\(modelID)" }
}

public struct SessionTokenTotals: Hashable, Codable, Sendable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let total: Int

    public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, total: Int) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }

    public static let zero = SessionTokenTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
}

public struct SessionContextUsage: Hashable, Codable, Sendable {
    public let tokens: Int?
    public let contextWindow: Int?
    public let percent: Double?

    public init(tokens: Int?, contextWindow: Int?, percent: Double?) {
        self.tokens = tokens
        self.contextWindow = contextWindow
        self.percent = percent
    }
}

public struct SessionRuntimeState: Hashable, Codable, Sendable {
    public let sessionID: String?
    public let sessionPath: String?
    public let provider: String?
    public let modelID: String?
    public let modelName: String?
    public let thinkingLevel: String
    public let tokens: SessionTokenTotals
    public let contextUsage: SessionContextUsage?

    public init(
        sessionID: String?,
        sessionPath: String?,
        provider: String?,
        modelID: String?,
        modelName: String?,
        thinkingLevel: String,
        tokens: SessionTokenTotals,
        contextUsage: SessionContextUsage?
    ) {
        self.sessionID = sessionID
        self.sessionPath = sessionPath
        self.provider = provider
        self.modelID = modelID
        self.modelName = modelName
        self.thinkingLevel = thinkingLevel
        self.tokens = tokens
        self.contextUsage = contextUsage
    }

    public var modelDisplayName: String {
        modelID?.nilIfBlank ?? modelName?.nilIfBlank ?? "no-model"
    }
}
