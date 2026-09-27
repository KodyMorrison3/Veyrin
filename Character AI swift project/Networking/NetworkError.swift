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
            return "Failed to decode the server response: \(error.localizedDescription)"

        case .requestFailed(let error):
            return "The network request failed: \(error.localizedDescription)"

        case .unauthenticated:
            return "Your Character.AI session has expired."

        case .serverMessage(let message):
            return message
        }
    }
}
