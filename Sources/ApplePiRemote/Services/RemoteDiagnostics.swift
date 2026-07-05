import Foundation

public struct RemoteDiagnosticEvent: Sendable {
    public let level: String
    public let category: String
    public let message: String
    public let metadata: [String: String]

    public init(level: String, category: String, message: String, metadata: [String: String] = [:]) {
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

public enum RemoteDiagnostics {
    public nonisolated(unsafe) static var sink: (@Sendable (RemoteDiagnosticEvent) -> Void)?

    public static func log(
        level: String,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        sink?(RemoteDiagnosticEvent(
            level: level,
            category: category,
            message: message,
            metadata: metadata
        ))
    }
}
