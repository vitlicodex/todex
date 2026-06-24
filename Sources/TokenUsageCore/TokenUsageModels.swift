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
    case apiKeyLocked

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
        case .apiKeyLocked:
            return "OpenAI Admin API key is locked. Unlock with local password plus Touch ID or macOS password."
        }
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

    public init(
        label: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        totalTokens: Int = 0,
        requests: Int = 0,
        costUSD: Double? = nil
    ) {
        self.label = label
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.totalTokens = totalTokens
        self.requests = requests
        self.costUSD = costUSD
    }
}

public struct TokenUsageSample: Codable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let mode: UsageMode
    public let sourceID: String
    public let sourcePath: String

    public init(
        id: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        mode: UsageMode,
        sourceID: String,
        sourcePath: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.mode = mode
        self.sourceID = sourceID
        self.sourcePath = sourcePath
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
    public var budgetUSD: Double?
    public var budgetUsedRatio: Double?
    public var dataSource: String?
    public var modelBreakdown: [UsageBreakdown]
    public var projectBreakdown: [UsageBreakdown]
    public var apiKeyBreakdown: [UsageBreakdown]

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
        apiKeyBreakdown: []
    )
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
