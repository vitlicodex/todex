import Foundation

public enum MonitorFeatureFlag: String, CaseIterable, Codable, Sendable {
    case apiUsageSource
    case costsEndpoint
    case localFallback
    case budgetAlerts
    case menuBarSpend
    case privacyMode
    case modelBreakdown
    case projectBreakdown
    case apiKeyBreakdown
    case dailyPace
    case codexPermissionMonitoring
    case estimatedLocalCost
    case contextExplosionDetector
    case spendFirewall

    public var title: String {
        switch self {
        case .apiUsageSource:
            return "API Usage Source"
        case .costsEndpoint:
            return "Costs Endpoint"
        case .localFallback:
            return "Codex Local Logs"
        case .budgetAlerts:
            return "Budget Alerts"
        case .menuBarSpend:
            return "Spend in Menu Bar"
        case .privacyMode:
            return "Privacy Mode"
        case .modelBreakdown:
            return "Model Breakdown"
        case .projectBreakdown:
            return "Project Breakdown"
        case .apiKeyBreakdown:
            return "API Key Breakdown"
        case .dailyPace:
            return "Daily Pace"
        case .codexPermissionMonitoring:
            return "Codex Permission Monitoring"
        case .estimatedLocalCost:
            return "Estimated Local Codex Cost"
        case .contextExplosionDetector:
            return "Context Explosion Detector"
        case .spendFirewall:
            return "AI Spend Firewall"
        }
    }
}

public struct SpendFirewallSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var dailyEstimatedBudgetUSD: Double
    public var hourlyBurnWarningUSD: Double
    public var hourlyBurnCriticalUSD: Double
    public var maxTokensPerRequestWarning: Int
    public var maxTokensPerRequestCritical: Int
    public var maxProjectShareWarning: Double
    public var lowOutputShareWarning: Double
    public var agentLoopDetectionEnabled: Bool
    public var contextExplosionDetectionEnabled: Bool
    public var alertCooldownMinutes: Int

    public init(
        enabled: Bool = true,
        dailyEstimatedBudgetUSD: Double = 100,
        hourlyBurnWarningUSD: Double = 25,
        hourlyBurnCriticalUSD: Double = 100,
        maxTokensPerRequestWarning: Int = 75_000,
        maxTokensPerRequestCritical: Int = 150_000,
        maxProjectShareWarning: Double = 0.80,
        lowOutputShareWarning: Double = 0.01,
        agentLoopDetectionEnabled: Bool = true,
        contextExplosionDetectionEnabled: Bool = true,
        alertCooldownMinutes: Int = 15
    ) {
        self.enabled = enabled
        self.dailyEstimatedBudgetUSD = dailyEstimatedBudgetUSD
        self.hourlyBurnWarningUSD = hourlyBurnWarningUSD
        self.hourlyBurnCriticalUSD = hourlyBurnCriticalUSD
        self.maxTokensPerRequestWarning = maxTokensPerRequestWarning
        self.maxTokensPerRequestCritical = maxTokensPerRequestCritical
        self.maxProjectShareWarning = maxProjectShareWarning
        self.lowOutputShareWarning = lowOutputShareWarning
        self.agentLoopDetectionEnabled = agentLoopDetectionEnabled
        self.contextExplosionDetectionEnabled = contextExplosionDetectionEnabled
        self.alertCooldownMinutes = alertCooldownMinutes
    }
}

public struct ContextExplosionSettings: Codable, Equatable, Sendable {
    public var recentWindowCount: Int
    public var minimumBaselineCount: Int
    public var minimumRequestCount: Int
    public var minimumRecentTotalTokens: Int
    public var relativeSpikeMultiplier: Double
    public var relativeSpikeMinimumInput: Double
    public var absoluteLargeInputThreshold: Double
    public var inputDominanceShare: Double
    public var inputDominanceMinimumTokens: Int
    public var cachedMissingInputThreshold: Int
    public var repeatedLargeRequestCount: Int
    public var highCachedInputShare: Double

