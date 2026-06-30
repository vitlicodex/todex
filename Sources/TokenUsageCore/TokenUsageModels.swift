import Foundation

public enum UsageMode: String, Codable, Sendable {
    case api
    case real
    case estimated
}

public enum TokenUsageStatus: String, Codable, Sendable {
    case ok = "OK"
    case warning = "WARNING"
    case highUsage = "HIGH USAGE"

    public static func classify(sessionTokens: Int, last10Average: Double) -> TokenUsageStatus {
        if sessionTokens >= 300_000 || last10Average >= 75_000 {
            return .highUsage
        }

        if sessionTokens >= 150_000 || last10Average >= 30_000 {
            return .warning
        }

        return .ok
    }
}

public enum TokenMonitorIssue: Error, Codable, Equatable, Sendable {
    case codexLogsNotFound
    case tokenUsageFileMissing(String)
    case invalidJSON(String)
    case permissionDenied(String)
    case apiUsageFieldsUnavailable(String)
    case unreadableSource(String, String)
    case apiKeyMissing
    case apiUnauthorized
    case apiRequestFailed(String)
    case apiResponseInvalid(String)
    case apiRateLimited(retryAfter: String?)
    case apiEndpointUnavailable(Int)
    case apiServerError(Int)
    case apiTimeout
    case apiKeyLocked
    case sourceTruncated(String, parsedSamples: Int, limit: Int)

    public var message: String {
        switch self {
        case .codexLogsNotFound:
            return "Codex logs or token usage files were not found."
        case .tokenUsageFileMissing(let path):
            return "Token usage file is missing: \(path)"
        case .invalidJSON(let path):
            return "Invalid or corrupted JSON: \(path)"
        case .permissionDenied(let path):
            return "Permission denied while reading: \(path)"
        case .apiUsageFieldsUnavailable(let path):
            return "API usage fields unavailable in: \(path)"
        case .unreadableSource(let path, let detail):
            return "Could not read \(path): \(detail)"
        case .apiKeyMissing:
            return "OpenAI Admin API key is missing."
        case .apiUnauthorized:
            return "OpenAI Usage API rejected the key or permissions."
        case .apiRequestFailed(let detail):
            return "OpenAI Usage API request failed: \(detail)"
        case .apiResponseInvalid(let detail):
            return "OpenAI Usage API response was invalid: \(detail)"
        case .apiRateLimited(let retryAfter):
            if let retryAfter, !retryAfter.isEmpty {
                return "OpenAI Usage API rate limit reached. Retry after \(retryAfter)."
            }
            return "OpenAI Usage API rate limit reached."
        case .apiEndpointUnavailable(let status):
            return "OpenAI Usage API endpoint is unavailable or unsupported for this account (HTTP \(status))."
        case .apiServerError(let status):
            return "OpenAI Usage API server error (HTTP \(status)). Try again later."
        case .apiTimeout:
            return "OpenAI Usage API request timed out."
        case .apiKeyLocked:
            return "OpenAI Admin API key is locked. Unlock with local password plus Touch ID or macOS password."
        case .sourceTruncated(let path, let parsedSamples, let limit):
            return "Stopped parsing \(path) after \(parsedSamples) token samples (limit \(limit)); usage may be incomplete."
        }
    }

    public func privacyRedactedForReport() -> TokenMonitorIssue {
        switch self {
        case .codexLogsNotFound, .apiKeyMissing, .apiUnauthorized, .apiKeyLocked,
             .apiRateLimited, .apiEndpointUnavailable, .apiServerError, .apiTimeout:
            return self
        case .tokenUsageFileMissing(let path):
            return .tokenUsageFileMissing(TokenReportPrivacy.redactedPath(path))
        case .invalidJSON(let path):
            return .invalidJSON(TokenReportPrivacy.redactedPath(path))
        case .permissionDenied(let path):
            return .permissionDenied(TokenReportPrivacy.redactedPath(path))
        case .apiUsageFieldsUnavailable(let path):
            return .apiUsageFieldsUnavailable(TokenReportPrivacy.redactedPath(path))
        case .unreadableSource(let path, let detail):
            return .unreadableSource(
                TokenReportPrivacy.redactedPath(path),
                TokenReportPrivacy.redactSensitivePaths(in: detail)
            )
        case .apiRequestFailed(let detail):
            return .apiRequestFailed(TokenReportPrivacy.redactSensitivePaths(in: detail))
        case .apiResponseInvalid(let detail):
            return .apiResponseInvalid(TokenReportPrivacy.redactSensitivePaths(in: detail))
        case .sourceTruncated(let path, let parsedSamples, let limit):
            return .sourceTruncated(
                TokenReportPrivacy.redactedPath(path),
                parsedSamples: parsedSamples,
                limit: limit
            )
        }
    }
}

