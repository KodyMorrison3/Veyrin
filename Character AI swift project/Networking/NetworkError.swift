import Foundation

enum NetworkError: Error {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(Error)
    case requestFailed(Error)
    case unauthenticated
    case serverMessage(String)
    
}

extension NetworkError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The request URL was invalid."

        case .invalidResponse:
            return "The server returned an invalid response."

        case .httpError(let statusCode):
            return "The server returned HTTP \(statusCode)."

        case .decodingError(let error):
            return "Failed to decode the server response.\(Self.decodingPathDetail(error))"

        case .requestFailed:
            return "The network request failed. Check your connection and try again."

        case .unauthenticated:
            return "Your Character.AI session has expired."

        case .serverMessage(let message):
            return message
        }
    }

    /// Names the key path that failed, so a missing or mistyped field is identifiable.
    private static func decodingPathDetail(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return "" }
        let detail: String
        switch decodingError {
        case .keyNotFound(let key, let context):
            detail = "missing field '\(keyPath(context.codingPath + [key]))'"
        case .valueNotFound(_, let context):
            detail = "missing value at '\(keyPath(context.codingPath))'"
        case .typeMismatch(_, let context):
            detail = "wrong type at '\(keyPath(context.codingPath))'"
        case .dataCorrupted(let context):
            detail = "corrupt data at '\(keyPath(context.codingPath))'"
        @unknown default:
            return ""
        }
        return " [\(detail)]"
    }

    private static func keyPath(_ codingPath: [CodingKey]) -> String {
        codingPath.map { key in
            key.intValue.map { "[\($0)]" } ?? key.stringValue
        }
        .joined(separator: ".")
        .replacingOccurrences(of: ".[", with: "[")
    }
}
