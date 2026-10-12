import Foundation
import OSLog

/// TEMPORARY diagnostics for the similar-character blank-profile report.
/// Logs only navigation operations and state transitions; never tokens or message content.
@MainActor
enum ProfileNavigationTrace {
    #if DEBUG
    private static let logger = Logger(subsystem: "CharacterAI.ProfileTrace", category: "navigation")
    private static var operationCounter = 0
    private(set) static var currentOperation = "op-0"

    #endif

    static func beginOperation(_ action: String, characterID: String?, stack: [String]) {
        #if DEBUG
        operationCounter += 1
        currentOperation = "op-\(operationCounter)"
        logger.notice("\(currentOperation, privacy: .public) \(action, privacy: .public) id=\(characterID ?? "nil", privacy: .private) stack=\(stack.joined(separator: ">"), privacy: .private)")
        #endif
    }

    static func log(_ message: String) {
        #if DEBUG
        logger.notice("\(currentOperation, privacy: .public) \(message, privacy: .private)")
        #endif
    }

    #if DEBUG
    private static let copySourceLogger = Logger(subsystem: "CharacterAI.ProfileTrace", category: "copy-source")
    #endif

    /// TEMPORARY: counts and IDs only, for the New Conversation copy-source search.
    static func logCopySource(_ message: String) {
        #if DEBUG
        copySourceLogger.notice("\(message, privacy: .private)")
        #endif
    }
}
