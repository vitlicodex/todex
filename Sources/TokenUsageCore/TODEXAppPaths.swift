import Foundation

public enum TODEXAppPaths {
    private static let supportDirectoryName = "TODEX"
    private static let legacySupportDirectoryNames = ["CodexTokenMenuBar"]

    public static func supportDirectory() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let current = baseURL.appendingPathComponent(supportDirectoryName, isDirectory: true)
        migrateLegacySupportIfNeeded(baseURL: baseURL, current: current)
        return current
    }

    public static func supportFile(_ name: String) -> URL {
        supportDirectory().appendingPathComponent(name)
    }

    private static func migrateLegacySupportIfNeeded(baseURL: URL, current: URL) {
        let fileManager = FileManager.default
        let legacyDirectories = legacySupportDirectoryNames.map {
            baseURL.appendingPathComponent($0, isDirectory: true)
        }

        if !fileManager.fileExists(atPath: current.path),
           let legacy = legacyDirectories.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            do {
                try fileManager.moveItem(at: legacy, to: current)
                try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
                return
            } catch {
                try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
            }
        }

        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
        for legacy in legacyDirectories where fileManager.fileExists(atPath: legacy.path) {
            migrateMissingFiles(from: legacy, to: current)
        }
    }

    private static func migrateMissingFiles(from legacy: URL, to current: URL) {
        let fileManager = FileManager.default
        let fileNames = [
            "stats.json",
            "settings.json",
            "api-key.vault.json",
            "token-report.md",
            "token-report.json"
        ]
        for name in fileNames {
            let source = legacy.appendingPathComponent(name)
            let destination = current.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else {
                continue
            }
            try? fileManager.copyItem(at: source, to: destination)
        }
    }
}
