import Foundation

public struct TokenSourceDiscovery: Sendable {
    public var homeDirectory: URL
    public var workspaceDirectory: URL?
    public var environment: [String: String]
    public var maxFilesPerDirectory: Int

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        workspaceDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxFilesPerDirectory: Int = 80
    ) {
        self.homeDirectory = homeDirectory
        self.workspaceDirectory = workspaceDirectory
        self.environment = environment
        self.maxFilesPerDirectory = maxFilesPerDirectory
    }

    public func discover() -> [URL] {
        var candidates: [URL] = []

        if let configured = environment["CODEX_TOKEN_USAGE_PATHS"] {
            candidates.append(contentsOf: configured.split(separator: ":").map { expandPath(String($0)) })
        }

        let codex = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        candidates.append(contentsOf: [
            codex.appendingPathComponent("token-usage.json"),
            codex.appendingPathComponent("usage.json"),
            codex.appendingPathComponent("codex-token-usage.json"),
            codex.appendingPathComponent("telemetry.json"),
            codex.appendingPathComponent("telemetry.jsonl"),
            codex.appendingPathComponent("session_index.jsonl"),
            codex.appendingPathComponent("sessions", isDirectory: true),
            codex.appendingPathComponent("logs", isDirectory: true),
            codex.appendingPathComponent("telemetry", isDirectory: true)
        ])

        if let workspaceDirectory {
            let workspaceCodex = workspaceDirectory.appendingPathComponent(".codex", isDirectory: true)
            candidates.append(contentsOf: [
                workspaceCodex.appendingPathComponent("token-usage.json"),
                workspaceCodex.appendingPathComponent("usage.json"),
                workspaceCodex.appendingPathComponent("logs", isDirectory: true),
                workspaceCodex.appendingPathComponent("sessions", isDirectory: true)
            ])
        }

        let files = candidates.flatMap { sourceFiles(from: $0) }
        var seen = Set<String>()
        return files.filter { url in
            guard !seen.contains(url.path) else { return false }
            seen.insert(url.path)
            return true
        }
    }

    private func expandPath(_ path: String) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private func sourceFiles(from url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }

        if !isDirectory.boolValue {
            return shouldReadFile(url) ? [url] : []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            guard shouldReadFile(fileURL) else { continue }
            urls.append(fileURL)
        }

        return urls
            .sorted { modificationDate($0) > modificationDate($1) }
            .prefix(maxFilesPerDirectory)
            .map { $0 }
    }

    private func shouldReadFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["json", "jsonl", "log"].contains(ext) else {
            return false
        }

        let name = url.lastPathComponent.lowercased()
        let blockedNames = ["auth.json", "pasted-text-attachments.json"]
        if blockedNames.contains(name) {
            return false
        }

        let lowerPath = url.path.lowercased()
        if lowerPath.contains("/attachments/") || lowerPath.contains("/cache/") || lowerPath.contains("/vendor_imports/") {
            return false
        }

        return true
    }

    private func modificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }
}
