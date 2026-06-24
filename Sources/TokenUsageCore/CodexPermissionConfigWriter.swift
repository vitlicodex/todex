import Darwin
import Foundation

public struct CodexPermissionCLIConfiguration: Equatable, Sendable {
    public var approvalPolicy: String
    public var sandboxMode: String
    public var workspaceWriteNetworkAccess: Bool

    public init(
        approvalPolicy: String,
        sandboxMode: String,
        workspaceWriteNetworkAccess: Bool
    ) {
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
        self.workspaceWriteNetworkAccess = workspaceWriteNetworkAccess
    }
}

public struct CodexPermissionConfigWriteResult: Equatable, Sendable {
    public var configURL: URL
    public var backupURL: URL?
    public var applied: CodexPermissionCLIConfiguration

    public init(
        configURL: URL,
        backupURL: URL?,
        applied: CodexPermissionCLIConfiguration
    ) {
        self.configURL = configURL
        self.backupURL = backupURL
        self.applied = applied
    }
}

public final class CodexPermissionConfigWriter: @unchecked Sendable {
    private let fileManager: FileManager
    private let configURL: URL

    public init(
        configURL: URL = CodexPermissionConfigWriter.defaultConfigURL(),
        fileManager: FileManager = .default
    ) {
        self.configURL = configURL
        self.fileManager = fileManager
    }

    public static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    public static func cliConfiguration(for preset: CodexPermissionPreset) -> CodexPermissionCLIConfiguration {
        switch preset {
        case .fullAccess:
            return CodexPermissionCLIConfiguration(
                approvalPolicy: "never",
                sandboxMode: "danger-full-access",
                workspaceWriteNetworkAccess: true
            )
        case .automation:
            return CodexPermissionCLIConfiguration(
                approvalPolicy: "never",
                sandboxMode: "workspace-write",
                workspaceWriteNetworkAccess: true
            )
        case .balanced:
            return CodexPermissionCLIConfiguration(
                approvalPolicy: "on-request",
                sandboxMode: "workspace-write",
                workspaceWriteNetworkAccess: false
            )
        case .guarded:
            return CodexPermissionCLIConfiguration(
                approvalPolicy: "on-request",
                sandboxMode: "workspace-write",
                workspaceWriteNetworkAccess: false
            )
        case .lockedDown:
            return CodexPermissionCLIConfiguration(
                approvalPolicy: "untrusted",
                sandboxMode: "read-only",
                workspaceWriteNetworkAccess: false
            )
        }
    }

    public func applyPreset(_ preset: CodexPermissionPreset) throws -> CodexPermissionConfigWriteResult {
        let configuration = Self.cliConfiguration(for: preset)
        let existingText: String
        var backupURL: URL?

        if fileManager.fileExists(atPath: configURL.path) {
            try prepareExistingConfigForPrivateWrite()
            existingText = try String(contentsOf: configURL, encoding: .utf8)
            let backup = configURL.deletingLastPathComponent()
                .appendingPathComponent("config.toml.todex-backup")
            try PrivateFileIO.writePrivateString(existingText, to: backup)
            backupURL = backup
        } else {
            existingText = ""
        }

        let updated = updateConfigText(existingText, configuration: configuration)
        try PrivateFileIO.writePrivateString(updated, to: configURL)

        return CodexPermissionConfigWriteResult(
            configURL: configURL,
            backupURL: backupURL,
            applied: configuration
        )
    }

    private func updateConfigText(
        _ text: String,
        configuration: CodexPermissionCLIConfiguration
    ) -> String {
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        upsertTopLevelKey(
            "approval_policy",
            value: #""\#(configuration.approvalPolicy)""#,
            in: &lines
        )
        upsertTopLevelKey(
            "sandbox_mode",
            value: #""\#(configuration.sandboxMode)""#,
            in: &lines
        )
        upsertTableKey(
            table: "sandbox_workspace_write",
            key: "network_access",
            value: configuration.workspaceWriteNetworkAccess ? "true" : "false",
            in: &lines
        )

        let joined = lines.joined(separator: "\n")
        return joined.hasSuffix("\n") ? joined : joined + "\n"
    }

    private func upsertTopLevelKey(
        _ key: String,
        value: String,
        in lines: inout [String]
    ) {
        let assignment = "\(key) = \(value)"
        let sectionStart = firstSectionIndex(in: lines) ?? lines.count

        if sectionStart > 0 {
            for index in 0..<sectionStart where isAssignmentLine(lines[index], key: key) {
                lines[index] = assignment
                return
            }
        }

        lines.insert(assignment, at: sectionStart)
    }

    private func upsertTableKey(
        table: String,
        key: String,
        value: String,
        in lines: inout [String]
    ) {
        let header = "[\(table)]"
        let assignment = "\(key) = \(value)"

        guard let tableIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append(header)
            lines.append(assignment)
            return
        }

        let tableEnd = lines[(tableIndex + 1)...].firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        } ?? lines.count

        if tableIndex + 1 < tableEnd {
            for index in (tableIndex + 1)..<tableEnd where isAssignmentLine(lines[index], key: key) {
                lines[index] = assignment
                return
            }
        }

        lines.insert(assignment, at: tableEnd)
    }

    private func firstSectionIndex(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        }
    }

    private func isAssignmentLine(_ line: String, key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return false }
        return trimmed.hasPrefix(key)
            && trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    private func prepareExistingConfigForPrivateWrite() throws {
        let values = try configURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw NSError(
                domain: "CodexPermissionConfigWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(configURL.path) must not be a symlink."]
            )
        }
        guard values.isRegularFile == true else {
            throw NSError(
                domain: "CodexPermissionConfigWriter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(configURL.path) is not a regular file."]
            )
        }
        let attributes = try fileManager.attributesOfItem(atPath: configURL.path)
        if let owner = attributes[.ownerAccountID] as? NSNumber,
           owner.uint32Value != getuid() {
            throw NSError(
                domain: "CodexPermissionConfigWriter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(configURL.path) is not owned by the current user."]
            )
        }
        if let referenceCount = attributes[.referenceCount] as? NSNumber,
           referenceCount.intValue > 1 {
            throw NSError(
                domain: "CodexPermissionConfigWriter",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(configURL.path) must not have multiple hard links."]
            )
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}