    public init(
        recentWindowCount: Int = 5,
        minimumBaselineCount: Int = 5,
        minimumRequestCount: Int = 10,
        minimumRecentTotalTokens: Int = 250_000,
        relativeSpikeMultiplier: Double = 4,
        relativeSpikeMinimumInput: Double = 50_000,
        absoluteLargeInputThreshold: Double = 100_000,
        inputDominanceShare: Double = 0.95,
        inputDominanceMinimumTokens: Int = 1_000_000,
        cachedMissingInputThreshold: Int = 10_000_000,
        repeatedLargeRequestCount: Int = 10,
        highCachedInputShare: Double = 0.25
    ) {
        self.recentWindowCount = recentWindowCount
        self.minimumBaselineCount = minimumBaselineCount
        self.minimumRequestCount = minimumRequestCount
        self.minimumRecentTotalTokens = minimumRecentTotalTokens
        self.relativeSpikeMultiplier = relativeSpikeMultiplier
        self.relativeSpikeMinimumInput = relativeSpikeMinimumInput
        self.absoluteLargeInputThreshold = absoluteLargeInputThreshold
        self.inputDominanceShare = inputDominanceShare
        self.inputDominanceMinimumTokens = inputDominanceMinimumTokens
        self.cachedMissingInputThreshold = cachedMissingInputThreshold
        self.repeatedLargeRequestCount = repeatedLargeRequestCount
        self.highCachedInputShare = highCachedInputShare
    }
}

public enum CodexPermissionBundle: String, CaseIterable, Codable, Sendable {
    case programming
    case fileSystem
    case network
    case automation
    case secretsPrivacy

    public var title: String {
        switch self {
        case .programming:
            return "Programming"
        case .fileSystem:
            return "File System"
        case .network:
            return "Network"
        case .automation:
            return "Automation"
        case .secretsPrivacy:
            return "Secrets & Privacy"
        }
    }
}

public enum CodexPermissionRule: String, CaseIterable, Codable, Sendable {
    case runWithoutApproval
    case workspaceCodeWrite
    case workspaceFileWrite
    case fullFileSystemAccess
    case networkAccess
    case unattendedAutomation
    case fullAccessMode
    case trustedWorkspaces
    case localSessionMetadataRead

    public var bundle: CodexPermissionBundle {
        switch self {
        case .runWithoutApproval, .workspaceCodeWrite:
            return .programming
        case .workspaceFileWrite, .fullFileSystemAccess:
            return .fileSystem
        case .networkAccess:
            return .network
        case .unattendedAutomation, .fullAccessMode:
            return .automation
        case .trustedWorkspaces, .localSessionMetadataRead:
            return .secretsPrivacy
        }
    }

    public var title: String {
        switch self {
        case .runWithoutApproval:
            return "Run Tools Without Approval"
        case .workspaceCodeWrite:
            return "Modify Workspace Code"
        case .workspaceFileWrite:
            return "Workspace File Writes"
        case .fullFileSystemAccess:
            return "Full Filesystem Access"
        case .networkAccess:
            return "Network Access"
        case .unattendedAutomation:
            return "Unattended Automation"
        case .fullAccessMode:
            return "Full Access Mode"
        case .trustedWorkspaces:
            return "Trusted Workspaces"
        case .localSessionMetadataRead:
            return "Read Local Session Metadata"
        }
    }

    public var detail: String {
        switch self {
        case .runWithoutApproval:
            return "Codex can run tools when approval_policy is never."
        case .workspaceCodeWrite:
            return "Codex can edit the current workspace."
        case .workspaceFileWrite:
            return "Codex can write files in workspace roots."
        case .fullFileSystemAccess:
            return "Codex can access the filesystem broadly."
        case .networkAccess:
            return "Codex can use network access."
        case .unattendedAutomation:
            return "Codex can continue actions without approval prompts."
        case .fullAccessMode:
            return "Codex is not constrained by the normal permission profile."
        case .trustedWorkspaces:
            return "Codex config has trusted workspace entries."
        case .localSessionMetadataRead:
            return "This app reads local Codex turn_context metadata."
        }
    }