public enum TokenReportPrivacy {
    public static func redactedPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("https://"), !trimmed.hasPrefix("http://") else {
            return trimmed
        }

        let fileName = URL(fileURLWithPath: trimmed).lastPathComponent
        let safeFileName = fileName.isEmpty ? "file" : fileName
        let lowerPath = trimmed.lowercased()
        if lowerPath.contains("/.codex/sessions/") {
            return "~/.codex/sessions/\(safeFileName)"
        }
        if lowerPath.contains("/.codex/") {
            return "~/.codex/\(safeFileName)"
        }
        if lowerPath.contains("/library/application support/todex/") {
            return "~/Library/Application Support/TODEX/\(safeFileName)"
        }
        if lowerPath.contains("/library/logs/") {
            return "~/Library/Logs/\(safeFileName)"
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~/.../\(safeFileName)"
        }
        if trimmed.hasPrefix("/") {
            return "<local>/\(safeFileName)"
        }
        return trimmed
    }

    public static func redactSensitivePaths(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = text
        let patterns = [
            #"/Users/[^\s,;\)\]\}"]+"#,
            #"/private/var/[^\s,;\)\]\}"]+"#,
            #"/var/[^\s,;\)\]\}"]+"#,
            #"/tmp/[^\s,;\)\]\}"]+"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let matches = regex.matches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output)
            )
            for match in matches.reversed() {
                guard let range = Range(match.range, in: output) else { continue }
                let path = String(output[range])
                output.replaceSubrange(range, with: redactedPath(path))
            }
        }

        return output
    }
}

public struct UsageBreakdown: Codable, Equatable, Sendable {
    public var label: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var totalTokens: Int
    public var requests: Int
    public var costUSD: Double?
    public var estimatedLocalCostUSD: Double?

    public init(
        label: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        totalTokens: Int = 0,
        requests: Int = 0,
        costUSD: Double? = nil,
        estimatedLocalCostUSD: Double? = nil
    ) {
        self.label = label
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.totalTokens = totalTokens
        self.requests = requests
        self.costUSD = costUSD
        self.estimatedLocalCostUSD = estimatedLocalCostUSD
    }
}

public struct TokenUsageSample: Codable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let reportedTotalTokens: Int?
    public let mode: UsageMode
    public let sourceID: String
    public let sourcePath: String
    public let projectID: String?
    public let projectName: String?

    public init(
        id: String,
        timestamp: Date,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        totalTokens: Int,
        reportedTotalTokens: Int? = nil,
        mode: UsageMode,
        sourceID: String,
        sourcePath: String,
        projectID: String? = nil,
        projectName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.reportedTotalTokens = reportedTotalTokens
        self.mode = mode
        self.sourceID = sourceID
        self.sourcePath = sourcePath
        self.projectID = projectID
        self.projectName = projectName
    }

    public var computedInputOutputTokens: Int {
        inputTokens + outputTokens
    }

    public var computedInputOutputReasoningTokens: Int {
        inputTokens + outputTokens + reasoningTokens
    }

    public var totalDiffersFromInputOutput: Bool {
        totalTokens != computedInputOutputTokens
    }

    public func withProject(projectID: String?, projectName: String?) -> TokenUsageSample {
        TokenUsageSample(
            id: id,
            timestamp: timestamp,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            reportedTotalTokens: reportedTotalTokens,
            mode: mode,
            sourceID: sourceID,
            sourcePath: sourcePath,
            projectID: projectID ?? self.projectID,
            projectName: projectName ?? self.projectName
        )
    }

    public func privacyRedactedForReport() -> TokenUsageSample {
        TokenUsageSample(
            id: id,
            timestamp: timestamp,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            reportedTotalTokens: reportedTotalTokens,
            mode: mode,
            sourceID: sourceID,
            sourcePath: TokenReportPrivacy.redactedPath(sourcePath),
            projectID: projectID,
            projectName: projectName
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case inputTokens
        case cachedInputTokens
        case outputTokens
        case reasoningTokens
        case totalTokens
        case reportedTotalTokens
        case mode
        case sourceID
        case sourcePath
        case projectID
        case projectName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        reportedTotalTokens = try container.decodeIfPresent(Int.self, forKey: .reportedTotalTokens)
        mode = try container.decode(UsageMode.self, forKey: .mode)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
    }
}

