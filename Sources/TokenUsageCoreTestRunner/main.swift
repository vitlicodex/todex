import Foundation
import TokenUsageCore

nonisolated(unsafe) private var failures: [String] = []

@discardableResult
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if condition() {
        return true
    }
    failures.append(message)
    return false
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        failures.append("\(message). Expected \(expected), got \(actual).")
    }
}

private func expectThrows(_ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        failures.append(message)
    } catch {
        // Expected failure.
    }
}

private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("CodexTokenMenuBarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sample(
    id: String,
    timestamp: Date,
    input: Int,
    output: Int,
    projectID: String? = nil,
    projectName: String? = nil
) -> TokenUsageSample {
    TokenUsageSample(
        id: id,
        timestamp: timestamp,
        inputTokens: input,
        outputTokens: output,
        totalTokens: input + output,
        mode: .real,
        sourceID: "source",
        sourcePath: "/tmp/source.jsonl",
        projectID: projectID,
        projectName: projectName
    )
}

private func testParsesOpenAIStyleUsageJSON() {
    let parser = TokenUsageParser()
    let url = URL(fileURLWithPath: "/tmp/usage.json")
    let data = """
    {
      "id": "response-1",
      "created_at": "2026-06-23T10:00:00.000Z",
      "usage": {
        "input_tokens": 1200,
        "output_tokens": 300,
        "total_tokens": 1500
      }
    }
    """.data(using: .utf8)!

    let result = parser.parse(data: data, sourceURL: url, fallbackDate: Date(timeIntervalSince1970: 0))

    expect(result.issues.isEmpty, "OpenAI usage JSON should parse without issues.")
    expectEqual(result.samples.count, 1, "OpenAI usage JSON should produce one sample.")
    guard let sample = result.samples.first else { return }
    expectEqual(sample.inputTokens, 1200, "OpenAI input token count should match.")
    expectEqual(sample.outputTokens, 300, "OpenAI output token count should match.")
    expectEqual(sample.totalTokens, 1500, "OpenAI total token count should match.")
    expectEqual(sample.mode, .real, "OpenAI sample mode should be real.")
}

private func testCodexTokenCountUsesLastUsageOnly() {
    let parser = TokenUsageParser()
    let url = URL(fileURLWithPath: "/tmp/codex-session.jsonl")
    let data = """
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"total_tokens":1200},"last_token_usage":{"input_tokens":120,"cached_input_tokens":40,"output_tokens":30,"total_tokens":150}}}}
    """.data(using: .utf8)!

    let result = parser.parse(data: data, sourceURL: url, fallbackDate: Date(timeIntervalSince1970: 0))

    expect(result.issues.isEmpty, "Codex token_count line should parse without issues.")
    expectEqual(result.samples.count, 1, "Codex token_count line should produce one sample.")
    guard let sample = result.samples.first else { return }
    expectEqual(sample.inputTokens, 120, "Codex parser should use last input tokens.")
    expectEqual(sample.outputTokens, 30, "Codex parser should use last output tokens.")
    expectEqual(sample.totalTokens, 150, "Codex parser should use last total tokens.")
}

private func testStreamingCodexSessionParserSkipsPromptLines() throws {
    let temp = try temporaryDirectory()
    let sessions = temp
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let url = sessions.appendingPathComponent("rollout.jsonl")
    let text = """
    {"type":"user_message","content":"private prompt-like line must be ignored"}
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15}}}}
    """
    try text.write(to: url, atomically: true, encoding: .utf8)

    let result = TokenUsageParser().parse(url: url)

    expect(result.issues.isEmpty, "Codex session stream should skip prompt-like lines.")
    expectEqual(result.samples.count, 1, "Codex session stream should produce one sample.")
    expectEqual(result.samples.first?.totalTokens, 15, "Codex session stream should parse token_count total.")
}

