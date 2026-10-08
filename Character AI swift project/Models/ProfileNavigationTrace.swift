import Foundation
import OSLog

/// TEMPORARY diagnostics for the similar-character blank-profile report.
/// Logs only navigation operations and state transitions; never tokens or message content.
@MainActor
enum ProfileNavigationTrace {
    private static let logger = Logger(subsystem: "CharacterAI.ProfileTrace", category: "navigation")
    private static var operationCounter = 0
    private(set) static var currentOperation = "op-0"

    static func beginOperation(_ action: String, characterID: String?, stack: [String]) {
        operationCounter += 1
        currentOperation = "op-\(operationCounter)"
        logger.notice("\(currentOperation, privacy: .public) \(action, privacy: .public) id=\(characterID ?? "nil", privacy: .public) stack=\(stack.joined(separator: ">"), privacy: .public)")
    }

    static func log(_ message: String) {
        logger.notice("\(currentOperation, privacy: .public) \(message, privacy: .public)")
    }

    private static let copySourceLogger = Logger(subsystem: "CharacterAI.ProfileTrace", category: "copy-source")

    /// TEMPORARY: counts and IDs only, for the New Conversation copy-source search.
    static func logCopySource(_ message: String) {
        copySourceLogger.notice("\(message, privacy: .public)")
    }
}
