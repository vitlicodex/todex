import Foundation

public struct FileScanCursor: Codable, Equatable, Sendable {
    public var offset: UInt64
    public var lineCount: Int
    public var projectID: String?
    public var projectName: String?

    public init(
        offset: UInt64,
        lineCount: Int = 0,
        projectID: String? = nil,
        projectName: String? = nil
    ) {
        self.offset = offset
        self.lineCount = lineCount
        self.projectID = projectID
        self.projectName = projectName
    }
}

public struct TokenUsageState: Codable, Equatable, Sendable {
    public var sessionStartedAt: Date
    public var samples: [TokenUsageSample]
    public var seenSampleIDs: Set<String>
    public var hasExplicitSessionReset: Bool?
    public var sourceFingerprints: [String: FileFingerprint]
    public var sourceCursors: [String: FileScanCursor]

    private enum CodingKeys: String, CodingKey {
        case sessionStartedAt
        case samples
        case seenSampleIDs
        case hasExplicitSessionReset
        case sourceFingerprints
        case sourceCursors
    }

    public init(
        sessionStartedAt: Date = Date(),
        samples: [TokenUsageSample] = [],
        seenSampleIDs: Set<String> = [],
        hasExplicitSessionReset: Bool? = nil,
        sourceFingerprints: [String: FileFingerprint] = [:],
        sourceCursors: [String: FileScanCursor] = [:]
    ) {
        self.sessionStartedAt = sessionStartedAt
        self.samples = samples
        self.seenSampleIDs = seenSampleIDs
        self.hasExplicitSessionReset = hasExplicitSessionReset
        self.sourceFingerprints = sourceFingerprints
        self.sourceCursors = sourceCursors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionStartedAt = try container.decode(Date.self, forKey: .sessionStartedAt)
        samples = try container.decodeIfPresent([TokenUsageSample].self, forKey: .samples) ?? []
        seenSampleIDs = try container.decodeIfPresent(Set<String>.self, forKey: .seenSampleIDs) ?? []
        hasExplicitSessionReset = try container.decodeIfPresent(Bool.self, forKey: .hasExplicitSessionReset)
        sourceFingerprints = try container.decodeIfPresent([String: FileFingerprint].self, forKey: .sourceFingerprints) ?? [:]
        sourceCursors = try container.decodeIfPresent([String: FileScanCursor].self, forKey: .sourceCursors) ?? [:]
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
        TODEXAppPaths.supportFile("stats.json")
    }

    @discardableResult
    public func add(_ samples: [TokenUsageSample]) throws -> Int {
        var enrichedExistingSamples = false
        var sampleIndexByID: [String: Int]?
        for sample in samples where state.seenSampleIDs.contains(sample.id) {
            guard sample.projectID != nil || sample.projectName != nil else { continue }
            if sampleIndexByID == nil {
                var index: [String: Int] = [:]
                index.reserveCapacity(state.samples.count)
                for (offset, existingSample) in state.samples.enumerated() {
                    index[existingSample.id] = offset
                }
                sampleIndexByID = index
            }
            guard let index = sampleIndexByID?[sample.id] else { continue }

            let existing = state.samples[index]
            let shouldEnrichProjectID = existing.projectID == nil && sample.projectID != nil
            let shouldEnrichProjectName = existing.projectName == nil && sample.projectName != nil
            guard shouldEnrichProjectID || shouldEnrichProjectName else { continue }

            state.samples[index] = existing.withProject(
                projectID: sample.projectID,
                projectName: sample.projectName
            )
            enrichedExistingSamples = true
        }

        let newSamples = samples.filter { !state.seenSampleIDs.contains($0.id) }
        guard !newSamples.isEmpty || enrichedExistingSamples else { return 0 }

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

    public func updateSourceFingerprints(_ fingerprints: [String: FileFingerprint]) throws {
        guard state.sourceFingerprints != fingerprints else { return }
        state.sourceFingerprints = fingerprints
        try save()
    }

    public func updateSourceMetadata(
        fingerprints: [String: FileFingerprint],
        cursors: [String: FileScanCursor]
    ) throws {
        guard state.sourceFingerprints != fingerprints || state.sourceCursors != cursors else { return }
        state.sourceFingerprints = fingerprints
        state.sourceCursors = cursors
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
            hasExplicitSessionReset: true,
            sourceFingerprints: state.sourceFingerprints,
            sourceCursors: state.sourceCursors
        )
        try save()
    }

