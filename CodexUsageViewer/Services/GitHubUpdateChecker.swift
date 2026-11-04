import Combine
import Foundation

@MainActor
final class GitHubUpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let url: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    typealias Transport = @MainActor (URLRequest) async throws -> (Data, URLResponse)

    @Published private(set) var state: State = .idle

    private let currentVersion: String
    private let transport: Transport
    private var hasChecked = false

    init(currentVersion: String = CodexUsageViewerVersion.display,
         transport: @escaping Transport = GitHubUpdateChecker.fetch) {
        self.currentVersion = currentVersion
        self.transport = transport
    }

    /// Automatically check once per app session; an explicit check can always retry.
    func check(force: Bool = false) async {
        guard state != .checking, force || !hasChecked else { return }
        hasChecked = true
        state = .checking

        guard let installed = NumericVersion(currentVersion, allowsDevelopmentSuffix: true) else {
            state = .failed("This build’s version could not be compared with GitHub releases.")
            return
        }

        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/schneidermayer/claude-and-codex-usage-viewer/releases/latest")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Claude-and-Codex-Usage-Viewer", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await transport(request)
            guard let response = response as? HTTPURLResponse else {
                state = .failed("GitHub returned an invalid response. Try again later.")
                return
            }
            guard response.statusCode == 200 else {
                switch response.statusCode {
                case 404:
                    state = .failed("No published release is available on GitHub yet.")
                case 403, 429:
                    state = .failed("GitHub’s request limit was reached. Try again later.")
                default:
                    state = .failed("GitHub couldn’t complete the update check. Try again later.")
                }
                return
            }
            guard let latest = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                  !latest.draft, !latest.prerelease,
                  let version = NumericVersion(latest.tagName) else {
                state = .failed("GitHub returned an invalid release. Try again later.")
                return
            }
            if version > installed {
                // Build the link from the validated tag, never from a response-supplied URL.
                let url = URL(string: "https://github.com/schneidermayer/claude-and-codex-usage-viewer/releases/tag/\(latest.tagName)")!
                state = .available(Release(version: version.label, url: url))
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed("Couldn’t check for updates. Check your connection and try again.")
        }
    }

    private static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease
        }
    }

    private struct NumericVersion: Comparable {
        let label: String
        private let components: [Int]

        init?(_ value: String, allowsDevelopmentSuffix: Bool = false) {
            let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 1 || (allowsDevelopmentSuffix && pieces.count == 2 && Self.isDigits(pieces[1])) else {
                return nil
            }
            let base = pieces[0].hasPrefix("v") ? pieces[0].dropFirst() : pieces[0]
            let segments = base.split(separator: ".", omittingEmptySubsequences: false)
            guard (2...3).contains(segments.count), segments.allSatisfy(Self.isDigits) else { return nil }
            let values = segments.compactMap { Int($0) }
            guard values.count == segments.count else { return nil }
            label = String(base)
            components = values + Array(repeating: 0, count: 3 - values.count)
        }

        private static func isDigits(_ value: Substring) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
        }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.components == rhs.components }
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.components.lexicographicallyPrecedes(rhs.components)
        }
    }
}