public struct UsagePeriodSummary: Codable, Equatable, Sendable {
    public var label: String
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var requests: Int

    public init(
        label: String,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        requests: Int = 0
    ) {
        self.label = label
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.requests = requests
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case inputTokens
        case cachedInputTokens
        case outputTokens
        case totalTokens
        case requests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        requests = try container.decode(Int.self, forKey: .requests)
    }
}

public struct TokenUsageStatistics: Codable, Equatable, Sendable {
    public var currentSessionPrompts: Int
    public var totalPrompts: Int
    public var sessionTokens: Int
    public var totalTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var averageTokensPerPrompt: Double
    public var last10PromptsAverage: Double
    public var peakPromptCost: Int
    public var mode: UsageMode
    public var status: TokenUsageStatus
    public var lastUpdatedAt: Date?
    public var activeSourcePath: String?
    public var issues: [TokenMonitorIssue]
    public var cachedInputTokens: Int
    public var requestCount: Int
    public var dailyCostUSD: Double?
    public var monthlyCostUSD: Double?
    public var estimatedLocalSessionCostUSD: Double? = nil
    public var estimatedLocalDailyCostUSD: Double? = nil
    public var estimatedLocalWeeklyCostUSD: Double? = nil
    public var estimatedLocalMonthlyCostUSD: Double? = nil
    public var estimatedLocalTotalCostUSD: Double? = nil
    public var estimatedLocalPricingProfileName: String? = nil
    public var budgetUSD: Double?
    public var budgetUsedRatio: Double?
    public var dataSource: String?
    public var modelBreakdown: [UsageBreakdown]
    public var projectBreakdown: [UsageBreakdown]
    public var apiKeyBreakdown: [UsageBreakdown]
    public var todayUsage: UsagePeriodSummary
    public var yesterdayUsage: UsagePeriodSummary
    public var currentWeekUsage: UsagePeriodSummary
    public var currentMonthUsage: UsagePeriodSummary
    public var recentDailyUsage: [UsagePeriodSummary]
    public var todayProjectBreakdown: [UsageBreakdown]

    public static let empty = TokenUsageStatistics(
        currentSessionPrompts: 0,
        totalPrompts: 0,
        sessionTokens: 0,
        totalTokens: 0,
        inputTokens: 0,
        outputTokens: 0,
        averageTokensPerPrompt: 0,
        last10PromptsAverage: 0,
        peakPromptCost: 0,
        mode: .estimated,
        status: .ok,
        lastUpdatedAt: nil,
        activeSourcePath: nil,
        issues: [],
        cachedInputTokens: 0,
        requestCount: 0,
        dailyCostUSD: nil,
        monthlyCostUSD: nil,
        budgetUSD: nil,
        budgetUsedRatio: nil,
        dataSource: nil,
        modelBreakdown: [],
        projectBreakdown: [],
        apiKeyBreakdown: [],
        todayUsage: UsagePeriodSummary(label: "Today"),
        yesterdayUsage: UsagePeriodSummary(label: "Yesterday"),
        currentWeekUsage: UsagePeriodSummary(label: "This week"),
        currentMonthUsage: UsagePeriodSummary(label: "This month"),
        recentDailyUsage: [],
        todayProjectBreakdown: []
    )