    public var defaultAllowed: Bool {
        CodexPermissionPreset.balanced.allows(self)
    }
}

public enum CodexPermissionPreset: String, CaseIterable, Codable, Sendable {
    case fullAccess
    case automation
    case balanced
    case guarded
    case lockedDown

    public var level: Int {
        switch self {
        case .fullAccess:
            return 1
        case .automation:
            return 2
        case .balanced:
            return 3
        case .guarded:
            return 4
        case .lockedDown:
            return 5
        }
    }

    public var title: String {
        switch self {
        case .fullAccess:
            return "Full Access"
        case .automation:
            return "Automation"
        case .balanced:
            return "Balanced"
        case .guarded:
            return "Guarded"
        case .lockedDown:
            return "Locked Down"
        }
    }

    public var detail: String {
        switch self {
        case .fullAccess:
            return "Allow every detected Codex permission. Use only for trusted local work."
        case .automation:
            return "Allow unattended workspace automation and network, but block full filesystem/full-access mode."
        case .balanced:
            return "Allow normal workspace edits, but require approval prompts and block network/full access."
        case .guarded:
            return "Allow workspace edits only; block trusted workspace shortcuts, network, and no-approval mode."
        case .lockedDown:
            return "Allow monitoring only. Any write, network, trusted workspace, or no-approval mode is a violation."
        }
    }

    public func allows(_ rule: CodexPermissionRule) -> Bool {
        switch self {
        case .fullAccess:
            return true
        case .automation:
            switch rule {
            case .runWithoutApproval, .workspaceCodeWrite, .workspaceFileWrite, .networkAccess,
                 .unattendedAutomation, .trustedWorkspaces, .localSessionMetadataRead:
                return true
            case .fullFileSystemAccess, .fullAccessMode:
                return false
            }
        case .balanced:
            switch rule {
            case .workspaceCodeWrite, .workspaceFileWrite, .trustedWorkspaces, .localSessionMetadataRead:
                return true
            case .runWithoutApproval, .fullFileSystemAccess, .networkAccess, .unattendedAutomation, .fullAccessMode:
                return false
            }
        case .guarded:
            switch rule {
            case .workspaceCodeWrite, .workspaceFileWrite, .localSessionMetadataRead:
                return true
            case .runWithoutApproval, .fullFileSystemAccess, .networkAccess, .unattendedAutomation,
                 .fullAccessMode, .trustedWorkspaces:
                return false
            }
        case .lockedDown:
            return rule == .localSessionMetadataRead
        }
    }
}

public struct MonitorSettings: Codable, Equatable, Sendable {
    public var featureFlags: [MonitorFeatureFlag: Bool]
    public var codexPermissionPreset: CodexPermissionPreset?
    public var codexPermissionBundles: [CodexPermissionBundle: Bool]
    public var codexPermissionRules: [CodexPermissionRule: Bool]
    public var refreshIntervalSeconds: TimeInterval
    public var monthlyBudgetUSD: Double
    public var localPricingProfile: TokenPricingProfile
    public var spendFirewall: SpendFirewallSettings
    public var contextExplosion: ContextExplosionSettings

