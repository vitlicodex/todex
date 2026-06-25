import Foundation

public enum SpendFirewallAlertKind: String, Codable, Equatable, Sendable {
    case highBurnRate
    case dailyBudgetRisk
    case projectDominance
    case lowOutputShare
    case possibleAgentLoop
    case contextExplosion
    case permissionRiskOverlap
}

public enum SpendFirewallActionKind: String, Codable, Equatable, Sendable {
    case openProjectSessionBreakdown
    case copyReduceContextPrompt
    case suggestRestartOrCompactContext
    case switchTodexPolicyGuarded
    case switchTodexPolicyLockedDown
    case applyCodexCLISafeMode
}

public struct SpendFirewallRecommendedAction: Codable, Equatable, Sendable {
    public var kind: SpendFirewallActionKind
    public var title: String
    public var detail: String
    public var requiresConfirmation: Bool
    public var modifiesCodexConfig: Bool
    public var clipboardText: String?

    public init(
        kind: SpendFirewallActionKind,
        title: String,
        detail: String,
        requiresConfirmation: Bool = false,
        modifiesCodexConfig: Bool = false,
        clipboardText: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.requiresConfirmation = requiresConfirmation
        self.modifiesCodexConfig = modifiesCodexConfig
        self.clipboardText = clipboardText
    }
}

public enum SpendFirewallActionCatalog {
    public static let reduceContextPrompt = """
    Please summarize the current state, list only the files or decisions still needed, and continue with a smaller context window.
    """

    public static let standard: [SpendFirewallRecommendedAction] = [
        SpendFirewallRecommendedAction(
            kind: .openProjectSessionBreakdown,
            title: "Open project/session breakdown",
            detail: "Review numeric usage by project and session before changing anything."
        ),
        SpendFirewallRecommendedAction(
            kind: .copyReduceContextPrompt,
            title: "Copy reduce-context prompt",
            detail: "Copies a generic prompt that asks Codex to summarize and shrink context.",
            clipboardText: reduceContextPrompt
        ),
        SpendFirewallRecommendedAction(
            kind: .suggestRestartOrCompactContext,
            title: "Suggest restart or compact context",
            detail: "Shows a non-destructive checklist. TODEX stays advisory only."
        ),
        SpendFirewallRecommendedAction(
            kind: .switchTodexPolicyGuarded,
            title: "Switch TODEX policy to Guarded",
            detail: "Changes TODEX monitoring policy only; does not alter the running Codex session."
        ),
        SpendFirewallRecommendedAction(
            kind: .switchTodexPolicyLockedDown,
            title: "Switch TODEX policy to Locked Down",
            detail: "Changes TODEX monitoring policy only; does not alter the running Codex session."
        ),
        SpendFirewallRecommendedAction(
            kind: .applyCodexCLISafeMode,
            title: "Apply Codex CLI Safe Mode config",
            detail: "Requires confirmation. New Codex CLI sessions may need restart; Codex Desktop may need restart.",
            requiresConfirmation: true,
            modifiesCodexConfig: true
        )
    ]

    public static let contextReduction: [SpendFirewallRecommendedAction] = standard.filter {
        [
            .openProjectSessionBreakdown,
            .copyReduceContextPrompt,
            .suggestRestartOrCompactContext,
            .switchTodexPolicyGuarded,
            .applyCodexCLISafeMode
        ].contains($0.kind)
    }
}

public struct SpendFirewallAlert: Codable, Equatable, Sendable {
    public var id: String
    public var kind: SpendFirewallAlertKind
    public var severity: SpendFirewallSeverity
    public var title: String
    public var detail: String
    public var evidence: [String]
    public var recommendedActions: [String]
    public var recommendedActionItems: [SpendFirewallRecommendedAction]
    public var projectID: String?
    public var projectName: String?
    public var createdAt: Date