    public var primaryDisplayUsage: UsagePeriodSummary {
        todayUsage
    }

    public var primaryDisplayStatus: TokenUsageStatus {
        TokenUsageStatus.classify(
            sessionTokens: primaryDisplayUsage.totalTokens,
            last10Average: last10PromptsAverage
        )
    }

    public func privacyRedactedForReport() -> TokenUsageStatistics {
        var redacted = self
        if let activeSourcePath {
            redacted.activeSourcePath = TokenReportPrivacy.redactedPath(activeSourcePath)
        }
        redacted.issues = issues.map { $0.privacyRedactedForReport() }
        return redacted
    }
}

public struct TokenUsageReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var sessionStartedAt: Date
    public var statistics: TokenUsageStatistics
    public var numericSamples: [TokenUsageSample]

    public init(
        generatedAt: Date,
        sessionStartedAt: Date,
        statistics: TokenUsageStatistics,
        numericSamples: [TokenUsageSample]
    ) {
        self.generatedAt = generatedAt
        self.sessionStartedAt = sessionStartedAt
        self.statistics = statistics
        self.numericSamples = numericSamples
    }

    public func privacyRedactedForReport() -> TokenUsageReport {
        TokenUsageReport(
            generatedAt: generatedAt,
            sessionStartedAt: sessionStartedAt,
            statistics: statistics.privacyRedactedForReport(),
            numericSamples: numericSamples.map { $0.privacyRedactedForReport() }
        )
    }
}

public struct CodexPermissionSnapshot: Codable, Equatable, Sendable {
    public var monitoringEnabled: Bool
    public var status: TokenUsageStatus
    public var statusReason: String
    public var approvalPolicy: String?
    public var sandboxPolicy: String?
    public var permissionProfile: String?
    public var fileSystemPolicy: String?
    public var networkAccess: Bool?
    public var trustedWorkspaceCount: Int
    public var configSourcePath: String?
    public var sessionSourcePath: String?
    public var lastUpdatedAt: Date?
    public var issues: [String]
    public var policyViolations: [CodexPermissionViolation]

    public init(
        monitoringEnabled: Bool,
        status: TokenUsageStatus,
        statusReason: String,
        approvalPolicy: String? = nil,
        sandboxPolicy: String? = nil,
        permissionProfile: String? = nil,
        fileSystemPolicy: String? = nil,
        networkAccess: Bool? = nil,
        trustedWorkspaceCount: Int = 0,
        configSourcePath: String? = nil,
        sessionSourcePath: String? = nil,
        lastUpdatedAt: Date? = nil,
        issues: [String] = [],
        policyViolations: [CodexPermissionViolation] = []
    ) {
        self.monitoringEnabled = monitoringEnabled
        self.status = status
        self.statusReason = statusReason
        self.approvalPolicy = approvalPolicy
        self.sandboxPolicy = sandboxPolicy
        self.permissionProfile = permissionProfile
        self.fileSystemPolicy = fileSystemPolicy
        self.networkAccess = networkAccess
        self.trustedWorkspaceCount = trustedWorkspaceCount
        self.configSourcePath = configSourcePath
        self.sessionSourcePath = sessionSourcePath
        self.lastUpdatedAt = lastUpdatedAt
        self.issues = issues
        self.policyViolations = policyViolations
    }

    public static let disabled = CodexPermissionSnapshot(
        monitoringEnabled: false,
        status: .ok,
        statusReason: "Permission monitoring is disabled."
    )
}

public struct CodexPermissionViolation: Codable, Equatable, Sendable {
    public var bundle: CodexPermissionBundle
    public var rule: CodexPermissionRule
    public var title: String
    public var detail: String
    public var severity: TokenUsageStatus

    public init(
        bundle: CodexPermissionBundle,
        rule: CodexPermissionRule,
        title: String,
        detail: String,
        severity: TokenUsageStatus
    ) {
        self.bundle = bundle
        self.rule = rule
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}
