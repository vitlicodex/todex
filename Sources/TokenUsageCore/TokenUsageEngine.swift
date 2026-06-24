import Foundation

public struct FileFingerprint: Codable, Equatable, Sendable {
    public var size: UInt64
    public var modifiedAt: Date
}

public final class TokenUsageEngine: @unchecked Sendable {
    private let store: TokenUsageStore
    private let parser: TokenUsageParser
    private var discovery: TokenSourceDiscovery
    private var fingerprints: [String: FileFingerprint] = [:]
    private var sourceCursors: [String: FileScanCursor] = [:]
    private var cachedSources: [URL] = []
    private var lastDiscoveryAt: Date?
    private let discoveryCacheInterval: TimeInterval = 15
    private(set) public var activeSourceURL: URL?
    private(set) public var lastIssues: [TokenMonitorIssue] = []

    public init(
        store: TokenUsageStore = TokenUsageStore(),
        parser: TokenUsageParser = TokenUsageParser(),
        discovery: TokenSourceDiscovery = TokenSourceDiscovery()
    ) {
        self.store = store
        self.parser = parser
        self.discovery = discovery
        self.fingerprints = store.state.sourceFingerprints
        self.sourceCursors = store.state.sourceCursors
    }

    @discardableResult
    public func refresh(force: Bool = false) -> TokenUsageStatistics {
        let sources = discoveredSources(force: force)
        var issues: [TokenMonitorIssue] = []

        if sources.isEmpty {
            issues.append(.codexLogsNotFound)
            lastIssues = issues
            return store.statistics(activeSourcePath: activeSourceURL?.path, issues: issues)
        }

        var parsedAnySource = false
        var importedSamples: [TokenUsageSample] = []
        var noUsageIssues: [TokenMonitorIssue] = []

        if activeSourceURL == nil {
            activeSourceURL = sources.first
        }

        for source in sources {
            guard let fingerprint = fingerprint(for: source) else {
                issues.append(.tokenUsageFileMissing(source.path))
                continue
            }

            let previousFingerprint = fingerprints[source.path]
            if previousFingerprint == fingerprint {
                continue
            }

            parsedAnySource = true
            let result = parse(source: source, fingerprint: fingerprint, previousFingerprint: previousFingerprint)
            let finalFingerprint = self.fingerprint(for: source) ?? fingerprint
            fingerprints[source.path] = finalFingerprint
            updateCursor(for: source, fingerprint: finalFingerprint, result: result)
            for issue in result.issues {
                if case .apiUsageFieldsUnavailable = issue {
                    noUsageIssues.append(issue)
                } else {
                    issues.append(issue)
                }
            }
            importedSamples.append(contentsOf: result.samples)
        }

        do {
            _ = try store.add(importedSamples)
            try store.updateSourceMetadata(fingerprints: fingerprints, cursors: sourceCursors)
            updateActiveSource(from: importedSamples)
        } catch {
            issues.append(.unreadableSource(store.stateURL.path, error.localizedDescription))
        }

        if parsedAnySource && importedSamples.isEmpty && issues.isEmpty {
            if let firstIssue = noUsageIssues.first {
                issues.append(firstIssue)
            } else if let firstSource = sources.first {
                issues.append(.apiUsageFieldsUnavailable(firstSource.path))
            }
        }

        lastIssues = issues
        return store.statistics(activeSourcePath: activeSourceURL?.path, issues: issues)
    }

    public func resetSession() throws -> TokenUsageStatistics {
        try store.resetSession()
        return store.statistics(activeSourcePath: activeSourceURL?.path, issues: lastIssues)
    }

    public func resetAllWithCurrentSourcesAsBaseline() throws -> TokenUsageStatistics {
        let sources = discoveredSources(force: true)
        var baselineIDs: [String] = []
        var baselineFingerprints: [String: FileFingerprint] = [:]
        var baselineCursors: [String: FileScanCursor] = [:]
        baselineIDs.reserveCapacity(sources.count)

        for source in sources {
            if let fingerprint = fingerprint(for: source) {
                baselineFingerprints[source.path] = fingerprint
            }
            let result = parser.parse(url: source)
            if let fingerprint = self.fingerprint(for: source) ?? baselineFingerprints[source.path] {
                baselineFingerprints[source.path] = fingerprint
                baselineCursors[source.path] = FileScanCursor(
                    offset: min(result.parsedBytes ?? fingerprint.size, fingerprint.size),
                    lineCount: result.parsedLineCount ?? 0,
                    projectID: result.projectID,
                    projectName: result.projectName
                )
            }
            baselineIDs.append(contentsOf: result.samples.map(\.id))
        }

        try store.resetAll(markSeen: baselineIDs)
        fingerprints = baselineFingerprints
        sourceCursors = baselineCursors
        try store.updateSourceMetadata(fingerprints: fingerprints, cursors: sourceCursors)
        cachedSources = sources
        lastDiscoveryAt = Date()
        activeSourceURL = sources.first
        lastIssues = sources.isEmpty ? [.codexLogsNotFound] : []
        return store.statistics(activeSourcePath: activeSourceURL?.path, issues: lastIssues)
    }

    public func report() -> TokenUsageReport {
        store.report(activeSourcePath: activeSourceURL?.path, issues: lastIssues)
    }

    public func cachedStatistics() -> TokenUsageStatistics {
        store.statistics(activeSourcePath: activeSourceURL?.path, issues: lastIssues)
    }

    public func writeReportJSON(to destinationURL: URL) throws {
        try store.saveReportJSON(report(), to: destinationURL)
    }

