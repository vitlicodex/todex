import Foundation

public enum SpendFirewallSeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case critical
}

public enum ContextExplosionConfidence: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

public struct ContextExplosionFinding: Codable, Equatable, Sendable {
    public var severity: SpendFirewallSeverity
    public var confidence: ContextExplosionConfidence
    public var projectID: String?
    public var projectName: String?
    public var baselineInputPerRequest: Double
    public var recentInputPerRequest: Double
    public var inputShare: Double
    public var cachedInputShare: Double?
    public var requestCount: Int
    public var timeWindowDescription: String
    public var triggeredBy: [String]
    public var likelyCauses: [String]
    public var recommendedActions: [String]
    public var evidence: [String]
    public var evidenceMetrics: [String: Double]

    public init(
        severity: SpendFirewallSeverity,
        confidence: ContextExplosionConfidence = .medium,
        projectID: String? = nil,
        projectName: String? = nil,
        baselineInputPerRequest: Double,
        recentInputPerRequest: Double,
        inputShare: Double,
        cachedInputShare: Double? = nil,
        requestCount: Int,
        timeWindowDescription: String,
        triggeredBy: [String] = [],
        likelyCauses: [String],
        recommendedActions: [String],
        evidence: [String],
        evidenceMetrics: [String: Double] = [:]
    ) {
        self.severity = severity
        self.confidence = confidence
        self.projectID = projectID
        self.projectName = projectName
        self.baselineInputPerRequest = baselineInputPerRequest
        self.recentInputPerRequest = recentInputPerRequest
        self.inputShare = inputShare
        self.cachedInputShare = cachedInputShare
        self.requestCount = requestCount
        self.timeWindowDescription = timeWindowDescription
        self.triggeredBy = triggeredBy
        self.likelyCauses = likelyCauses
        self.recommendedActions = recommendedActions
        self.evidence = evidence
        self.evidenceMetrics = evidenceMetrics
    }
}

public struct ContextExplosionDetector: Sendable {
    public var recentWindowCount: Int
    public var minimumBaselineCount: Int
    public var relativeSpikeMultiplier: Double
    public var relativeSpikeMinimumInput: Double
    public var absoluteLargeInputThreshold: Double
    public var inputDominanceShare: Double
    public var inputDominanceMinimumTokens: Int
    public var cachedMissingInputThreshold: Int
    public var repeatedLargeRequestCount: Int
    public var minimumRequestCount: Int
    public var minimumRecentTotalTokens: Int
    public var highCachedInputShare: Double

    public init(
        recentWindowCount: Int = 5,
        minimumBaselineCount: Int = 5,
        relativeSpikeMultiplier: Double = 4,
        relativeSpikeMinimumInput: Double = 50_000,
        absoluteLargeInputThreshold: Double = 100_000,
        inputDominanceShare: Double = 0.95,
        inputDominanceMinimumTokens: Int = 1_000_000,
        cachedMissingInputThreshold: Int = 10_000_000,
        repeatedLargeRequestCount: Int = 10,
        minimumRequestCount: Int = 10,
        minimumRecentTotalTokens: Int = 250_000,
        highCachedInputShare: Double = 0.25
    ) {
        self.recentWindowCount = recentWindowCount
        self.minimumBaselineCount = minimumBaselineCount
        self.relativeSpikeMultiplier = relativeSpikeMultiplier
        self.relativeSpikeMinimumInput = relativeSpikeMinimumInput
        self.absoluteLargeInputThreshold = absoluteLargeInputThreshold
        self.inputDominanceShare = inputDominanceShare
        self.inputDominanceMinimumTokens = inputDominanceMinimumTokens
        self.cachedMissingInputThreshold = cachedMissingInputThreshold
        self.repeatedLargeRequestCount = repeatedLargeRequestCount
        self.minimumRequestCount = minimumRequestCount
        self.minimumRecentTotalTokens = minimumRecentTotalTokens
        self.highCachedInputShare = highCachedInputShare
    }

    public func detect(
        samples: [TokenUsageSample],
        settings: MonitorSettings = MonitorSettings()
    ) -> [ContextExplosionFinding] {
        let detector = configured(with: settings.contextExplosion)
        return detector.detectConfigured(samples: samples)
    }

