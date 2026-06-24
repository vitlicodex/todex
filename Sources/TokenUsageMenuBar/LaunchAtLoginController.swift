import AppKit
import Foundation

final class LaunchAtLoginController {
    private let label = "local.codex-token-menubar"

    var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func cleanupLegacyLogs() {
        let support = supportDirectory()
        for name in ["launch-agent.out.log", "launch-agent.err.log"] {
            let url = support.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private func install() throws {
        let executablePath = try validatedAppExecutablePath()
        let support = supportDirectory()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escape(executablePath))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/dev/null</string>
            <key>StandardErrorPath</key>
            <string>/dev/null</string>
        </dict>
        </plist>
        """
        try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launchAgentURL.path)
        try runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", launchAgentURL.path], allowFailure: true)
    }

    private func uninstall() throws {
        try runLaunchctl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path], allowFailure: true)
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    private func runLaunchctl(arguments: [String], allowFailure: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if !allowFailure && process.terminationStatus != 0 {
            throw NSError(
                domain: "LaunchAtLoginController",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "launchctl failed with status \(process.terminationStatus)"]
            )
        }
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexTokenMenuBar", isDirectory: true)
    }

    private func validatedAppExecutablePath() throws -> String {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let executableURL = Bundle.main.executableURL else {
            throw NSError(
                domain: "LaunchAtLoginController",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Launch at Login can only be enabled from the installed .app bundle, not from swift run or a build folder."
                ]
            )
        }

        let executablePath = executableURL.standardizedFileURL.path
        let macOSPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .standardizedFileURL
            .path
        guard executablePath.hasPrefix(macOSPath + "/") else {
            throw NSError(
                domain: "LaunchAtLoginController",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Launch at Login executable path is outside the app bundle."]
            )
        }

        return executablePath
    }
}
