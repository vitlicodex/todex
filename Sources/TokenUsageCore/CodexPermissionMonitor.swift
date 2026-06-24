import Foundation

public final class CodexPermissionMonitor: @unchecked Sendable {
    private let homeDirectory: URL
    private let fileManager: FileManager
    private let maxSessionFiles: Int
    private let isoFormatter: ISO8601DateFormatter

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        maxSessionFiles: Int = 40
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.maxSessionFiles = maxSessionFiles
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    public func snapshot(monitoringEnabled: Bool = true) -> CodexPermissionSnapshot {
        snapshot(settings: MonitorSettings(featureFlags: [.codexPermissionMonitoring: monitoringEnabled]))
    }

    public func snapshot(settings: MonitorSettings) -> CodexPermissionSnapshot {
        guard settings.isEnabled(.codexPermissionMonitoring) else {
            return .disabled
        }

        let configURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        let config = parseConfig(url: configURL)
        let context = latestTurnContext()
        var issues = config.issues + context.issues

        if config.trustedWorkspaceCount == 0, config.exists {
            issues.append("No trusted workspaces were found in Codex config.")
        }

        let baseStatus = classify(
            approvalPolicy: context.approvalPolicy,
            sandboxPolicy: context.sandboxPolicy,
            permissionProfile: context.permissionProfile,
            fileSystemPolicy: context.fileSystemPolicy,
            networkAccess: context.networkAccess
        )
        let violations = policyViolations(
            settings: settings,
            context: context,
            trustedWorkspaceCount: config.trustedWorkspaceCount
        )
        let finalStatus = statusWithPolicy(baseStatus.status, violations: violations)
        let reason = violations.isEmpty
            ? baseStatus.reason
            : "\(violations.count) disabled permission(s) active."

        return CodexPermissionSnapshot(
            monitoringEnabled: true,
            status: finalStatus,
            statusReason: reason,
            approvalPolicy: context.approvalPolicy,
            sandboxPolicy: context.sandboxPolicy,
            permissionProfile: context.permissionProfile,
            fileSystemPolicy: context.fileSystemPolicy,
            networkAccess: context.networkAccess,
            trustedWorkspaceCount: config.trustedWorkspaceCount,
            configSourcePath: config.exists ? configURL.path : nil,
            sessionSourcePath: context.sourcePath,
            lastUpdatedAt: context.timestamp ?? config.modifiedAt,
            issues: issues,
            policyViolations: violations
        )
    }

