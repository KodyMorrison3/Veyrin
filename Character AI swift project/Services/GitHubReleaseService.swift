import Foundation

nonisolated struct GitHubRelease: Decodable, Sendable, Identifiable {
    let id: Int
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let isPrerelease: Bool
    let isDraft: Bool

    var isBeta: Bool {
        isPrerelease || tagName.localizedCaseInsensitiveContains("beta") ||
            (name?.localizedCaseInsensitiveContains("beta") ?? false)
    }

    var displayVersion: String {
        name.flatMap { $0.isEmpty ? nil : $0 } ?? tagName
    }

    func isNewerVersion(than currentVersion: String) -> Bool? {
        guard let latest = Self.versionComponents(in: tagName) ?? Self.versionComponents(in: name ?? ""),
              let current = Self.versionComponents(in: currentVersion) else { return nil }

        for index in 0..<max(latest.count, current.count) {
            let latestPart = index < latest.count ? latest[index] : 0
            let currentPart = index < current.count ? current[index] : 0
            if latestPart != currentPart { return latestPart > currentPart }
        }
        return false
    }

    private static func versionComponents(in value: String) -> [Int]? {
        let pattern = #"(?i)(?:^|[^0-9])v?([0-9]+(?:\.[0-9]+){1,3})(?=$|[^0-9.])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return value[range].split(separator: ".").compactMap { Int($0) }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case isPrerelease = "prerelease"
        case isDraft = "draft"
    }
}

nonisolated struct GitHubReleaseService {
    private let session: URLSession
    private let repository = "KodyMorrison3/Veyrin"

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease(includeBeta: Bool) async throws -> GitHubRelease {
        let official: GitHubRelease?
        do {
            official = try await fetch("releases/latest")
        } catch GitHubReleaseError.notFound where includeBeta {
            official = nil
        }

        guard includeBeta else {
            guard let official else { throw GitHubReleaseError.noReleases }
            return official
        }

        let releases: [GitHubRelease] = try await fetch("releases?per_page=100")
        let latestBeta = releases
            .filter({ !$0.isDraft && $0.isBeta })
            .max(by: { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) })
        guard let latestBeta else {
            guard let official else { throw GitHubReleaseError.noReleases }
            return official
        }
        guard let official else { return latestBeta }
        guard let betaDate = latestBeta.publishedAt,
              let officialDate = official.publishedAt else { return official }
        if betaDate > officialDate { return latestBeta }
        return official
    }

    private func fetch<Response: Decodable & Sendable>(_ path: String) async throws -> Response {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/\(path)") else {
            throw GitHubReleaseError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Veyrin macOS app", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw GitHubReleaseError.invalidResponse
            }
            guard 200..<300 ~= response.statusCode else {
                if response.statusCode == 404 {
                    throw GitHubReleaseError.notFound
                }
                if response.statusCode == 401 || response.statusCode == 403 {
                    throw GitHubReleaseError.accessDenied
                }
                throw GitHubReleaseError.httpError(response.statusCode)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Response.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitHubReleaseError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw GitHubReleaseError.requestFailed(error.localizedDescription)
        }
    }
}

nonisolated private enum GitHubReleaseError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case noReleases
    case notFound
    case accessDenied
    case httpError(Int)
    case requestFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The GitHub releases URL is invalid."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .noReleases:
            return "No releases were found for this repository."
        case .notFound:
            return "The repository or its releases could not be found. Check that the repository is public and has a release published."
        case .accessDenied:
            return "GitHub denied access to the releases API. Try again later."
        case .httpError(let statusCode):
            return "GitHub returned HTTP \(statusCode) while checking for releases."
        case .requestFailed(let message):
            return "Could not check GitHub releases: \(message)"
        }
    }
}