    private func detectConfigured(samples: [TokenUsageSample]) -> [ContextExplosionFinding] {
        guard !samples.isEmpty else { return [] }

        var findings: [ContextExplosionFinding] = []
        if let global = finding(for: samples, projectID: nil, projectName: nil) {
            findings.append(global)
        }

        let grouped = Dictionary(grouping: samples) { $0.projectID ?? "unknown" }
        for (projectID, projectSamples) in grouped
        where projectID != "unknown" && projectSamples.count >= minimumBaselineCount + recentWindowCount {
            let projectName = projectSamples.compactMap(\.projectName).first
            if let finding = finding(
                for: projectSamples,
                projectID: projectID,
                projectName: projectName
            ) {
                findings.append(finding)
            }
        }

        return findings.sorted { lhs, rhs in
            severityRank(lhs.severity) > severityRank(rhs.severity)
        }
    }

    private func configured(with settings: ContextExplosionSettings) -> ContextExplosionDetector {
        ContextExplosionDetector(
            recentWindowCount: settings.recentWindowCount,
            minimumBaselineCount: settings.minimumBaselineCount,
            relativeSpikeMultiplier: settings.relativeSpikeMultiplier,
            relativeSpikeMinimumInput: settings.relativeSpikeMinimumInput,
            absoluteLargeInputThreshold: settings.absoluteLargeInputThreshold,
            inputDominanceShare: settings.inputDominanceShare,
            inputDominanceMinimumTokens: settings.inputDominanceMinimumTokens,
            cachedMissingInputThreshold: settings.cachedMissingInputThreshold,
            repeatedLargeRequestCount: settings.repeatedLargeRequestCount,
            minimumRequestCount: settings.minimumRequestCount,
            minimumRecentTotalTokens: settings.minimumRecentTotalTokens,
            highCachedInputShare: settings.highCachedInputShare
        )
    }

    private func finding(
        for samples: [TokenUsageSample],
        projectID: String?,
        projectName: String?
    ) -> ContextExplosionFinding? {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= recentWindowCount else { return nil }
        guard ordered.count >= minimumRequestCount else { return nil }

        let recent = Array(ordered.suffix(recentWindowCount))
        let baseline = Array(ordered.dropLast(recentWindowCount))
        let baselineInputPerRequest = averageInputPerRequest(baseline)
        let recentInputPerRequest = averageInputPerRequest(recent)
        let recentInput = recent.reduce(0) { $0 + $1.inputTokens }
        let recentCached = recent.reduce(0) { $0 + $1.cachedInputTokens }
        let recentOutput = recent.reduce(0) { $0 + $1.outputTokens }
        let recentTotal = recent.reduce(0) { $0 + max($1.totalTokens, $1.computedInputOutputTokens) }
        guard recentTotal >= minimumRecentTotalTokens else { return nil }
        let inputShare = recentTotal > 0 ? Double(recentInput) / Double(recentTotal) : 0
        let cachedInputShare = recentInput > 0 ? Double(recentCached) / Double(recentInput) : nil
        let hasBaseline = baseline.count >= minimumBaselineCount && baselineInputPerRequest > 0
        let outputShare = recentTotal > 0 ? Double(recentOutput) / Double(recentTotal) : 0
        let relativeMultiplier = hasBaseline ? recentInputPerRequest / max(baselineInputPerRequest, 1) : 0

        var triggers: [String] = []
        if hasBaseline,
           recentInputPerRequest >= relativeSpikeMinimumInput,
           recentInputPerRequest >= baselineInputPerRequest * relativeSpikeMultiplier {
            triggers.append("recent input/request spike")
        }
        if recentInputPerRequest >= absoluteLargeInputThreshold,
           inputShare >= inputDominanceShare {
            triggers.append("absolute large context")
        }
        if inputShare >= inputDominanceShare && recentTotal >= inputDominanceMinimumTokens {
            triggers.append("input-dominated token usage")
        }
        if recentInput >= cachedMissingInputThreshold && recentCached == 0 {
            triggers.append("large uncached input")
        }
        if ordered.count >= repeatedLargeRequestCount,
           inputShare >= inputDominanceShare,
           repeatedLargeContext(Array(ordered.suffix(repeatedLargeRequestCount))) {
            triggers.append("repeated large context reload pattern")
        }

        guard !triggers.isEmpty else { return nil }

        let severity: SpendFirewallSeverity
        let highCachedShare = cachedInputShare ?? 0 >= highCachedInputShare
        if highCachedShare {
            severity = .warning
        } else if triggers.contains("input-dominated token usage")
            || triggers.contains("large uncached input")
            || (triggers.contains("recent input/request spike") && inputShare >= inputDominanceShare) {
            severity = .critical
        } else {
            severity = .warning
        }
        let confidence = confidence(
            triggers: triggers,
            hasBaseline: hasBaseline,
            recentCount: recent.count,
            baselineCount: baseline.count,
            inputShare: inputShare,
            relativeMultiplier: relativeMultiplier,
            cachedInputShare: cachedInputShare
        )

        return ContextExplosionFinding(
            severity: severity,
            confidence: confidence,
            projectID: projectID,
            projectName: projectName,
            baselineInputPerRequest: baselineInputPerRequest,
            recentInputPerRequest: recentInputPerRequest,
            inputShare: inputShare,
            cachedInputShare: cachedInputShare,
            requestCount: recent.count,
            timeWindowDescription: "last \(recent.count) requests",
            triggeredBy: triggers,
            likelyCauses: likelyCauses(for: triggers, cachedInputShare: cachedInputShare),
            recommendedActions: recommendedActions(),
            evidence: evidence(
                triggers: triggers,
                baselineInputPerRequest: baselineInputPerRequest,
                recentInputPerRequest: recentInputPerRequest,
                inputShare: inputShare,
                cachedInputShare: cachedInputShare,
                recentInput: recentInput,
                recentOutput: recentOutput,
                projectName: projectName
            ),
            evidenceMetrics: [
                "baselineInputPerRequest": baselineInputPerRequest,
                "recentInputPerRequest": recentInputPerRequest,
                "inputShare": inputShare,
                "outputShare": outputShare,
                "cachedInputShare": cachedInputShare ?? 0,
                "relativeMultiplier": relativeMultiplier,
                "recentInputTokens": Double(recentInput),
                "recentOutputTokens": Double(recentOutput),
                "recentTotalTokens": Double(recentTotal),
                "recentRequestCount": Double(recent.count),
                "baselineRequestCount": Double(baseline.count)
            ]
        )
    }