    public init(
        kind: SpendFirewallAlertKind,
        severity: SpendFirewallSeverity,
        title: String,
        detail: String,
        evidence: [String],
        recommendedActions: [String],
        recommendedActionItems: [SpendFirewallRecommendedAction] = [],
        projectID: String? = nil,
        projectName: String? = nil,
        createdAt: Date
    ) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.evidence = evidence
        self.recommendedActions = recommendedActions
        self.recommendedActionItems = recommendedActionItems
        self.projectID = projectID
        self.projectName = projectName
        self.createdAt = createdAt
        self.id = StableHash.make([
            kind.rawValue,
            projectID ?? "",
            projectName ?? "",
            title
        ].joined(separator: "|"))
    }
}

public struct SpendFirewallEvaluator: Sendable {
    public init() {}

    public func evaluate(
        snapshot: TokenUsageStatistics,
        samples: [TokenUsageSample] = [],
        settings: MonitorSettings = MonitorSettings(),
        contextFindings: [ContextExplosionFinding] = [],
        permissionSnapshot: CodexPermissionSnapshot? = nil,
        previousAlerts: [SpendFirewallAlert] = [],
        now: Date = Date()
    ) -> [SpendFirewallAlert] {
        guard settings.isEnabled(.spendFirewall), settings.spendFirewall.enabled else {
            return []
        }

        var alerts: [SpendFirewallAlert] = []
        alerts.append(contentsOf: burnRateAlerts(samples: samples, settings: settings, now: now))
        alerts.append(contentsOf: budgetAlerts(snapshot: snapshot, settings: settings, now: now))
        alerts.append(contentsOf: projectDominanceAlerts(snapshot: snapshot, settings: settings, now: now))
        alerts.append(contentsOf: lowOutputShareAlerts(snapshot: snapshot, settings: settings, now: now))
        alerts.append(contentsOf: agentLoopAlerts(samples: samples, settings: settings, now: now))
        alerts.append(contentsOf: contextAlerts(contextFindings: contextFindings, settings: settings, now: now))
        alerts.append(contentsOf: permissionAlerts(permissionSnapshot: permissionSnapshot, now: now))

        return applyCooldown(
            alerts.sorted { severityRank($0.severity) > severityRank($1.severity) },
            previousAlerts: previousAlerts,
            cooldownMinutes: settings.spendFirewall.alertCooldownMinutes,
            now: now
        )
    }

    private func burnRateAlerts(
        samples: [TokenUsageSample],
        settings: MonitorSettings,
        now: Date
    ) -> [SpendFirewallAlert] {
        let windowStart = now.addingTimeInterval(-3600)
        let recent = samples.filter { $0.timestamp >= windowStart && $0.timestamp <= now }
        guard !recent.isEmpty else { return [] }

        let estimate = CostEstimator.estimate(samples: recent, profile: settings.localPricingProfile)
        let severity: SpendFirewallSeverity
        if estimate.totalCostUSD >= settings.spendFirewall.hourlyBurnCriticalUSD {
            severity = .critical
        } else if estimate.totalCostUSD >= settings.spendFirewall.hourlyBurnWarningUSD {
            severity = .warning
        } else {
            return []
        }

        return [
            SpendFirewallAlert(
                kind: .highBurnRate,
                severity: severity,
                title: "High AI burn rate",
                detail: "Estimated local Codex burn rate is high in the last hour.",
                evidence: [
                    "estimated local cost/hour: \(usd(estimate.totalCostUSD))",
                    "requests in last hour: \(recent.count)",
                    "pricing profile: \(settings.localPricingProfile.name)"
                ],
                recommendedActions: standardRecommendedActions(),
                recommendedActionItems: SpendFirewallActionCatalog.standard,
                createdAt: now
            )
        ]
    }

