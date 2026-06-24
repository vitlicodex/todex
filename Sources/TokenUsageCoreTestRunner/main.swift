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

private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("CodexTokenMenuBarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sample(id: String, timestamp: Date, input: Int, output: Int) -> TokenUsageSample {
    TokenUsageSample(
        id: id,
        timestamp: timestamp,
        inputTokens: input,
        outputTokens: output,
        totalTokens: input + output,
        mode: .real,
        sourceID: "source",
        sourcePath: "/tmp/source.jsonl"
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
    ("Codex permission monitoring", testPermissionMonitorFlagsBroadPermissions),
    ("Permission presets", testPermissionPresetLevelsApplyExpectedRules),
    ("Usage store aggregation", testStoreAggregatesSessionAndTotalStatistics),
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
