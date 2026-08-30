import Foundation
import AppKit
import TrackerDesignSystem

enum UpdaterError: LocalizedError {
    case badAssetURL
    case downloadFailed(String)
    case unzipFailed
    case noAppFoundInArchive
    case untrustedUpdate(String)

    var errorDescription: String? {
        switch self {
        case .badAssetURL:
            return "The release asset URL looked invalid."
        case .downloadFailed(let message):
            return "Couldn't download the update: \(message)"
        case .unzipFailed:
            return "Couldn't unzip the downloaded update."
        case .noAppFoundInArchive:
            return "The downloaded update didn't contain an app bundle."
        case .untrustedUpdate(let message):
            return "The downloaded update was not installed: \(message)"
        }
    }
}

/// Downloads a new release's app bundle from GitHub, swaps it in for this
/// running app, and relaunches it after verifying its Developer ID signature,
/// hardened runtime, bundle identity, signing team, and Apple notarization.
@MainActor
enum Updater {
    static func downloadAndInstall(_ update: UpdateInfo) async throws {
        guard let assetURL = URL(string: update.assetAPIURL) else {
            throw UpdaterError.badAssetURL
        }
        do {
            try TrackerSecureUpdate.validateAssetURL(assetURL)
        } catch {
            throw UpdaterError.untrustedUpdate(error.localizedDescription)
        }

        var request = URLRequest(url: assetURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 180

        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdaterError.downloadFailed("Server returned an unexpected response.")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPTUsageTrackerUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var installerStarted = false
        defer {
            if !installerStarted { try? FileManager.default.removeItem(at: workDir) }
        }
        let zipPath = workDir.appendingPathComponent(UpdateFeed.assetName)
        try FileManager.default.moveItem(at: downloadedURL, to: zipPath)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipPath.path, workDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw UpdaterError.unzipFailed
        }

        let currentAppPath = URL(fileURLWithPath: Bundle.main.bundlePath)
        let newAppPath: URL
        do {
            newAppPath = try TrackerSecureUpdate.locateTopLevelApp(in: workDir)
            try TrackerSecureUpdate.verifyApp(
                at: newAppPath,
                expectedBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
            )
            try TrackerSecureUpdate.launchInstaller(
                currentApp: currentAppPath,
                newApp: newAppPath,
                workDirectory: workDir,
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            )
            installerStarted = true
        } catch {
            throw UpdaterError.untrustedUpdate(error.localizedDescription)
        }

        NSApp.terminate(nil)
    }
}