private func testStreamingCodexSessionParserSkipsInvalidNonTokenLines() throws {
    let temp = try temporaryDirectory()
    let sessions = temp
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let url = sessions.appendingPathComponent("rollout.jsonl")
    var data = Data([0xff, 0xfe, 0xfd, 0x0a])
    data.append(
        """
        {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9,"output_tokens":1,"total_tokens":10}}}}
        """.data(using: .utf8)!
    )
    try data.write(to: url)

    let result = TokenUsageParser().parse(url: url)

    expect(result.issues.isEmpty, "Codex session stream should ignore invalid private non-token lines.")
    expectEqual(result.samples.count, 1, "Codex session stream should still parse the token_count line.")
    expectEqual(result.samples.first?.totalTokens, 10, "Codex session stream should parse token_count after skipped invalid line.")
}

private func testCodexSessionParserAttachesProjectMetadata() throws {
    let temp = try temporaryDirectory()
    let project = temp.appendingPathComponent("alpha", isDirectory: true)
    let sessions = temp
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let url = sessions.appendingPathComponent("rollout.jsonl")
    let text = """
    {"timestamp":"2026-06-23T09:59:59.000Z","type":"session_meta","payload":{"cwd":"\(project.path)","originator":"Codex Desktop"}}
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":21,"output_tokens":4,"total_tokens":25}}}}
    """
    try text.write(to: url, atomically: true, encoding: .utf8)

    let result = TokenUsageParser().parse(url: url)

    expect(result.issues.isEmpty, "Codex session parser should attach project metadata without issues.")
    expectEqual(result.samples.count, 1, "Codex project metadata test should produce one sample.")
    expectEqual(result.samples.first?.projectName, "alpha", "Codex project name should use the workspace folder name.")
    expect(result.samples.first?.projectID?.isEmpty == false, "Codex project id should be a non-empty stable hash.")
}

private func testPermissionMonitorFlagsBroadPermissions() throws {
    let temp = try temporaryDirectory()
    let codex = temp.appendingPathComponent(".codex", isDirectory: true)
    let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try "trust_level = \"trusted\"".write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let url = sessions.appendingPathComponent("rollout.jsonl")
    try """
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":{"type":"danger-full-access","network_access":true},"permission_profile":{"type":"disabled","file_system":{"type":"unrestricted"},"network":"enabled"}}}
    """.write(to: url, atomically: true, encoding: .utf8)

    let snapshot = CodexPermissionMonitor(homeDirectory: temp).snapshot()

    expectEqual(snapshot.status, .highUsage, "Broad Codex permissions should classify as high usage risk.")
    expectEqual(snapshot.networkAccess, true, "Permission monitor should detect network access.")
    expect(!snapshot.policyViolations.isEmpty, "Broad Codex permissions should produce policy violations.")
}

private func testPermissionPresetLevelsApplyExpectedRules() {
    var settings = MonitorSettings()

    settings.applyPermissionPreset(.fullAccess)
    expect(CodexPermissionRule.allCases.allSatisfy { settings.isPermissionRuleAllowed($0) }, "Full Access should allow every rule.")

    settings.applyPermissionPreset(.automation)
    expect(settings.isPermissionRuleAllowed(.networkAccess), "Automation should allow network access.")
    expect(settings.isPermissionRuleAllowed(.unattendedAutomation), "Automation should allow unattended automation.")
    expect(!settings.isPermissionRuleAllowed(.fullFileSystemAccess), "Automation should block full filesystem access.")
    expect(!settings.isPermissionRuleAllowed(.fullAccessMode), "Automation should block full access mode.")

    settings.applyPermissionPreset(.balanced)
    expect(settings.isPermissionRuleAllowed(.workspaceCodeWrite), "Balanced should allow workspace code edits.")
    expect(settings.isPermissionRuleAllowed(.workspaceFileWrite), "Balanced should allow workspace file writes.")
    expect(!settings.isPermissionRuleAllowed(.runWithoutApproval), "Balanced should block no-approval mode.")
    expect(!settings.isPermissionRuleAllowed(.networkAccess), "Balanced should block network access.")

    settings.applyPermissionPreset(.lockedDown)
    expect(settings.isPermissionRuleAllowed(.localSessionMetadataRead), "Locked Down should allow local metadata monitoring.")
    expect(!settings.isPermissionRuleAllowed(.workspaceFileWrite), "Locked Down should block workspace writes.")
    expect(!settings.isPermissionRuleAllowed(.networkAccess), "Locked Down should block network access.")
}