    public func configURL() -> URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    private func parseConfig(url: URL) -> ConfigSnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            return ConfigSnapshot(
                exists: false,
                trustedWorkspaceCount: 0,
                modifiedAt: nil,
                issues: ["Codex config.toml was not found."]
            )
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let trustedCount = text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { line in
                    line.hasPrefix("trust_level")
                        && line.contains("=")
                        && line.lowercased().contains("\"trusted\"")
                }
                .count
            return ConfigSnapshot(
                exists: true,
                trustedWorkspaceCount: trustedCount,
                modifiedAt: modificationDate(url),
                issues: []
            )
        } catch {
            return ConfigSnapshot(
                exists: true,
                trustedWorkspaceCount: 0,
                modifiedAt: modificationDate(url),
                issues: ["Could not read Codex config.toml: \(error.localizedDescription)"]
            )
        }
    }

    private func latestTurnContext() -> TurnContextSnapshot {
        let sessionsURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let files = recentSessionFiles(in: sessionsURL)
        guard !files.isEmpty else {
            return TurnContextSnapshot(issues: ["Codex session files were not found."])
        }

        var newest: TurnContextSnapshot?
        for file in files {
            guard let context = latestTurnContext(in: file) else {
                continue
            }
            if let current = newest {
                if (context.timestamp ?? .distantPast) > (current.timestamp ?? .distantPast) {
                    newest = context
                }
            } else {
                newest = context
            }
        }

        if let newest {
            return newest
        }
        return TurnContextSnapshot(issues: ["No Codex turn_context permission metadata was found."])
    }

    private func recentSessionFiles(in directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            files.append(url)
        }

        return files
            .sorted { (modificationDate($0) ?? .distantPast) > (modificationDate($1) ?? .distantPast) }
            .prefix(maxSessionFiles)
            .map { $0 }
    }

    private func latestTurnContext(in url: URL) -> TurnContextSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        let newline = Data([0x0A])
        let turnContextNeedle = Data(#""type":"turn_context""#.utf8)
        var pending = Data()
        var latest: TurnContextSnapshot?

        while true {
            let chunk: Data
            do {
                guard let nextChunk = try handle.read(upToCount: 64 * 1024),
                      !nextChunk.isEmpty else {
                    break
                }
                chunk = nextChunk
            } catch {
                break
            }

            pending.append(chunk)
            while let range = pending.firstRange(of: newline) {
                let lineData = pending.subdata(in: pending.startIndex..<range.lowerBound)
                pending.removeSubrange(pending.startIndex..<range.upperBound)
                if let context = parseTurnContextLine(lineData, sourceURL: url, needle: turnContextNeedle) {
                    latest = context
                }
            }
        }

        if !pending.isEmpty,
           let context = parseTurnContextLine(pending, sourceURL: url, needle: turnContextNeedle) {
            latest = context
        }

        return latest
    }

    private func parseTurnContextLine(_ data: Data, sourceURL: URL, needle: Data) -> TurnContextSnapshot? {
        guard data.range(of: needle) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }

        let sandboxPolicy = payload["sandbox_policy"] as? [String: Any]
        let permissionProfile = payload["permission_profile"] as? [String: Any]
        let profileFileSystem = permissionProfile?["file_system"] as? [String: Any]
        let fileSystemSandbox = payload["file_system_sandbox_policy"] as? [String: Any]

        let timestamp = stringValue(object["timestamp"]).flatMap { isoFormatter.date(from: $0) }
        let networkFromSandbox = boolValue(sandboxPolicy?["network_access"])
        let networkFromProfile = stringValue(permissionProfile?["network"]).map { $0.lowercased() != "restricted" }

        return TurnContextSnapshot(
            approvalPolicy: stringValue(payload["approval_policy"]),
            sandboxPolicy: stringValue(sandboxPolicy?["type"]),
            permissionProfile: stringValue(permissionProfile?["type"]),
            fileSystemPolicy: stringValue(profileFileSystem?["type"]) ?? stringValue(fileSystemSandbox?["kind"]),
            networkAccess: networkFromSandbox ?? networkFromProfile,
            timestamp: timestamp,
            sourcePath: sourceURL.path,
            issues: []
        )
    }

    private func classify(
        approvalPolicy: String?,
        sandboxPolicy: String?,
        permissionProfile: String?,
        fileSystemPolicy: String?,
        networkAccess: Bool?
    ) -> (status: TokenUsageStatus, reason: String) {
        let approval = approvalPolicy?.lowercased() ?? ""
        let sandbox = sandboxPolicy?.lowercased() ?? ""
        let profile = permissionProfile?.lowercased() ?? ""
        let filesystem = fileSystemPolicy?.lowercased() ?? ""

        if profile == "disabled"
            || filesystem == "unrestricted"
            || sandbox == "danger-full-access" {
            return (.highUsage, "Codex is running with broad filesystem access.")
        }

        if networkAccess == true && approval == "never" {
            return (.warning, "Network is enabled while approval policy is never.")
        }

        if approval == "never" {
            return (.warning, "Approval prompts are disabled for this Codex session.")
        }

        if networkAccess == true {
            return (.warning, "Network access is enabled for this Codex session.")
        }

        if approvalPolicy == nil && sandboxPolicy == nil && permissionProfile == nil {
            return (.warning, "Permission metadata is unavailable.")
        }

        return (.ok, "Codex permissions look constrained.")
    }

    private func policyViolations(
        settings: MonitorSettings,
        context: TurnContextSnapshot,
        trustedWorkspaceCount: Int
    ) -> [CodexPermissionViolation] {
        CodexPermissionRule.allCases.compactMap { rule in
            guard isActive(rule, context: context, trustedWorkspaceCount: trustedWorkspaceCount),
                  !settings.isPermissionRuleAllowed(rule) else {
                return nil
            }

            return CodexPermissionViolation(
                bundle: rule.bundle,
                rule: rule,
                title: rule.title,
                detail: activeDetail(for: rule, context: context, trustedWorkspaceCount: trustedWorkspaceCount),
                severity: severity(for: rule)
            )
        }
    }

    private func isActive(
        _ rule: CodexPermissionRule,
        context: TurnContextSnapshot,
        trustedWorkspaceCount: Int
    ) -> Bool {
        let approval = context.approvalPolicy?.lowercased() ?? ""
        let sandbox = context.sandboxPolicy?.lowercased() ?? ""
        let profile = context.permissionProfile?.lowercased() ?? ""
        let filesystem = context.fileSystemPolicy?.lowercased() ?? ""

        switch rule {
        case .runWithoutApproval:
            return approval == "never"
        case .workspaceCodeWrite:
            return sandbox == "workspace-write"
        case .workspaceFileWrite:
            return sandbox == "workspace-write"
        case .fullFileSystemAccess:
            return profile == "disabled" || filesystem == "unrestricted" || sandbox == "danger-full-access"
        case .networkAccess:
            return context.networkAccess == true
        case .unattendedAutomation:
            return approval == "never"
        case .fullAccessMode:
            return profile == "disabled" || sandbox == "danger-full-access"
        case .trustedWorkspaces:
            return trustedWorkspaceCount > 0
        case .localSessionMetadataRead:
            return true
        }
    }

    private func activeDetail(
        for rule: CodexPermissionRule,
        context: TurnContextSnapshot,
        trustedWorkspaceCount: Int
    ) -> String {
        switch rule {
        case .runWithoutApproval:
            return "Active approval policy: \(context.approvalPolicy ?? "unknown")."
        case .workspaceCodeWrite, .workspaceFileWrite:
            return "Active sandbox policy: \(context.sandboxPolicy ?? "unknown")."
        case .fullFileSystemAccess:
            return "Active filesystem/profile: \(context.fileSystemPolicy ?? "unknown") / \(context.permissionProfile ?? "unknown")."
        case .networkAccess:
            return "Active network access: \(context.networkAccess == true ? "enabled" : "unknown")."
        case .unattendedAutomation:
            return "Active approval policy: \(context.approvalPolicy ?? "unknown")."
        case .fullAccessMode:
            return "Active sandbox/profile: \(context.sandboxPolicy ?? "unknown") / \(context.permissionProfile ?? "unknown")."
        case .trustedWorkspaces:
            return "Trusted workspace entries: \(trustedWorkspaceCount)."
        case .localSessionMetadataRead:
            return "Permission monitor is reading local turn_context metadata."
        }
    }

    private func severity(for rule: CodexPermissionRule) -> TokenUsageStatus {
        switch rule {
        case .fullFileSystemAccess, .networkAccess, .unattendedAutomation, .fullAccessMode:
            return .highUsage
        case .runWithoutApproval, .workspaceCodeWrite, .workspaceFileWrite, .trustedWorkspaces, .localSessionMetadataRead:
            return .warning
        }
    }

    private func statusWithPolicy(
        _ baseStatus: TokenUsageStatus,
        violations: [CodexPermissionViolation]
    ) -> TokenUsageStatus {
        if violations.contains(where: { $0.severity == .highUsage }) {
            return .highUsage
        }
        if !violations.isEmpty || baseStatus == .warning {
            return .warning
        }
        return baseStatus
    }

    private func modificationDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

private struct ConfigSnapshot {
    var exists: Bool
    var trustedWorkspaceCount: Int
    var modifiedAt: Date?
    var issues: [String]
}

private struct TurnContextSnapshot {
    var approvalPolicy: String?
    var sandboxPolicy: String?
    var permissionProfile: String?
    var fileSystemPolicy: String?
    var networkAccess: Bool?
    var timestamp: Date?
    var sourcePath: String?
    var issues: [String]

    init(
        approvalPolicy: String? = nil,
        sandboxPolicy: String? = nil,
        permissionProfile: String? = nil,
        fileSystemPolicy: String? = nil,
        networkAccess: Bool? = nil,
        timestamp: Date? = nil,
        sourcePath: String? = nil,
        issues: [String] = []
    ) {
        self.approvalPolicy = approvalPolicy
        self.sandboxPolicy = sandboxPolicy
        self.permissionProfile = permissionProfile
        self.fileSystemPolicy = fileSystemPolicy
        self.networkAccess = networkAccess
        self.timestamp = timestamp
        self.sourcePath = sourcePath
        self.issues = issues
    }
}
