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

private func expectApprox(_ actual: Double, _ expected: Double, accuracy: Double = 0.000_001, _ message: String) {
    if abs(actual - expected) > accuracy {
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
    cachedInput: Int = 0,
    output: Int,
    sourcePath: String = "/tmp/source.jsonl",
    projectID: String? = nil,
    projectName: String? = nil
) -> TokenUsageSample {
    TokenUsageSample(
        id: id,
        timestamp: timestamp,
        inputTokens: input,
        cachedInputTokens: cachedInput,
        outputTokens: output,
        totalTokens: input + output,
        mode: .real,
        sourceID: "source",
        sourcePath: sourcePath,
        projectID: projectID,
        projectName: projectName
    )
}

private enum MockOpenAIResponse {
    case http(status: Int, headers: [String: String] = [:], body: String = "{}")
    case error(Error)
}

private final class MockOpenAIURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseProvider: ((URLRequest) -> MockOpenAIResponse)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let provider = Self.responseProvider else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch provider(request) {
        case .http(let status, let headers, let body):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class AsyncResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ value: T) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }
}

private func waitForAsync<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<T>()
    Task.detached {
        box.set(await operation())
        semaphore.signal()
    }
    semaphore.wait()
    return box.get()!
}

private func openAIStatsForMockedResponse(_ response: MockOpenAIResponse) -> TokenUsageStatistics {
    MockOpenAIURLProtocol.responseProvider = { _ in response }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockOpenAIURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = OpenAIUsageClient(
        session: session,
        baseURL: URL(string: "https://api.openai.test/v1")!
    )
    var settings = MonitorSettings()
    settings.featureFlags[.costsEndpoint] = false
    let testSettings = settings
    return waitForAsync {
        await client.fetchStatistics(
            apiKey: "test-key-not-real",
            settings: testSettings,
            now: Date(timeIntervalSince1970: 1_783_324_800)
        )
    }
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

private func testOpenAIUsageClientClassifiesHTTPFailures() {
    let rateLimited = openAIStatsForMockedResponse(
        .http(status: 429, headers: ["Retry-After": "12"], body: #"{"error":"slow down"}"#)
    )
    expectEqual(
        rateLimited.issues,
        [.apiRateLimited(retryAfter: "12")],
        "OpenAI client should classify 429 as a rate-limit issue."
    )

    let endpointUnavailable = openAIStatsForMockedResponse(
        .http(status: 404, body: #"{"error":"not found"}"#)
    )
    expectEqual(
        endpointUnavailable.issues,
        [.apiEndpointUnavailable(404)],
        "OpenAI client should classify 404 as endpoint unavailable."
    )

    let serverError = openAIStatsForMockedResponse(
        .http(status: 503, body: #"{"error":"temporary"}"#)
    )
    expectEqual(
        serverError.issues,
        [.apiServerError(503)],
        "OpenAI client should classify 5xx responses as server errors."
    )

    let timeout = openAIStatsForMockedResponse(.error(URLError(.timedOut)))
    expectEqual(
        timeout.issues,
        [.apiTimeout],
        "OpenAI client should classify URLSession timeout errors."
    )
}

private func testCostEstimatorSeparatesCachedInputAndMultiplier() {
    let profile = TokenPricingProfile(
        name: "Test",
        inputPerMillionUSD: 5,
        cachedInputPerMillionUSD: 0.5,
        outputPerMillionUSD: 20,
        reasoningPerMillionUSD: 10,
        multiplier: 2
    )

    let estimate = CostEstimator.estimate(
        inputTokens: 1_000_000,
        cachedInputTokens: 200_000,
        outputTokens: 100_000,
        reasoningTokens: 50_000,
        profile: profile
    )

    expectApprox(estimate.inputCostUSD, 4.0, "Estimator should price only uncached input at input rate.")
    expectApprox(estimate.cachedInputCostUSD, 0.1, "Estimator should price cached input at cached rate.")
    expectApprox(estimate.outputCostUSD, 2.0, "Estimator should price output at output rate.")
    expectApprox(estimate.reasoningCostUSD, 0.5, "Estimator should price reasoning at reasoning rate.")
    expectApprox(estimate.totalCostUSD, 13.2, "Estimator should apply multiplier after summing component costs.")
    expectEqual(estimate.pricingProfileName, "Test", "Estimator should preserve pricing profile name for report labels.")
}

private func testCostEstimatorAggregatesSamples() {
    let profile = TokenPricingProfile(
        name: "Aggregate",
        inputPerMillionUSD: 4,
        cachedInputPerMillionUSD: 1,
        outputPerMillionUSD: 8
    )
    let estimate = CostEstimator.estimate(
        samples: [
            sample(id: "a", timestamp: Date(timeIntervalSince1970: 1), input: 100, cachedInput: 40, output: 10),
            sample(id: "b", timestamp: Date(timeIntervalSince1970: 2), input: 200, cachedInput: 50, output: 20)
        ],
        profile: profile
    )

    expectApprox(estimate.inputCostUSD, 0.00084, "Estimator should aggregate uncached input from samples.")
    expectApprox(estimate.cachedInputCostUSD, 0.00009, "Estimator should aggregate cached input from samples.")
    expectApprox(estimate.outputCostUSD, 0.00024, "Estimator should aggregate output from samples.")
    expectApprox(estimate.totalCostUSD, 0.00117, "Estimator should total aggregate sample costs.")
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
    expectEqual(sample.cachedInputTokens, 40, "Codex parser should preserve cached input tokens from last usage.")
    expectEqual(sample.outputTokens, 30, "Codex parser should use last output tokens.")
    expectEqual(sample.totalTokens, 150, "Codex parser should use last total tokens.")
}

private func testParserWarnsWhenSampleLimitTruncatesSource() {
    let parser = TokenUsageParser(maxSamplesPerFile: 1)
    let url = URL(fileURLWithPath: "/tmp/.codex/sessions/rollout.jsonl")
    let data = """
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15}}}}
    {"timestamp":"2026-06-23T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":8,"output_tokens":2,"total_tokens":10}}}}
    """.data(using: .utf8)!

    let result = parser.parse(data: data, sourceURL: url, fallbackDate: Date(timeIntervalSince1970: 0))

    expectEqual(result.samples.count, 1, "Parser should respect the configured sample limit.")
    expectEqual(
        result.issues,
        [.sourceTruncated(url.path, parsedSamples: 1, limit: 1)],
        "Parser should warn when sample limit truncates a source."
    )
}

private func testParserKeepsDistinctRequestsWithSameTimestampAndTokens() {
    let parser = TokenUsageParser()
    let url = URL(fileURLWithPath: "/tmp/.codex/sessions/rollout.jsonl")
    let data = """
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15}}}}
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15}}}}
    """.data(using: .utf8)!

    let result = parser.parse(data: data, sourceURL: url, fallbackDate: Date(timeIntervalSince1970: 0))

    expect(result.issues.isEmpty, "Duplicate-shaped token_count lines should parse without issues.")
    expectEqual(result.samples.count, 2, "Parser should keep distinct requests even when timestamp and token values match.")
    expectEqual(Set(result.samples.map(\.id)).count, 2, "Distinct same-shaped requests should have line-specific stable ids.")
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
    expectEqual(snapshot.fileSystemPolicy, "unrestricted", "Permission monitor should detect unrestricted filesystem access.")
    expect(!snapshot.policyViolations.isEmpty, "Broad Codex permissions should produce policy violations.")
}

private func testPermissionMonitorParsesAlternateTurnContextShapes() throws {
    let temp = try temporaryDirectory()
    let sessions = temp
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let url = sessions.appendingPathComponent("rollout.jsonl")
    try """
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":"danger-full-access","permission_profile":"disabled","network":"enabled"}}
    """.write(to: url, atomically: true, encoding: .utf8)

    let snapshot = CodexPermissionMonitor(homeDirectory: temp).snapshot()

    expectEqual(snapshot.sandboxPolicy, "danger-full-access", "Permission monitor should parse string sandbox policy.")
    expectEqual(snapshot.permissionProfile, "disabled", "Permission monitor should parse string permission profile.")
    expectEqual(snapshot.fileSystemPolicy, "unrestricted", "Danger full access should infer unrestricted filesystem access.")
    expectEqual(snapshot.networkAccess, true, "Permission monitor should parse top-level network metadata.")
}

private func testPermissionMonitorParsesNetworkAndTrustedWorkspaceSafely() throws {
    let temp = try temporaryDirectory()
    let codex = temp.appendingPathComponent(".codex", isDirectory: true)
    let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try """
    # trust_level = "trusted"
    some_other_trust_level = "trusted"
    trust_level = 'trusted'
    """.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let url = sessions.appendingPathComponent("rollout.jsonl")
    try """
    {"timestamp":"2026-06-23T10:00:00.000Z","type": "event_msg","payload": {"type": "turn_context","approval_policy":"on-request","sandbox_policy":"workspace-write","permission_profile":{"type":"standard","network":"disabled"}}}
    """.write(to: url, atomically: true, encoding: .utf8)

    let snapshot = CodexPermissionMonitor(homeDirectory: temp).snapshot()

    expectEqual(snapshot.networkAccess, false, "Disabled permission_profile network should not be treated as enabled.")
    expectEqual(snapshot.trustedWorkspaceCount, 1, "Trusted workspace parser should ignore comments and non-exact keys while accepting single quotes.")
    expect(
        !snapshot.issues.contains("No trusted workspaces were found in Codex config."),
        "Trusted workspace absence/presence should not produce a misleading warning issue."
    )
}

private func testPermissionMonitorParsesTopLevelTurnContext() throws {
    let temp = try temporaryDirectory()
    let codex = temp.appendingPathComponent(".codex", isDirectory: true)
    let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try "model = \"gpt-5\"".write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let url = sessions.appendingPathComponent("rollout.jsonl")
    try """
    {"timestamp":"2026-06-23T10:00:00.000Z","type": "turn_context","approval_policy":"never","sandbox_policy":"workspace-write","network":"enabled"}
    """.write(to: url, atomically: true, encoding: .utf8)

    let snapshot = CodexPermissionMonitor(homeDirectory: temp).snapshot()

    expectEqual(snapshot.approvalPolicy, "never", "Permission monitor should parse top-level turn_context records.")
    expectEqual(snapshot.networkAccess, true, "Permission monitor should parse top-level turn_context network metadata.")
    expect(
        !snapshot.issues.contains("No trusted workspaces were found in Codex config."),
        "Missing trusted workspaces should not be reported as a problem by itself."
    )
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

private func testPermissionPresetWriterUpdatesCodexConfig() throws {
    let temp = try temporaryDirectory()
    let codex = temp.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let configURL = codex.appendingPathComponent("config.toml")
    try """
    model = "gpt-5"

    [projects."/tmp/project"]
    trust_level = "trusted"
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let writer = CodexPermissionConfigWriter(configURL: configURL)
    let lockedResult = try writer.applyPreset(.lockedDown)
    let lockedText = try String(contentsOf: configURL, encoding: .utf8)

    expectEqual(lockedResult.applied.approvalPolicy, "untrusted", "Locked Down should map to untrusted approval.")
    expectEqual(lockedResult.applied.sandboxMode, "read-only", "Locked Down should map to read-only sandbox.")
    expect(lockedResult.backupURL != nil, "Applying to an existing config should create a backup.")
    expect(lockedText.contains(#"approval_policy = "untrusted""#), "Config should contain locked down approval policy.")
    expect(lockedText.contains(#"sandbox_mode = "read-only""#), "Config should contain locked down sandbox mode.")
    expect(lockedText.contains("[sandbox_workspace_write]"), "Config should include workspace-write network table.")
    expect(lockedText.contains("network_access = false"), "Locked Down should disable workspace-write network access.")
    expect(lockedText.contains(#"[projects."/tmp/project"]"#), "Config writer should preserve project trust sections.")

    _ = try writer.applyPreset(.automation)
    let automationText = try String(contentsOf: configURL, encoding: .utf8)
    expectEqual(countOccurrences(of: "approval_policy", in: automationText), 1, "Config writer should update approval policy in place.")
    expectEqual(countOccurrences(of: "sandbox_mode", in: automationText), 1, "Config writer should update sandbox mode in place.")
    expect(automationText.contains(#"approval_policy = "never""#), "Automation should set never approval policy.")
    expect(automationText.contains(#"sandbox_mode = "workspace-write""#), "Automation should set workspace-write sandbox mode.")
    expect(automationText.contains("network_access = true"), "Automation should enable workspace-write network access.")
}

private func testPermissionConfigWriterRejectsBackupSymlink() throws {
    let temp = try temporaryDirectory()
    let codex = temp.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let configURL = codex.appendingPathComponent("config.toml")
    let backupURL = codex.appendingPathComponent("config.toml.todex-backup")
    let targetURL = temp.appendingPathComponent("backup-target.txt")
    try "model = \"gpt-5\"\n".write(to: configURL, atomically: true, encoding: .utf8)
    try "do not overwrite".write(to: targetURL, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: backupURL, withDestinationURL: targetURL)

    let writer = CodexPermissionConfigWriter(configURL: configURL)
    expectThrows("Config writer should reject a symlinked backup destination.") {
        _ = try writer.applyPreset(.lockedDown)
    }

    let configText = try String(contentsOf: configURL, encoding: .utf8)
    let targetText = try String(contentsOf: targetURL, encoding: .utf8)
    expectEqual(configText, "model = \"gpt-5\"\n", "Config writer should not modify config when backup destination is unsafe.")
    expectEqual(targetText, "do not overwrite", "Config writer should not write through a symlinked backup target.")
}

private func testPermissionConfigWriterRejectsHardlinkedConfig() throws {
    let temp = try temporaryDirectory()
    let codex = temp.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let realConfig = temp.appendingPathComponent("real-config.toml")
    let configURL = codex.appendingPathComponent("config.toml")
    try "model = \"gpt-5\"\n".write(to: realConfig, atomically: true, encoding: .utf8)
    do {
        try FileManager.default.linkItem(at: realConfig, to: configURL)
    } catch {
        return
    }

    let writer = CodexPermissionConfigWriter(configURL: configURL)
    expectThrows("Config writer should reject hardlinked config files.") {
        _ = try writer.applyPreset(.lockedDown)
    }

    let realText = try String(contentsOf: realConfig, encoding: .utf8)
    let configText = try String(contentsOf: configURL, encoding: .utf8)
    expectEqual(realText, "model = \"gpt-5\"\n", "Config writer should not modify a hardlinked config target.")
    expectEqual(configText, "model = \"gpt-5\"\n", "Config writer should leave hardlinked config content unchanged.")
}

private func countOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

private func testStoreAggregatesSessionAndTotalStatistics() throws {
    let temp = try temporaryDirectory()
    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    try store.resetAll(sessionStartedAt: Date(timeIntervalSince1970: 1_000))

    let old = sample(id: "old", timestamp: Date(timeIntervalSince1970: 900), input: 10, output: 5)
    let current = sample(id: "current", timestamp: Date(timeIntervalSince1970: 1_100), input: 100, cachedInput: 40, output: 50)
    try store.add([old, current])

    let stats = store.statistics(activeSourcePath: "/tmp/events.jsonl", issues: [])

    expectEqual(stats.currentSessionPrompts, 1, "Session prompt count should use session start.")
    expectEqual(stats.totalPrompts, 2, "Total prompt count should include all samples.")
    expectEqual(stats.sessionTokens, 150, "Session token count should include current sample only.")
    expectEqual(stats.totalTokens, 165, "Total token count should include all samples.")
    expectEqual(stats.inputTokens, 100, "Session input token count should include current sample only.")
    expectEqual(stats.cachedInputTokens, 40, "Session cached input token count should include current sample only.")
    expectEqual(stats.outputTokens, 50, "Session output token count should include current sample only.")
    expectEqual(stats.peakPromptCost, 150, "Peak request tokens should match current sample.")
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
    expect(
        stats.recentDailyUsage.count >= calendar.component(.day, from: now),
        "Recent daily usage should cover the current month for calendar rendering."
    )
}

private func testStoreDecodesLegacySamplesWithoutCachedInputTokens() throws {
    let temp = try temporaryDirectory()
    let url = temp.appendingPathComponent("stats.json")
    let text = """
    {
      "sessionStartedAt": "2026-06-23T09:00:00Z",
      "samples": [
        {
          "id": "legacy",
          "timestamp": "2026-06-23T10:00:00Z",
          "inputTokens": 100,
          "outputTokens": 25,
          "totalTokens": 125,
          "mode": "real",
          "sourceID": "source",
          "sourcePath": "/tmp/source.jsonl"
        }
      ],
      "seenSampleIDs": ["legacy"],
      "hasExplicitSessionReset": true
    }
    """
    try text.write(to: url, atomically: true, encoding: .utf8)

    let store = TokenUsageStore(stateURL: url)
    let stats = store.statistics(activeSourcePath: nil, issues: [], now: ISO8601DateFormatter().date(from: "2026-06-23T12:00:00Z")!)

    expectEqual(store.state.samples.first?.cachedInputTokens, 0, "Legacy samples should decode missing cached input tokens as zero.")
    expectEqual(stats.cachedInputTokens, 0, "Legacy decoded statistics should default cached input tokens to zero.")
    expectEqual(stats.todayUsage.totalTokens, 125, "Legacy decoded samples should still contribute to daily usage.")
}

private func testPrimaryDisplayUsageUsesTodayScope() throws {
    let temp = try temporaryDirectory()
    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    let calendar = Calendar.current
    let todayStart = calendar.startOfDay(for: Date())
    let today = calendar.date(byAdding: .hour, value: 2, to: todayStart) ?? Date()
    let activePath = "/tmp/.codex/sessions/active.jsonl"
    let otherPath = "/tmp/.codex/sessions/other.jsonl"

    try store.resetAll(sessionStartedAt: todayStart)
    try store.add([
        sample(id: "active", timestamp: today, input: 100, output: 50, sourcePath: activePath),
        sample(id: "other", timestamp: today.addingTimeInterval(60), input: 20, output: 5, sourcePath: otherPath)
    ])

    let stats = store.statistics(activeSourcePath: activePath, issues: [], now: today)

    expectEqual(stats.sessionTokens, 150, "Session tokens should remain scoped to the active Codex source.")
    expectEqual(stats.todayUsage.totalTokens, 175, "Today usage should include all today's Codex sources.")
    expectEqual(stats.primaryDisplayUsage.totalTokens, stats.todayUsage.totalTokens, "Primary UI usage should use Today scope.")
    expectEqual(stats.primaryDisplayUsage.requests, stats.todayUsage.requests, "Primary UI requests should use Today scope.")
}

private func testUIDisplayModelCoversHeaderMenuAndCalendarData() throws {
    let temp = try temporaryDirectory()
    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
    let todayStart = calendar.startOfDay(for: now)
    let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
    let activePath = "/tmp/.codex/sessions/active.jsonl"
    let otherPath = "/tmp/.codex/sessions/other.jsonl"

    try store.resetAll(sessionStartedAt: todayStart)
    try store.add([
        sample(id: "active", timestamp: todayStart.addingTimeInterval(3600), input: 100, output: 50, sourcePath: activePath),
        sample(id: "other", timestamp: todayStart.addingTimeInterval(7200), input: 20, output: 5, sourcePath: otherPath),
        sample(id: "yesterday", timestamp: yesterdayStart.addingTimeInterval(3600), input: 30, output: 10, sourcePath: otherPath)
    ])

    let stats = store.statistics(activeSourcePath: activePath, issues: [], now: now)
    let weekDisplay = TokenUsageUIDisplay(statistics: stats, calendarScope: .week, now: now, calendar: calendar)
    let monthDisplay = TokenUsageUIDisplay(statistics: stats, calendarScope: .month, now: now, calendar: calendar)

    expectEqual(weekDisplay.headerTitle, "TODAY", "Header title should state the primary UI scope.")
    expectEqual(weekDisplay.primaryTokenText, "175", "Header token text should use today's tokens.")
    expectEqual(weekDisplay.primaryRequestText, "2", "Header request text should use today's requests.")
    expectEqual(weekDisplay.primaryStatus, stats.primaryDisplayStatus, "Header status should use primary display status.")
    expectEqual(weekDisplay.statusBadgeText, "OK", "Header status badge should match primary display status.")
    expectEqual(weekDisplay.primaryAverageRequestText, "88", "Header average metric should use today's tokens divided by today's requests.")
    expectEqual(weekDisplay.last10PromptAverageText, "150", "Last 10 metric should use the active session average.")
    expectEqual(weekDisplay.monthlyCostText, "n/a", "Header cost metric should format missing cost data.")
    expectEqual(weekDisplay.tooltipText, "Today: 175 | Avg/req: 88 | OK", "Menu bar tooltip should use the same Today scope.")

    expectEqual(
        weekDisplay.overviewLines,
        [
            "Status: OK · real",
            "Today tokens: 175 · 215 total",
            "Today requests: 2",
            "Today avg/request: 88",
            "Input tokens today: 120",
            "Output tokens today: 55",
            "Cached input tokens: 0",
            "Current session requests: 1",
            "Session avg/request: 150",
            "Last 10 request average: 150",
            "Peak request tokens: 150",
            "Note: requests can include context reloads and tool/model calls."
        ],
        "Overview should expose every UI data row from the shared display model."
    )

    expectEqual(weekDisplay.usageLogLines.count, 4, "Usage Log should expose exactly four period rows.")
    expectEqual(weekDisplay.usageLogLines[0], "Today: 175 tok · 2 req · in 120 / out 55", "Usage Log Today row should match primary Today data.")
    expectEqual(weekDisplay.usageLogLines[1], "Yesterday: 40 tok · 1 req · in 30 / out 10", "Usage Log Yesterday row should match yesterday data.")
    expect(!weekDisplay.usageLogLines.contains { $0.contains("Jun 22") || $0.contains("Daily History") }, "Usage Log should not include older zero rows.")

    expectEqual(weekDisplay.calendar.scope, .week, "Week calendar display should use week scope.")
    expectEqual(weekDisplay.calendar.subtitle, "215 week", "Week calendar subtitle should use week totals.")
    expectEqual(weekDisplay.calendar.days.count, 7, "Week calendar should render seven days.")
    let weekToday = weekDisplay.calendar.days.first { $0.isToday }
    expectEqual(weekToday?.totalTokens, 175, "Week calendar should mark today's token usage.")
    expectEqual(weekToday?.isPeakUsageDay, true, "Week calendar should mark the highest token day as the peak day.")

    expectEqual(monthDisplay.calendar.scope, .month, "Month calendar display should use month scope.")
    expectEqual(monthDisplay.calendar.subtitle, "215 month", "Month calendar subtitle should use month totals.")
    expectEqual(monthDisplay.calendar.days.count, 42, "Month calendar should render a stable six-week grid.")
    let monthToday = monthDisplay.calendar.days.first { $0.isToday }
    expectEqual(monthToday?.totalTokens, 175, "Month calendar should mark today's token usage.")
    expectEqual(monthToday?.isPeakUsageDay, true, "Month calendar should mark the highest token day as the peak day.")
    expect(monthDisplay.calendar.days.contains { !$0.isCurrentMonth }, "Month calendar should include leading or trailing non-month days for grid alignment.")
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

private func testPrivateFileIORejectsHardlinkDestination() throws {
    let temp = try temporaryDirectory()
    let realFile = temp.appendingPathComponent("real.json")
    let hardlink = temp.appendingPathComponent("stats.json")
    try Data("{}".utf8).write(to: realFile)
    do {
        try FileManager.default.linkItem(at: realFile, to: hardlink)
    } catch {
        return
    }

    expectThrows("Private file writer should reject hardlink destinations.") {
        try PrivateFileIO.writePrivateData(Data(#"{"changed":true}"#.utf8), to: hardlink)
    }
    let realContents = try String(contentsOf: realFile, encoding: .utf8)
    expectEqual(realContents, "{}", "Private file writer should not modify a hardlinked target.")
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

private func testReportPrivacyRedactsLocalPaths() throws {
    let temp = try temporaryDirectory()
    let reportURL = temp.appendingPathComponent("report.json")
    let privatePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions/2026/06/25/rollout-private.jsonl")
        .path
    var statistics = TokenUsageStatistics.empty
    statistics.activeSourcePath = privatePath
    statistics.issues = [
        .permissionDenied(privatePath),
        .sourceTruncated(privatePath, parsedSamples: 1, limit: 1),
        .unreadableSource(privatePath, "Could not read \(privatePath)")
    ]
    let report = TokenUsageReport(
        generatedAt: Date(timeIntervalSince1970: 1),
        sessionStartedAt: Date(timeIntervalSince1970: 0),
        statistics: statistics,
        numericSamples: [
            sample(
                id: "sample",
                timestamp: Date(timeIntervalSince1970: 1),
                input: 10,
                output: 2,
                sourcePath: privatePath
            )
        ]
    )

    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    try store.saveReportJSON(report, to: reportURL)
    let exported = try String(contentsOf: reportURL, encoding: .utf8)

    expect(!exported.contains(FileManager.default.homeDirectoryForCurrentUser.path), "Report export should not contain full private user paths.")
    expect(exported.contains("rollout-private.jsonl"), "Report export should keep a redacted source file hint.")
}

private let tests: [(String, () throws -> Void)] = [
    ("OpenAI usage JSON parsing", testParsesOpenAIStyleUsageJSON),
    ("OpenAI API HTTP error classification", testOpenAIUsageClientClassifiesHTTPFailures),
    ("Estimated cost cached input pricing", testCostEstimatorSeparatesCachedInputAndMultiplier),
    ("Estimated cost sample aggregation", testCostEstimatorAggregatesSamples),
    ("Codex token_count parsing", testCodexTokenCountUsesLastUsageOnly),
    ("Parser truncation warning", testParserWarnsWhenSampleLimitTruncatesSource),
    ("Parser same-shaped request preservation", testParserKeepsDistinctRequestsWithSameTimestampAndTokens),
    ("Codex session prompt skipping", testStreamingCodexSessionParserSkipsPromptLines),
    ("Codex invalid non-token line skipping", testStreamingCodexSessionParserSkipsInvalidNonTokenLines),
    ("Codex project metadata parsing", testCodexSessionParserAttachesProjectMetadata),
    ("Codex permission monitoring", testPermissionMonitorFlagsBroadPermissions),
    ("Codex permission metadata shapes", testPermissionMonitorParsesAlternateTurnContextShapes),
    ("Codex permission network and trust parsing", testPermissionMonitorParsesNetworkAndTrustedWorkspaceSafely),
    ("Codex permission top-level turn context parsing", testPermissionMonitorParsesTopLevelTurnContext),
    ("Permission presets", testPermissionPresetLevelsApplyExpectedRules),
    ("Permission config writer", testPermissionPresetWriterUpdatesCodexConfig),
    ("Permission config writer backup symlink refusal", testPermissionConfigWriterRejectsBackupSymlink),
    ("Permission config writer hardlink refusal", testPermissionConfigWriterRejectsHardlinkedConfig),
    ("Usage store aggregation", testStoreAggregatesSessionAndTotalStatistics),
    ("Usage store project enrichment", testStoreEnrichesExistingSampleProjectMetadata),
    ("Usage store daily history", testStorePersistsDailyHistoryAndProjectBreakdown),
    ("Primary display usage scope", testPrimaryDisplayUsageUsesTodayScope),
    ("UI display model coverage", testUIDisplayModelCoversHeaderMenuAndCalendarData),
    ("Legacy state migration", testStoreDecodesLegacyStateWithoutFingerprints),
    ("Legacy cached token migration", testStoreDecodesLegacySamplesWithoutCachedInputTokens),
    ("Source fingerprint persistence", testEnginePersistsSourceFingerprintsAcrossRestart),
    ("Incremental source cursor", testEngineUsesIncrementalCursorForAppendedSessionLog),
    ("Private file symlink refusal", testPrivateFileIORejectsSymlinkDestination),
    ("Private file hardlink refusal", testPrivateFileIORejectsHardlinkDestination),
    ("Oversized JSON refusal", testParserRefusesOversizedStructuredJSONFile),
    ("Report privacy redaction", testReportPrivacyRedactsLocalPaths)
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