private func testStoreAggregatesSessionAndTotalStatistics() throws {
    let temp = try temporaryDirectory()
    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    try store.resetAll(sessionStartedAt: Date(timeIntervalSince1970: 1_000))

    let old = sample(id: "old", timestamp: Date(timeIntervalSince1970: 900), input: 10, output: 5)
    let current = sample(id: "current", timestamp: Date(timeIntervalSince1970: 1_100), input: 100, output: 50)
    try store.add([old, current])

    let stats = store.statistics(activeSourcePath: "/tmp/events.jsonl", issues: [])

    expectEqual(stats.currentSessionPrompts, 1, "Session prompt count should use session start.")
    expectEqual(stats.totalPrompts, 2, "Total prompt count should include all samples.")
    expectEqual(stats.sessionTokens, 150, "Session token count should include current sample only.")
    expectEqual(stats.totalTokens, 165, "Total token count should include all samples.")
    expectEqual(stats.inputTokens, 100, "Session input token count should include current sample only.")
    expectEqual(stats.outputTokens, 50, "Session output token count should include current sample only.")
    expectEqual(stats.peakPromptCost, 150, "Peak prompt cost should match current sample.")
}

private func testStoreEnrichesExistingSampleProjectMetadata() throws {
    let temp = try temporaryDirectory()
    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    let timestamp = Date()
    let original = sample(id: "same", timestamp: timestamp, input: 10, output: 2)
    let enriched = sample(
        id: "same",
        timestamp: timestamp,
        input: 10,
        output: 2,
        projectID: "project-alpha",
        projectName: "alpha"
    )

    let firstImportCount = try store.add([original])
    let secondImportCount = try store.add([enriched])

    expectEqual(firstImportCount, 1, "First store import should add the sample.")
    expectEqual(secondImportCount, 0, "Project enrichment should not count as a new sample.")
    expectEqual(store.state.samples.count, 1, "Project enrichment should not duplicate the sample.")
    expectEqual(store.state.samples.first?.projectName, "alpha", "Project enrichment should update project name.")
    expectEqual(store.state.samples.first?.projectID, "project-alpha", "Project enrichment should update project id.")
}

private func testStorePersistsDailyHistoryAndProjectBreakdown() throws {
    let temp = try temporaryDirectory()
    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    let calendar = Calendar.current
    let now = Date()
    let todayStart = calendar.startOfDay(for: now)
    let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
    let today = calendar.date(byAdding: .hour, value: 1, to: todayStart) ?? now
    let yesterday = calendar.date(byAdding: .hour, value: 1, to: yesterdayStart) ?? now

    try store.resetAll(sessionStartedAt: yesterdayStart)
    try store.add([
        sample(id: "today-alpha", timestamp: today, input: 100, output: 50, projectID: "project-alpha", projectName: "alpha"),
        sample(id: "today-beta", timestamp: today.addingTimeInterval(10), input: 20, output: 5, projectID: "project-beta", projectName: "beta"),
        sample(id: "yesterday-alpha", timestamp: yesterday, input: 30, output: 10, projectID: "project-alpha", projectName: "alpha")
    ])

    let stats = store.statistics(activeSourcePath: nil, issues: [], now: now)

    expectEqual(stats.todayUsage.totalTokens, 175, "Today usage should include today's samples after restart-safe persistence.")
    expectEqual(stats.yesterdayUsage.totalTokens, 40, "Yesterday usage should include yesterday's samples.")
    expectEqual(stats.currentMonthUsage.totalTokens >= 215, true, "Current month usage should include recent samples.")
    expectEqual(stats.todayProjectBreakdown.first?.label, "alpha", "Today project breakdown should be sorted by token count.")
    expectEqual(stats.todayProjectBreakdown.first?.totalTokens, 150, "Today project breakdown should aggregate tokens by project.")
    expect(stats.recentDailyUsage.contains { $0.label == "Today" && $0.totalTokens == 175 }, "Recent daily usage should include today.")
}

