import Foundation

@MainActor
enum PresentationDate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSeconds = ISO8601DateFormatter()

    static func parse(_ value: String) -> Date? {
        fractional.date(from: value) ?? wholeSeconds.date(from: value)
    }
}