    private func confidence(
        triggers: [String],
        hasBaseline: Bool,
        recentCount: Int,
        baselineCount: Int,
        inputShare: Double,
        relativeMultiplier: Double,
        cachedInputShare: Double?
    ) -> ContextExplosionConfidence {
        let strongTriggerCount = triggers.filter {
            $0 == "recent input/request spike"
                || $0 == "absolute large context"
                || $0 == "input-dominated token usage"
                || $0 == "large uncached input"
        }.count
        if hasBaseline,
           baselineCount >= minimumBaselineCount * 2,
           recentCount >= recentWindowCount,
           strongTriggerCount >= 2,
           inputShare >= inputDominanceShare,
           relativeMultiplier >= relativeSpikeMultiplier,
           (cachedInputShare ?? 0) < highCachedInputShare {
            return .high
        }
        if strongTriggerCount >= 1 {
            return .medium
        }
        return .low
    }

    private func averageInputPerRequest(_ samples: [TokenUsageSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.reduce(0) { $0 + $1.inputTokens }) / Double(samples.count)
    }

    private func repeatedLargeContext(_ samples: [TokenUsageSample]) -> Bool {
        guard samples.count >= repeatedLargeRequestCount else { return false }
        let inputs = samples.map(\.inputTokens)
        let average = Double(inputs.reduce(0, +)) / Double(inputs.count)
        guard average >= relativeSpikeMinimumInput else { return false }
        let maxInput = inputs.max() ?? 0
        let minInput = inputs.min() ?? 0
        return Double(maxInput - minInput) <= average * 0.10
    }

    private func likelyCauses(for triggers: [String], cachedInputShare: Double?) -> [String] {
        var causes = [
            "long Codex session",
            "large workspace or generated files in context",
            "repeated context reloads"
        ]
        if cachedInputShare == nil || cachedInputShare == 0 {
            causes.append("missing cached input")
        }
        if triggers.contains("recent input/request spike") {
            causes.append("sudden project or file-scope expansion")
        }
        return causes
    }

    private func recommendedActions() -> [String] {
        [
            "summarize the current state and restart the Codex session",
            "narrow the goal or workspace scope",
            "review large generated files before continuing",
            "switch Codex permissions to Guarded or Locked Down if automation is running"
        ]
    }

    private func evidence(
        triggers: [String],
        baselineInputPerRequest: Double,
        recentInputPerRequest: Double,
        inputShare: Double,
        cachedInputShare: Double?,
        recentInput: Int,
        recentOutput: Int,
        projectName: String?
    ) -> [String] {
        var values = [
            "triggers: \(triggers.joined(separator: ", "))",
            "baseline input/request: \(Int(baselineInputPerRequest.rounded()))",
            "recent input/request: \(Int(recentInputPerRequest.rounded()))",
            "input share: \(percent(inputShare))",
            "recent input tokens: \(recentInput)",
            "recent output tokens: \(recentOutput)"
        ]
        if let cachedInputShare {
            values.append("cached input share: \(percent(cachedInputShare))")
        }
        if let projectName, !projectName.isEmpty {
            values.append("project: \(projectName)")
        }
        return values
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
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
}