private func testStoreDecodesLegacyStateWithoutFingerprints() throws {
    let temp = try temporaryDirectory()
    let url = temp.appendingPathComponent("stats.json")
    let text = """
    {
      "sessionStartedAt": "2026-06-23T10:00:00Z",
      "samples": [],
      "seenSampleIDs": [],
      "hasExplicitSessionReset": true
    }
    """
    try text.write(to: url, atomically: true, encoding: .utf8)

    let store = TokenUsageStore(stateURL: url)

    expect(store.state.sourceFingerprints.isEmpty, "Legacy stats.json should decode with empty source fingerprints.")
    expect(store.state.sourceCursors.isEmpty, "Legacy stats.json should decode with empty source cursors.")
    expect(store.state.samples.isEmpty, "Legacy stats.json should preserve samples while decoding.")
}

private func testEnginePersistsSourceFingerprintsAcrossRestart() throws {
    let temp = try temporaryDirectory()
    let sessions = temp
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let source = sessions.appendingPathComponent("rollout.jsonl")
    try """
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15}}}}
    """.write(to: source, atomically: true, encoding: .utf8)

    let storeURL = temp.appendingPathComponent("stats.json")
    let store = TokenUsageStore(stateURL: storeURL)
    let discovery = TokenSourceDiscovery(homeDirectory: temp)
    let engine = TokenUsageEngine(store: store, discovery: discovery)

    let firstStats = engine.refresh(force: true)
    expectEqual(firstStats.totalTokens, 15, "First refresh should import source token usage.")
    expect(!store.state.sourceFingerprints.isEmpty, "First refresh should persist source fingerprints.")

    let reloadedStore = TokenUsageStore(stateURL: storeURL)
    let reloadedEngine = TokenUsageEngine(store: reloadedStore, discovery: discovery)
    let reloadedStats = reloadedEngine.refresh(force: true)

    expect(!reloadedStore.state.sourceFingerprints.isEmpty, "Reloaded store should retain source fingerprints.")
    expectEqual(reloadedStats.totalTokens, 15, "Reloaded engine should keep persisted totals without duplicating samples.")
    expectEqual(reloadedStore.state.samples.count, 1, "Reloaded engine should not duplicate already imported samples.")
}

private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer {
        try? handle.close()
    }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

private func testEngineUsesIncrementalCursorForAppendedSessionLog() throws {
    let temp = try temporaryDirectory()
    let project = temp.appendingPathComponent("alpha", isDirectory: true)
    let sessions = temp
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let source = sessions.appendingPathComponent("rollout.jsonl")
    try """
    {"timestamp":"2026-06-23T09:59:59.000Z","type":"session_meta","payload":{"cwd":"\(project.path)","originator":"Codex Desktop"}}
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15}}}}
    """.write(to: source, atomically: true, encoding: .utf8)

    let storeURL = temp.appendingPathComponent("stats.json")
    let store = TokenUsageStore(stateURL: storeURL)
    let discovery = TokenSourceDiscovery(homeDirectory: temp)
    let engine = TokenUsageEngine(store: store, discovery: discovery)

    let firstStats = engine.refresh(force: true)
    let firstCursor = store.state.sourceCursors.values.first
    expectEqual(firstStats.totalTokens, 15, "Initial incremental test import should parse the first sample.")
    expect(firstCursor?.offset ?? 0 > 0, "Initial import should persist a scan cursor.")
    expectEqual(firstCursor?.projectName, "alpha", "Initial import should persist project metadata for the cursor.")

    try append(
        "\n{\"timestamp\":\"2026-06-23T10:01:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":8,\"output_tokens\":2,\"total_tokens\":10}}}}\n",
        to: source
    )
    let secondStats = engine.refresh(force: true)
    let secondCursor = store.state.sourceCursors.values.first

    expectEqual(secondStats.totalTokens, 25, "Incremental refresh should add only the appended sample.")
    expectEqual(store.state.samples.count, 2, "Incremental refresh should not duplicate existing samples.")
    expectEqual(store.state.samples.last?.projectName, "alpha", "Incremental refresh should carry project metadata into appended samples.")
    expect((secondCursor?.offset ?? 0) > (firstCursor?.offset ?? 0), "Incremental refresh should advance the scan cursor.")

    let reloadedStore = TokenUsageStore(stateURL: storeURL)
    let reloadedEngine = TokenUsageEngine(store: reloadedStore, discovery: discovery)
    try append(
        "{\"timestamp\":\"2026-06-23T10:02:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":4,\"output_tokens\":1,\"total_tokens\":5}}}}\n",
        to: source
    )
    let thirdStats = reloadedEngine.refresh(force: true)

    expectEqual(thirdStats.totalTokens, 30, "Reloaded engine should resume from the persisted cursor.")
    expectEqual(reloadedStore.state.samples.count, 3, "Reloaded incremental refresh should append one new sample.")
    expectEqual(reloadedStore.state.samples.last?.projectName, "alpha", "Reloaded cursor should retain project metadata.")
}

