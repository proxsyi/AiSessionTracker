import Foundation

public enum TrackerSecureUpdateError: LocalizedError {
    case invalidAssetURL
    case invalidApplicationPath
    case unexpectedArchiveContents
    case signatureRejected(String)
    case identityMismatch
    case hardenedRuntimeMissing
    case notarizationRejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAssetURL:
            return "The release asset did not come from the expected GitHub repository."
        case .invalidApplicationPath:
            return "The update contained an unsafe application path."
        case .unexpectedArchiveContents:
            return "The update must contain exactly one top-level app bundle."
        case .signatureRejected(let detail):
            return "The update's code signature was rejected: \(detail)"
        case .identityMismatch:
            return "The update was not signed by the expected Developer ID owner."
        case .hardenedRuntimeMissing:
            return "The update was not built with Apple's hardened runtime."
        case .notarizationRejected(let detail):
            return "Apple did not accept the update as notarized: \(detail)"
        }
    }
}

public enum TrackerSecureUpdate {
    public static let expectedGitHubRepositoryPath = "/repos/proxsyi/AiSessionTracker/releases/assets/"
    public static let expectedTeamIdentifier = "7JX38C53N8"

    public static func validateAssetURL(_ url: URL) throws {
        guard url.scheme == "https",
              url.host?.lowercased() == "api.github.com",
              url.path.hasPrefix(expectedGitHubRepositoryPath) else {
            throw TrackerSecureUpdateError.invalidAssetURL
        }
    }

    public static func locateTopLevelApp(in workDirectory: URL) throws -> URL {
        let values: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let contents = try FileManager.default.contentsOfDirectory(
            at: workDirectory,
            includingPropertiesForKeys: values,
            options: [.skipsHiddenFiles]
        )
        let apps = try contents.filter { url in
            guard url.pathExtension.lowercased() == "app" else { return false }
            let resourceValues = try url.resourceValues(forKeys: Set(values))
            return resourceValues.isDirectory == true && resourceValues.isSymbolicLink != true
        }
        guard apps.count == 1 else { throw TrackerSecureUpdateError.unexpectedArchiveContents }

        let root = workDirectory.standardizedFileURL.path + "/"
        let app = apps[0].standardizedFileURL
        guard app.path.hasPrefix(root), app.pathExtension.lowercased() == "app" else {
            throw TrackerSecureUpdateError.invalidApplicationPath
        }
        return app
    }

    public static func verifyApp(
        at appURL: URL,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String = expectedTeamIdentifier
    ) throws {
        guard appURL.isFileURL,
              appURL.pathExtension.lowercased() == "app",
              Bundle(url: appURL)?.bundleIdentifier == expectedBundleIdentifier else {
            throw TrackerSecureUpdateError.identityMismatch
        }

        let verification = try run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
        )
        guard verification.status == 0 else {
            throw TrackerSecureUpdateError.signatureRejected(verification.message)
        }

        let details = try run(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "--verbose=4", appURL.path]
        )
        guard details.message.contains("Identifier=\(expectedBundleIdentifier)"),
              details.message.contains("TeamIdentifier=\(expectedTeamIdentifier)"),
              details.message.contains("Authority=Developer ID Application:") else {
            throw TrackerSecureUpdateError.identityMismatch
        }
        guard details.message.contains("Runtime Version=") else {
            throw TrackerSecureUpdateError.hardenedRuntimeMissing
        }

        let assessment = try run(
            executable: "/usr/sbin/spctl",
            arguments: ["--assess", "--type", "execute", "--verbose=4", appURL.path]
        )
        guard assessment.status == 0,
              assessment.message.localizedCaseInsensitiveContains("notarized developer id") else {
            throw TrackerSecureUpdateError.notarizationRejected(assessment.message)
        }
    }

    public static func launchInstaller(
        currentApp: URL,
        newApp: URL,
        workDirectory: URL,
        processIdentifier: Int32
    ) throws {
        let current = currentApp.standardizedFileURL
        let replacement = newApp.standardizedFileURL
        let work = workDirectory.standardizedFileURL
        guard current.isFileURL,
              current.pathExtension.lowercased() == "app",
              current.path != "/",
              replacement.path.hasPrefix(work.path + "/"),
              replacement.pathExtension.lowercased() == "app" else {
            throw TrackerSecureUpdateError.invalidApplicationPath
        }

        let scriptURL = work.appendingPathComponent("install.sh")
        try installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments = [
            scriptURL.path,
            String(processIdentifier),
            current.path,
            replacement.path,
            work.path
        ]
        installer.standardOutput = FileHandle.nullDevice
        installer.standardError = FileHandle.nullDevice
        try installer.run()
    }

    public static let installerScript = """
    #!/bin/bash
    set -u
    pid="$1"
    current_app="$2"
    new_app="$3"
    work_dir="$4"
    backup_app="$work_dir/previous.app"

    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
    done
    if [[ ! -d "$current_app" || ! -d "$new_app" ]]; then
        exit 1
    fi
    mv "$current_app" "$backup_app" || exit 1
    if mv "$new_app" "$current_app"; then
        open "$current_app"
        rm -rf "$work_dir"
        exit 0
    fi
    mv "$backup_app" "$current_app"
    open "$current_app"
    rm -rf "$work_dir"
    exit 1
    """

    private static func run(executable: String, arguments: [String]) throws -> (status: Int32, message: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, message)
    }
}
