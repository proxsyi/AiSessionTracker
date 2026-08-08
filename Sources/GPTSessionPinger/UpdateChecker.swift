import Foundation

/// Where this app checks for new releases: the public GitHub Releases API
/// for this repo. Each GPT release must be tagged like "gpt-v1.17.1" and have a
/// zipped app bundle attached as an asset named `assetName` below --
/// `Scripts/release.sh` builds and publishes that automatically. Because the
/// repo is public, no token or auth is needed to read releases.
enum UpdateFeed {
    /// GPT releases share the repository with Claude releases, so this app
    /// reads the release list and accepts only `gpt-v*` tags carrying the GPT
    /// asset. The two installed apps can therefore update independently.
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/proxsyi/AiSessionTracker/releases?per_page=30")!
    static let tagPrefix = "gpt-v"
    static let assetName = "GPTSessionPinger.app.zip"
}

struct UpdateInfo: Equatable {
    let version: String
    let releasePageURL: String
    let notes: String?
    /// GitHub API URL for the release asset itself -- fetching it requires
    /// the same auth token and an `Accept: application/octet-stream` header.
    /// See `Updater.swift`.
    let assetAPIURL: String
}

enum UpdateCheckResult: Equatable {
    case upToDate
    case updateAvailable(UpdateInfo)
    case failed(String)
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let url: String
    }
    let tag_name: String
    let html_url: String
    let body: String?
    let assets: [Asset]
}

enum UpdateChecker {
    /// Compares two dotted version strings numerically (e.g. "1.10.0" > "1.9.3"),
    /// rather than lexicographically, so double-digit components sort correctly.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateParts = versionParts(candidate),
              let currentParts = versionParts(current) else { return false }
        let count = max(candidateParts.count, currentParts.count)
        for i in 0..<count {
            let c = i < candidateParts.count ? candidateParts[i] : 0
            let d = i < currentParts.count ? currentParts[i] : 0
            if c != d { return c > d }
        }
        return false
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let core = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
        let pieces = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var result: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, let number = Int(piece), number >= 0 else { return nil }
            result.append(number)
        }
        return result
    }

    static func check(currentVersion: String) async -> UpdateCheckResult {
        do {
            var request = URLRequest(url: UpdateFeed.latestReleaseAPIURL)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Couldn't reach GitHub.")
            }
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 404 {
                    return .failed("No releases found yet.")
                }
                return .failed("GitHub returned an unexpected response (\(http.statusCode)).")
            }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            guard let release = releases.first(where: { release in
                release.tag_name.hasPrefix(UpdateFeed.tagPrefix)
                    && release.assets.contains(where: { $0.name == UpdateFeed.assetName })
            }) else {
                return .failed("No GPT releases found yet.")
            }
            let version = String(release.tag_name.dropFirst(UpdateFeed.tagPrefix.count))
            guard isNewer(version, than: currentVersion) else {
                return .upToDate
            }
            guard let asset = release.assets.first(where: { $0.name == UpdateFeed.assetName }) else {
                return .failed("Release \(release.tag_name) is missing its \(UpdateFeed.assetName) asset.")
            }
            let info = UpdateInfo(version: version, releasePageURL: release.html_url, notes: release.body, assetAPIURL: asset.url)
            return .updateAvailable(info)
        } catch {
            return .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }
}