private func testPrivateFileIORejectsSymlinkDestination() throws {
    let temp = try temporaryDirectory()
    let realFile = temp.appendingPathComponent("real.json")
    let symlink = temp.appendingPathComponent("stats.json")
    try Data("{}".utf8).write(to: realFile)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realFile)

    expectThrows("Private file writer should reject symlink destinations.") {
        try PrivateFileIO.writePrivateData(Data("{}".utf8), to: symlink)
    }
    let realContents = try String(contentsOf: realFile, encoding: .utf8)
    expectEqual(realContents, "{}", "Private file writer should not modify the symlink target.")
}

private func testParserRefusesOversizedStructuredJSONFile() throws {
    let temp = try temporaryDirectory()
    let url = temp.appendingPathComponent("usage.json")
    try String(repeating: " ", count: 128).write(to: url, atomically: true, encoding: .utf8)
    let parser = TokenUsageParser(maxStructuredJSONBytes: 64)

    let result = parser.parse(url: url)

    expect(result.samples.isEmpty, "Oversized structured JSON should not produce samples.")
    expectEqual(
        result.issues,
        [.unreadableSource(url.path, "Structured JSON file is too large to parse safely.")],
        "Oversized structured JSON should return a safe refusal issue."
    )
}

private let tests: [(String, () throws -> Void)] = [
    ("OpenAI usage JSON parsing", testParsesOpenAIStyleUsageJSON),
    ("Codex token_count parsing", testCodexTokenCountUsesLastUsageOnly),
    ("Codex session prompt skipping", testStreamingCodexSessionParserSkipsPromptLines),
    ("Codex invalid non-token line skipping", testStreamingCodexSessionParserSkipsInvalidNonTokenLines),
    ("Codex project metadata parsing", testCodexSessionParserAttachesProjectMetadata),
    ("Codex permission monitoring", testPermissionMonitorFlagsBroadPermissions),
    ("Permission presets", testPermissionPresetLevelsApplyExpectedRules),
    ("Usage store aggregation", testStoreAggregatesSessionAndTotalStatistics),
    ("Usage store project enrichment", testStoreEnrichesExistingSampleProjectMetadata),
    ("Usage store daily history", testStorePersistsDailyHistoryAndProjectBreakdown),
    ("Legacy state migration", testStoreDecodesLegacyStateWithoutFingerprints),
    ("Source fingerprint persistence", testEnginePersistsSourceFingerprintsAcrossRestart),
    ("Incremental source cursor", testEngineUsesIncrementalCursorForAppendedSessionLog),
    ("Private file symlink refusal", testPrivateFileIORejectsSymlinkDestination),
    ("Oversized JSON refusal", testParserRefusesOversizedStructuredJSONFile)
]

for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        failures.append("\(name) threw unexpected error: \(error)")
    }
}

if failures.isEmpty {
    print("All TokenUsageCore checks passed.")
} else {
    FileHandle.standardError.write(Data(("TokenUsageCore checks failed:\n" + failures.map { "- \($0)" }.joined(separator: "\n") + "\n").utf8))
    exit(1)
}
