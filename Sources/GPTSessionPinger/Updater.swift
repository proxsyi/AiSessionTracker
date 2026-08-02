import Foundation
import AppKit

enum UpdaterError: LocalizedError {
    case badAssetURL
    case downloadFailed(String)
    case unzipFailed
    case noAppFoundInArchive
    case bundleIdentifierMismatch

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
        case .bundleIdentifierMismatch:
            return "The downloaded update belongs to a different app and was not installed."
        }
    }
}

/// Downloads a new release's app bundle from GitHub, swaps it in for this
/// running app, and relaunches it. There's no Sparkle-style signed-update
/// framework here -- this is a small hand-rolled updater appropriate for a
/// single-user personal app pulling from a private repo only you control.
@MainActor
enum Updater {
    static func downloadAndInstall(_ update: UpdateInfo) async throws {
        guard let assetURL = URL(string: update.assetAPIURL) else {
            throw UpdaterError.badAssetURL
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

        let extractedContents = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
        guard let newAppPath = extractedContents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.noAppFoundInArchive
        }

        let currentAppPath = URL(fileURLWithPath: Bundle.main.bundlePath)
        guard Bundle(url: newAppPath)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdaterError.bundleIdentifierMismatch
        }
        let scriptURL = workDir.appendingPathComponent("install.sh")
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do
            sleep 0.2
        done
        rm -rf "\(currentAppPath.path)"
        mv "\(newAppPath.path)" "\(currentAppPath.path)"
        xattr -dr com.apple.quarantine "\(currentAppPath.path)" 2>/dev/null
        open "\(currentAppPath.path)"
        rm -rf "\(workDir.path)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments = [scriptURL.path]
        installer.standardOutput = FileHandle.nullDevice
        installer.standardError = FileHandle.nullDevice
        try installer.run()

        NSApp.terminate(nil)
    }
}