    private func budgetAlerts(
        snapshot: TokenUsageStatistics,
        settings: MonitorSettings,
        now: Date
    ) -> [SpendFirewallAlert] {
        guard settings.spendFirewall.dailyEstimatedBudgetUSD > 0,
              let dailyCost = snapshot.estimatedLocalDailyCostUSD else {
            return []
        }
        let ratio = dailyCost / settings.spendFirewall.dailyEstimatedBudgetUSD
        guard ratio >= 0.75 else { return [] }

        return [
            SpendFirewallAlert(
                kind: .dailyBudgetRisk,
                severity: ratio >= 1 ? .critical : .warning,
                title: "Daily estimated budget risk",
                detail: "Estimated local Codex cost is near or above the daily budget.",
                evidence: [
                    "estimated local daily cost: \(usd(dailyCost))",
                    "daily estimated budget: \(usd(settings.spendFirewall.dailyEstimatedBudgetUSD))",
                    "budget used: \(percent(ratio))"
                ],
                recommendedActions: standardRecommendedActions(),
                recommendedActionItems: SpendFirewallActionCatalog.standard,
                createdAt: now
            )
        ]
    }

    private func projectDominanceAlerts(
        snapshot: TokenUsageStatistics,
        settings: MonitorSettings,
        now: Date
    ) -> [SpendFirewallAlert] {
        let total = max(snapshot.todayUsage.totalTokens, 1)
        return snapshot.todayProjectBreakdown.compactMap { breakdown in
            let share = Double(breakdown.totalTokens) / Double(total)
            guard share >= settings.spendFirewall.maxProjectShareWarning,
                  breakdown.totalTokens > 0 else {
                return nil
            }
            return SpendFirewallAlert(
                kind: .projectDominance,
                severity: .warning,
                title: "Project spend concentration",
                detail: "One project dominates today's local Codex token usage.",
                evidence: [
                    "project share today: \(percent(share))",
                    "project tokens: \(breakdown.totalTokens)",
                    "total tokens today: \(snapshot.todayUsage.totalTokens)"
                ],
                recommendedActions: [
                    "open project breakdown",
                    "narrow the active task scope",
                    "restart Codex if this project no longer needs full context"
                ],
                recommendedActionItems: SpendFirewallActionCatalog.contextReduction,
                projectName: breakdown.label,
                createdAt: now
            )
        }
    }

    private func lowOutputShareAlerts(
        snapshot: TokenUsageStatistics,
        settings: MonitorSettings,
        now: Date
    ) -> [SpendFirewallAlert] {
        let total = snapshot.todayUsage.inputTokens + snapshot.todayUsage.outputTokens
        guard total > 0 else { return [] }
        let outputShare = Double(snapshot.todayUsage.outputTokens) / Double(total)
        guard outputShare <= settings.spendFirewall.lowOutputShareWarning,
              snapshot.todayUsage.inputTokens >= settings.spendFirewall.maxTokensPerRequestWarning else {
            return []
        }

        return [
            SpendFirewallAlert(
                kind: .lowOutputShare,
                severity: .warning,
                title: "Most spend is input context",
                detail: "Output is very small compared with input tokens.",
                evidence: [
                    "output share today: \(percent(outputShare))",
                    "input tokens today: \(snapshot.todayUsage.inputTokens)",
                    "output tokens today: \(snapshot.todayUsage.outputTokens)"
                ],
                recommendedActions: [
                    "summarize state and start a fresh Codex session",
                    "reduce workspace scope",
                    "review large generated files"
                ],
                recommendedActionItems: SpendFirewallActionCatalog.contextReduction,
                createdAt: now
            )
        ]
    }

