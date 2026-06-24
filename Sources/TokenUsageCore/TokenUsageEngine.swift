import Foundation

public struct FileFingerprint: Equatable, Sendable {
    public var size: UInt64
    public var modifiedAt: Date
}

public final class TokenUsageEngine: @unchecked Sendable {
    private let store: TokenUsageStore
    private let parser: TokenUsageParser
    private var discovery: TokenSourceDiscovery
    private var fingerprints: [String: FileFingerprint] = [:]
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

        for source in sources {
            guard let fingerprint = fingerprint(for: source) else {
                issues.append(.tokenUsageFileMissing(source.path))
                continue
            }

            if fingerprints[source.path] == fingerprint {
                continue
            }

            parsedAnySource = true
            fingerprints[source.path] = fingerprint

            let result = parser.parse(url: source)
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
        let baselineIDs = sources.flatMap { parser.parse(url: $0).samples.map(\.id) }
        try store.resetAll(markSeen: baselineIDs)
        fingerprints.removeAll()
        cachedSources = sources
        lastDiscoveryAt = Date()
        activeSourceURL = sources.first
        lastIssues = sources.isEmpty ? [.codexLogsNotFound] : []
        return store.statistics(activeSourcePath: activeSourceURL?.path, issues: lastIssues)
    }

    public func report() -> TokenUsageReport {
        store.report(activeSourcePath: activeSourceURL?.path, issues: lastIssues)
    }

    public func writeReportJSON(to destinationURL: URL) throws {
        try store.saveReportJSON(report(), to: destinationURL)
    }

    public func writeMarkdownReport(to destinationURL: URL) throws {
        let report = report()
        let stats = report.statistics
        let text = """
        # Codex Token Usage Report

        Generated: \(Formatters.isoString(from: report.generatedAt))
        Session started: \(Formatters.isoString(from: report.sessionStartedAt))
        Mode: \(stats.mode.rawValue)
        Status: \(stats.status.rawValue)

        ## Current Session

        - Current session prompts: \(stats.currentSessionPrompts)
        - Session tokens: \(stats.sessionTokens)
        - Input tokens: \(stats.inputTokens)
        - Output tokens: \(stats.outputTokens)
        - Cached input tokens: \(stats.cachedInputTokens)
        - Requests: \(stats.requestCount)
        - Daily cost USD: \(stats.dailyCostUSD.map { String(format: "%.4f", $0) } ?? "n/a")
        - Monthly cost USD: \(stats.monthlyCostUSD.map { String(format: "%.4f", $0) } ?? "n/a")
        - Average tokens per prompt: \(Formatters.decimal(stats.averageTokensPerPrompt))
        - Last 10 prompts average: \(Formatters.decimal(stats.last10PromptsAverage))
        - Peak prompt cost: \(stats.peakPromptCost)

        ## Totals

        - Total prompts: \(stats.totalPrompts)
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