    public func writeMarkdownReport(to destinationURL: URL) throws {
        let report = report().privacyRedactedForReport()
        let stats = report.statistics
        let text = """
        # TODEX Usage Report

        Generated: \(Formatters.isoString(from: report.generatedAt))
        Session started: \(Formatters.isoString(from: report.sessionStartedAt))
        Mode: \(stats.mode.rawValue)
        Status: \(stats.status.rawValue)

        ## Current Session

        - Current session requests: \(stats.currentSessionPrompts)
        - Session tokens: \(stats.sessionTokens)
        - Input tokens: \(stats.inputTokens)
        - Output tokens: \(stats.outputTokens)
        - Cached input tokens: \(stats.cachedInputTokens)
        - Requests: \(stats.requestCount)
        - Daily cost USD: \(stats.dailyCostUSD.map { String(format: "%.4f", $0) } ?? "n/a")
        - Monthly cost USD: \(stats.monthlyCostUSD.map { String(format: "%.4f", $0) } ?? "n/a")
        - Today average tokens per request: \(Formatters.decimal(TokenUsageUIDisplay.averageTokensPerRequest(stats.todayUsage)))
        - Session average tokens per request: \(Formatters.decimal(stats.averageTokensPerPrompt))
        - Last 10 request average: \(Formatters.decimal(stats.last10PromptsAverage))
        - Peak request tokens: \(stats.peakPromptCost)

        ## Usage Log

        - Today: \(stats.todayUsage.totalTokens) tokens, \(stats.todayUsage.requests) requests
        - Yesterday: \(stats.yesterdayUsage.totalTokens) tokens, \(stats.yesterdayUsage.requests) requests
        - This week: \(stats.currentWeekUsage.totalTokens) tokens, \(stats.currentWeekUsage.requests) requests
        - This month: \(stats.currentMonthUsage.totalTokens) tokens, \(stats.currentMonthUsage.requests) requests

        ## Daily History

        \(stats.recentDailyUsage.isEmpty ? "- No daily history yet" : stats.recentDailyUsage.map { "- \($0.label): \($0.totalTokens) tokens, \($0.requests) requests" }.joined(separator: "\n"))

        ## Codex Projects Today

        \(stats.todayProjectBreakdown.isEmpty ? "- No project metadata yet" : stats.todayProjectBreakdown.map { "- \($0.label): \($0.totalTokens) tokens, \($0.requests) requests" }.joined(separator: "\n"))

        ## Totals

        - Total requests: \(stats.totalPrompts)
        - Total tokens: \(stats.totalTokens)
        - Active source: \(stats.activeSourcePath ?? "None")

        ## Issues

        \(stats.issues.isEmpty ? "- None" : stats.issues.map { "- \($0.message)" }.joined(separator: "\n"))

        This report contains numeric usage statistics and technical metadata only.
        """

        try PrivateFileIO.writePrivateString(text, to: destinationURL)
    }

    public func defaultReportURL() -> URL {
        store.stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("token-report.md")
    }

    public func defaultExportURL() -> URL {
        store.stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("token-report.json")
    }

    private func fingerprint(for url: URL) -> FileFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }

        return FileFingerprint(
            size: UInt64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
    }

    private func discoveredSources(force: Bool) -> [URL] {
        let now = Date()
        if !force,
           let lastDiscoveryAt,
           now.timeIntervalSince(lastDiscoveryAt) < discoveryCacheInterval {
            return cachedSources
        }

        let sources = discovery.discover()
        cachedSources = sources
        lastDiscoveryAt = now
        return sources
    }

    private func parse(
        source: URL,
        fingerprint: FileFingerprint,
        previousFingerprint: FileFingerprint?
    ) -> TokenUsageFileResult {
        guard shouldParseIncrementally(
            source: source,
            fingerprint: fingerprint,
            previousFingerprint: previousFingerprint
        ),
              let cursor = sourceCursors[source.path] else {
            return parser.parse(url: source)
        }

        return parser.parse(
            url: source,
            fromOffset: cursor.offset,
            lineNumber: cursor.lineCount,
            projectID: cursor.projectID,
            projectName: cursor.projectName
        )
    }

    private func shouldParseIncrementally(
        source: URL,
        fingerprint: FileFingerprint,
        previousFingerprint: FileFingerprint?
    ) -> Bool {
        let extensionName = source.pathExtension.lowercased()
        guard extensionName == "jsonl" || extensionName == "log" else {
            return false
        }
        guard let previousFingerprint,
              let cursor = sourceCursors[source.path],
              cursor.offset > 0,
              cursor.offset <= previousFingerprint.size,
              previousFingerprint.size <= fingerprint.size,
              cursor.offset < fingerprint.size else {
            return false
        }
        return true
    }

    private func updateCursor(
        for source: URL,
        fingerprint: FileFingerprint,
        result: TokenUsageFileResult
    ) {
        guard shouldAdvanceCursor(for: result) else { return }
        let previous = sourceCursors[source.path]
        let parsedBytes = min(result.parsedBytes ?? fingerprint.size, fingerprint.size)
        sourceCursors[source.path] = FileScanCursor(
            offset: parsedBytes,
            lineCount: result.parsedLineCount ?? previous?.lineCount ?? 0,
            projectID: result.projectID ?? previous?.projectID,
            projectName: result.projectName ?? previous?.projectName
        )
    }

    private func shouldAdvanceCursor(for result: TokenUsageFileResult) -> Bool {
        for issue in result.issues {
            switch issue {
            case .invalidJSON, .permissionDenied, .unreadableSource:
                return false
            default:
                continue
            }
        }
        return true
    }

    private func updateActiveSource(from samples: [TokenUsageSample]) {
        guard let newestSample = samples.max(by: { $0.timestamp < $1.timestamp }) else {
            return
        }
        activeSourceURL = URL(fileURLWithPath: newestSample.sourcePath)
    }

}

enum Formatters {
    static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