    public init(
        featureFlags: [MonitorFeatureFlag: Bool] = MonitorSettings.defaultFeatureFlags,
        codexPermissionPreset: CodexPermissionPreset? = .balanced,
        codexPermissionBundles: [CodexPermissionBundle: Bool] = MonitorSettings.defaultPermissionBundles,
        codexPermissionRules: [CodexPermissionRule: Bool] = MonitorSettings.defaultPermissionRules,
        refreshIntervalSeconds: TimeInterval = 120,
        monthlyBudgetUSD: Double = 100,
        localPricingProfile: TokenPricingProfile = .defaultLocalEstimate,
        spendFirewall: SpendFirewallSettings = SpendFirewallSettings(),
        contextExplosion: ContextExplosionSettings = ContextExplosionSettings()
    ) {
        self.featureFlags = featureFlags
        self.codexPermissionPreset = codexPermissionPreset
        self.codexPermissionBundles = codexPermissionBundles
        self.codexPermissionRules = codexPermissionRules
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.localPricingProfile = localPricingProfile
        self.spendFirewall = spendFirewall
        self.contextExplosion = contextExplosion
    }

    private enum CodingKeys: String, CodingKey {
        case featureFlags
        case codexPermissionPreset
        case codexPermissionBundles
        case codexPermissionRules
        case refreshIntervalSeconds
        case monthlyBudgetUSD
        case localPricingProfile
        case spendFirewall
        case contextExplosion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        featureFlags = try container.decodeIfPresent([MonitorFeatureFlag: Bool].self, forKey: .featureFlags) ?? MonitorSettings.defaultFeatureFlags
        codexPermissionPreset = try container.decodeIfPresent(CodexPermissionPreset.self, forKey: .codexPermissionPreset)
        codexPermissionBundles = try container.decodeIfPresent([CodexPermissionBundle: Bool].self, forKey: .codexPermissionBundles) ?? MonitorSettings.defaultPermissionBundles
        codexPermissionRules = try container.decodeIfPresent([CodexPermissionRule: Bool].self, forKey: .codexPermissionRules) ?? MonitorSettings.defaultPermissionRules
        if codexPermissionPreset == nil {
            codexPermissionPreset = MonitorSettings.matchingPermissionPreset(
                bundles: codexPermissionBundles,
                rules: codexPermissionRules
            )
        }
        refreshIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshIntervalSeconds) ?? 120
        monthlyBudgetUSD = try container.decodeIfPresent(Double.self, forKey: .monthlyBudgetUSD) ?? 100
        localPricingProfile = try container.decodeIfPresent(TokenPricingProfile.self, forKey: .localPricingProfile) ?? .defaultLocalEstimate
        spendFirewall = try container.decodeIfPresent(SpendFirewallSettings.self, forKey: .spendFirewall) ?? SpendFirewallSettings()
        contextExplosion = try container.decodeIfPresent(ContextExplosionSettings.self, forKey: .contextExplosion) ?? ContextExplosionSettings()
    }

    public static let defaultFeatureFlags: [MonitorFeatureFlag: Bool] = [
        .apiUsageSource: true,
        .costsEndpoint: true,
        .localFallback: true,
        .budgetAlerts: true,
        .menuBarSpend: true,
        .privacyMode: false,
        .modelBreakdown: true,
        .projectBreakdown: true,
        .apiKeyBreakdown: false,
        .dailyPace: true,
        .codexPermissionMonitoring: true,
        .estimatedLocalCost: true,
        .contextExplosionDetector: true,
        .spendFirewall: true
    ]

    public static let defaultPermissionBundles: [CodexPermissionBundle: Bool] = Dictionary(
        uniqueKeysWithValues: CodexPermissionBundle.allCases.map { bundle in
            let hasAllowedRule = CodexPermissionRule.allCases.contains { rule in
                rule.bundle == bundle && CodexPermissionPreset.balanced.allows(rule)
            }
            return (bundle, hasAllowedRule)
        }
    )

    public static let defaultPermissionRules: [CodexPermissionRule: Bool] = Dictionary(
        uniqueKeysWithValues: CodexPermissionRule.allCases.map { ($0, CodexPermissionPreset.balanced.allows($0)) }
    )

    public func isEnabled(_ feature: MonitorFeatureFlag) -> Bool {
        featureFlags[feature] ?? MonitorSettings.defaultFeatureFlags[feature] ?? false
    }

    public mutating func toggle(_ feature: MonitorFeatureFlag) {
        featureFlags[feature] = !isEnabled(feature)
    }

    public func isPermissionBundleAllowed(_ bundle: CodexPermissionBundle) -> Bool {
        codexPermissionBundles[bundle] ?? MonitorSettings.defaultPermissionBundles[bundle] ?? true
    }

    public func isPermissionRuleAllowed(_ rule: CodexPermissionRule) -> Bool {
        isPermissionBundleAllowed(rule.bundle)
            && (codexPermissionRules[rule] ?? MonitorSettings.defaultPermissionRules[rule] ?? rule.defaultAllowed)
    }

    public mutating func togglePermissionBundle(_ bundle: CodexPermissionBundle) {
        codexPermissionPreset = nil
        let next = !isPermissionBundleAllowed(bundle)
        codexPermissionBundles[bundle] = next
        for rule in CodexPermissionRule.allCases where rule.bundle == bundle {
            codexPermissionRules[rule] = next
        }
    }

    public mutating func togglePermissionRule(_ rule: CodexPermissionRule) {
        codexPermissionPreset = nil
        codexPermissionBundles[rule.bundle] = true
        codexPermissionRules[rule] = !(codexPermissionRules[rule] ?? MonitorSettings.defaultPermissionRules[rule] ?? rule.defaultAllowed)
    }

    public mutating func applyPermissionPreset(_ preset: CodexPermissionPreset) {
        codexPermissionPreset = preset
        codexPermissionRules = Dictionary(
            uniqueKeysWithValues: CodexPermissionRule.allCases.map { ($0, preset.allows($0)) }
        )
        codexPermissionBundles = Dictionary(
            uniqueKeysWithValues: CodexPermissionBundle.allCases.map { bundle in
                let hasAllowedRule = CodexPermissionRule.allCases.contains { rule in
                    rule.bundle == bundle && preset.allows(rule)
                }
                return (bundle, hasAllowedRule)
            }
        )
    }

    public mutating func resetPermissionPolicy() {
        applyPermissionPreset(.balanced)
    }

    public mutating func applyPricingProfile(_ profile: TokenPricingProfile) throws {
        localPricingProfile = try profile.validated()
    }

    public mutating func resetPricingProfile(to profileID: String = TokenPricingProfile.defaultLocalEstimate.id) {
        localPricingProfile = TokenPricingProfile.defaultProfile(id: profileID) ?? .defaultLocalEstimate
    }

    private static func matchingPermissionPreset(
        bundles: [CodexPermissionBundle: Bool],
        rules: [CodexPermissionRule: Bool]
    ) -> CodexPermissionPreset? {
        CodexPermissionPreset.allCases.first { preset in
            CodexPermissionRule.allCases.allSatisfy { rule in
                let bundleAllowed = bundles[rule.bundle] ?? MonitorSettings.defaultPermissionBundles[rule.bundle] ?? true
                let ruleAllowed = bundleAllowed
                    && (rules[rule] ?? MonitorSettings.defaultPermissionRules[rule] ?? rule.defaultAllowed)
                return ruleAllowed == preset.allows(rule)
            }
        }
    }
}

public final class MonitorSettingsStore: @unchecked Sendable {
    public let settingsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(settingsURL: URL = MonitorSettingsStore.defaultSettingsURL()) {
        self.settingsURL = settingsURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public static func defaultSettingsURL() -> URL {
        TODEXAppPaths.supportFile("settings.json")
    }

    public func load() -> MonitorSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? decoder.decode(MonitorSettings.self, from: data) else {
            return MonitorSettings()
        }
        return settings
    }

    public func save(_ settings: MonitorSettings) throws {
        let data = try encoder.encode(settings)
        try PrivateFileIO.writePrivateData(data, to: settingsURL)
    }
}