    public func statistics(
        activeSourcePath: String?,
        issues: [TokenMonitorIssue],
        now: Date = Date()
    ) -> TokenUsageStatistics {
        let allSamples = state.samples
        let sessionSamples = sessionSamples(from: allSamples, activeSourcePath: activeSourcePath)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: todayStart, end: tomorrowStart)
        let monthInterval = calendar.dateInterval(of: .month, for: now)
            ?? DateInterval(start: todayStart, end: tomorrowStart)

        let todaySamples = samples(allSamples, in: DateInterval(start: todayStart, end: tomorrowStart))
        let yesterdaySamples = samples(allSamples, in: DateInterval(start: yesterdayStart, end: todayStart))
        let weekSamples = samples(allSamples, in: weekInterval)
        let monthSamples = samples(allSamples, in: monthInterval)

        var totalTokens = 0
        for sample in allSamples {
            totalTokens += sample.totalTokens
        }

        var sessionTokens = 0
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var peak = 0
        var hasRealSample = false
        var last10Tokens: [Int] = []
        last10Tokens.reserveCapacity(10)

        for sample in sessionSamples {
            sessionTokens += sample.totalTokens
            inputTokens += sample.inputTokens
            cachedInputTokens += sample.cachedInputTokens
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
            cachedInputTokens: cachedInputTokens,
            requestCount: sessionSamples.count,
            dailyCostUSD: nil,
            monthlyCostUSD: nil,
            budgetUSD: nil,
            budgetUsedRatio: nil,
            dataSource: "Codex local session logs",
            modelBreakdown: [],
            projectBreakdown: projectBreakdown(from: monthSamples),
            apiKeyBreakdown: [],
            todayUsage: periodSummary(label: "Today", samples: todaySamples),
            yesterdayUsage: periodSummary(label: "Yesterday", samples: yesterdaySamples),
            currentWeekUsage: periodSummary(label: "This week", samples: weekSamples),
            currentMonthUsage: periodSummary(label: "This month", samples: monthSamples),
            recentDailyUsage: recentDailyUsage(from: allSamples, calendar: calendar, todayStart: todayStart),
            todayProjectBreakdown: projectBreakdown(from: todaySamples)
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

    private func samples(_ samples: [TokenUsageSample], in interval: DateInterval) -> [TokenUsageSample] {
        samples.filter { interval.contains($0.timestamp) }
    }

    private func periodSummary(label: String, samples: [TokenUsageSample]) -> UsagePeriodSummary {
        var input = 0
        var cachedInput = 0
        var output = 0
        var total = 0
        for sample in samples {
            input += sample.inputTokens
            cachedInput += sample.cachedInputTokens
            output += sample.outputTokens
            total += sample.totalTokens
        }
        return UsagePeriodSummary(
            label: label,
            inputTokens: input,
            cachedInputTokens: cachedInput,
            outputTokens: output,
            totalTokens: total,
            requests: samples.count
        )
    }

    private func recentDailyUsage(
        from allSamples: [TokenUsageSample],
        calendar: Calendar,
        todayStart: Date
    ) -> [UsagePeriodSummary] {
        let monthStart = calendar.dateInterval(of: .month, for: todayStart)?.start ?? todayStart
        let dayCount = (calendar.dateComponents([.day], from: monthStart, to: todayStart).day ?? 0) + 1
        var summaries: [UsagePeriodSummary] = []
        summaries.reserveCapacity(dayCount)

        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                continue
            }
            let label: String
            if offset == 0 {
                label = "Today"
            } else if offset == 1 {
                label = "Yesterday"
            } else {
                label = Self.dayLabel(for: dayStart)
            }
            summaries.append(
                periodSummary(
                    label: label,
                    samples: samples(allSamples, in: DateInterval(start: dayStart, end: dayEnd))
                )
            )
        }

        return summaries
    }

    private func projectBreakdown(from samples: [TokenUsageSample]) -> [UsageBreakdown] {
        var breakdown: [String: UsageBreakdown] = [:]
        for sample in samples {
            let key = sample.projectID ?? "unknown"
            let label = sample.projectName ?? "Unknown Project"
            var item = breakdown[key] ?? UsageBreakdown(label: label)
            item.inputTokens += sample.inputTokens
            item.cachedInputTokens += sample.cachedInputTokens
            item.outputTokens += sample.outputTokens
            item.totalTokens += sample.totalTokens
            item.requests += 1
            breakdown[key] = item
        }

        return breakdown.values.sorted {
            if $0.totalTokens == $1.totalTokens {
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            return $0.totalTokens > $1.totalTokens
        }
    }

    private static func dayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