    private func agentLoopAlerts(
        samples: [TokenUsageSample],
        settings: MonitorSettings,
        now: Date
    ) -> [SpendFirewallAlert] {
        guard settings.spendFirewall.agentLoopDetectionEnabled else { return [] }
        let windowStart = now.addingTimeInterval(-20 * 60)
        let recent = samples.filter { $0.timestamp >= windowStart && $0.timestamp <= now }
        guard recent.count >= 20 else { return [] }

        let totals = recent.map(\.totalTokens)
        let average = Double(totals.reduce(0, +)) / Double(totals.count)
        let spread = Double((totals.max() ?? 0) - (totals.min() ?? 0))
        guard average >= Double(settings.spendFirewall.maxTokensPerRequestWarning),
              spread <= average * 0.10 else {
            return []
        }

        return [
            SpendFirewallAlert(
                kind: .possibleAgentLoop,
                severity: .critical,
                title: "Possible agent loop",
                detail: "Many similar high-token requests happened in a short window.",
                evidence: [
                    "requests in 20 minutes: \(recent.count)",
                    "average tokens/request: \(Int(average.rounded()))",
                    "token-size spread: \(Int(spread.rounded()))"
                ],
                recommendedActions: [
                    "manually review the current Codex run",
                    "summarize state before continuing",
                    "switch policy to Guarded or Locked Down"
                ],
                recommendedActionItems: SpendFirewallActionCatalog.contextReduction,
                createdAt: now
            )
        ]
    }

    private func contextAlerts(
        contextFindings: [ContextExplosionFinding],
        settings: MonitorSettings,
        now: Date
    ) -> [SpendFirewallAlert] {
        guard settings.spendFirewall.contextExplosionDetectionEnabled else { return [] }
        return contextFindings.map { finding in
            SpendFirewallAlert(
                kind: .contextExplosion,
                severity: finding.severity,
                title: "Context explosion detected",
                detail: "Recent Codex requests are dominated by large input context. Confidence: \(finding.confidence.rawValue).",
                evidence: ["confidence: \(finding.confidence.rawValue)"] + finding.evidence,
                recommendedActions: finding.recommendedActions,
                recommendedActionItems: SpendFirewallActionCatalog.contextReduction,
                projectID: finding.projectID,
                projectName: finding.projectName,
                createdAt: now
            )
        }
    }

    private func permissionAlerts(
        permissionSnapshot: CodexPermissionSnapshot?,
        now: Date
    ) -> [SpendFirewallAlert] {
        guard let permissionSnapshot,
              permissionSnapshot.networkAccess == true,
              permissionSnapshot.approvalPolicy?.lowercased() == "never" else {
            return []
        }
        return [
            SpendFirewallAlert(
                kind: .permissionRiskOverlap,
                severity: .warning,
                title: "Permission risk overlaps spend risk",
                detail: "Network access is enabled while approval prompts are disabled.",
                evidence: [
                    "network access: enabled",
                    "approval policy: never"
                ],
                recommendedActions: [
                    "switch Codex policy to Guarded",
                    "review automation before continuing"
                ],
                recommendedActionItems: [
                    SpendFirewallActionCatalog.standard[3],
                    SpendFirewallActionCatalog.standard[4],
                    SpendFirewallActionCatalog.standard[5]
                ],
                createdAt: now
            )
        ]
    }

    private func applyCooldown(
        _ alerts: [SpendFirewallAlert],
        previousAlerts: [SpendFirewallAlert],
        cooldownMinutes: Int,
        now: Date
    ) -> [SpendFirewallAlert] {
        guard cooldownMinutes > 0, !previousAlerts.isEmpty else { return alerts }
        let cutoff = now.addingTimeInterval(-TimeInterval(cooldownMinutes * 60))
        return alerts.filter { alert in
            !previousAlerts.contains { previous in
                previous.kind == alert.kind
                    && previous.projectID == alert.projectID
                    && previous.projectName == alert.projectName
                    && previous.createdAt >= cutoff
            }
        }
    }

    private func standardRecommendedActions() -> [String] {
        [
            "open usage breakdown",
            "summarize state and restart Codex",
            "reduce workspace scope",
            "switch Codex policy to Guarded or Locked Down"
        ]
    }

    private func severityRank(_ severity: SpendFirewallSeverity) -> Int {
        switch severity {
        case .critical:
            return 3
        case .warning:
            return 2
        case .info:
            return 1
        }
    }

    private func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
