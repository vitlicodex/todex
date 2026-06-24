import Foundation

public struct TokenUsageState: Codable, Equatable, Sendable {
    public var sessionStartedAt: Date
    public var samples: [TokenUsageSample]
    public var seenSampleIDs: Set<String>
    public var hasExplicitSessionReset: Bool?

    public init(
        sessionStartedAt: Date = Date(),
        samples: [TokenUsageSample] = [],
        seenSampleIDs: Set<String> = [],
        hasExplicitSessionReset: Bool? = nil
    ) {
        self.sessionStartedAt = sessionStartedAt
        self.samples = samples
        self.seenSampleIDs = seenSampleIDs
        self.hasExplicitSessionReset = hasExplicitSessionReset
    }
}

public final class TokenUsageStore: @unchecked Sendable {
    public let stateURL: URL
    private(set) public var state: TokenUsageState
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(stateURL: URL = TokenUsageStore.defaultStateURL()) {
        self.stateURL = stateURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? decoder.decode(TokenUsageState.self, from: data) {
            state = decoded
        } else {
            state = TokenUsageState()
        }
    }

    public static func defaultStateURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("CodexTokenMenuBar", isDirectory: true)
            .appendingPathComponent("stats.json")
    }

    @discardableResult
    public func add(_ samples: [TokenUsageSample]) throws -> Int {
        let newSamples = samples.filter { !state.seenSampleIDs.contains($0.id) }
        guard !newSamples.isEmpty else { return 0 }

        for sample in newSamples {
            state.samples.append(sample)
            state.seenSampleIDs.insert(sample.id)
        }

        state.samples.sort { $0.timestamp < $1.timestamp }
        try save()
        return newSamples.count
    }

    public func markSeen(_ sampleIDs: [String]) throws {
        for sampleID in sampleIDs {
            state.seenSampleIDs.insert(sampleID)
        }
        try save()
    }

    public func resetSession(at date: Date = Date()) throws {
        state.sessionStartedAt = date
        state.hasExplicitSessionReset = true
        try save()
    }

    public func resetAll(markSeen sampleIDs: [String] = [], sessionStartedAt: Date = Date()) throws {
        state = TokenUsageState(
            sessionStartedAt: sessionStartedAt,
            samples: [],
            seenSampleIDs: Set(sampleIDs),
            hasExplicitSessionReset: true
        )
        try save()
    }

    public func statistics(activeSourcePath: String?, issues: [TokenMonitorIssue]) -> TokenUsageStatistics {
        let allSamples = state.samples
        let sessionSamples = sessionSamples(from: allSamples, activeSourcePath: activeSourcePath)

        var totalTokens = 0
        for sample in allSamples {
            totalTokens += sample.totalTokens
        }

        var sessionTokens = 0
        var inputTokens = 0
        var outputTokens = 0
        var peak = 0
        var hasRealSample = false
        var last10Tokens: [Int] = []
        last10Tokens.reserveCapacity(10)

        for sample in sessionSamples {
            sessionTokens += sample.totalTokens
            inputTokens += sample.inputTokens
            outputTokens += sample.outputTokens
            peak = max(peak, sample.totalTokens)
            hasRealSample = hasRealSample || sample.mode == .real
            last10Tokens.append(sample.totalTokens)
            if last10Tokens.count > 10 {
                last10Tokens.removeFirst()
            }
        }

        let last10Average = average(last10Tokens)
        let averagePerPrompt = average(total: sessionTokens, count: sessionSamples.count)

        let mode: UsageMode
        if hasRealSample {
            mode = .real
        } else {
            mode = .estimated
        }

        return TokenUsageStatistics(
            currentSessionPrompts: sessionSamples.count,
            totalPrompts: allSamples.count,
            sessionTokens: sessionTokens,
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            averageTokensPerPrompt: averagePerPrompt,
            last10PromptsAverage: last10Average,
            peakPromptCost: peak,
            mode: mode,
            status: TokenUsageStatus.classify(sessionTokens: sessionTokens, last10Average: last10Average),
            lastUpdatedAt: allSamples.last?.timestamp,
            activeSourcePath: activeSourcePath,
            issues: issues,
            cachedInputTokens: 0,
            requestCount: sessionSamples.count,
            dailyCostUSD: nil,
            monthlyCostUSD: nil,
            budgetUSD: nil,
            budgetUsedRatio: nil,
            dataSource: "Codex local session logs",
            modelBreakdown: [],
            projectBreakdown: [],
            apiKeyBreakdown: []
        )
    }

    public func report(activeSourcePath: String?, issues: [TokenMonitorIssue]) -> TokenUsageReport {
        TokenUsageReport(
            generatedAt: Date(),
            sessionStartedAt: state.sessionStartedAt,
            statistics: statistics(activeSourcePath: activeSourcePath, issues: issues),
            numericSamples: state.samples
        )
    }

    public func saveReportJSON(_ report: TokenUsageReport, to destinationURL: URL) throws {
        let data = try encoder.encode(report)
        try PrivateFileIO.writePrivateData(data, to: destinationURL)
    }

    public func save() throws {
        let data = try encoder.encode(state)
        try PrivateFileIO.writePrivateData(data, to: stateURL)
    }

    private func average(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    private func average(total: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return Double(total) / Double(count)
    }

    private func sessionSamples(from allSamples: [TokenUsageSample], activeSourcePath: String?) -> [TokenUsageSample] {
        let timeScopedSamples = allSamples.filter { $0.timestamp >= state.sessionStartedAt }
        guard let activeSourcePath,
              activeSourcePath.contains("/.codex/sessions/") else {
            return timeScopedSamples
        }

        let activeSourceSamples = allSamples.filter { $0.sourcePath == activeSourcePath }
        let activeTimeScopedSamples = activeSourceSamples.filter { $0.timestamp >= state.sessionStartedAt }
        if !activeTimeScopedSamples.isEmpty || state.hasExplicitSessionReset == true {
            return activeTimeScopedSamples
        }

        return activeSourceSamples.isEmpty ? timeScopedSamples : activeSourceSamples
    }
}
