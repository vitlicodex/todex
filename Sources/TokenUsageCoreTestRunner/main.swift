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
    reasoning: Int = 0,
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
        reasoningTokens: reasoning,
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
    return openAIStatsForMockedProvider(costsEnabled: false) { _ in response }
}

private func openAIStatsForMockedProvider(
    costsEnabled: Bool = false,
    configure: ((inout MonitorSettings) -> Void)? = nil,
    provider: @escaping (URLRequest) -> MockOpenAIResponse
) -> TokenUsageStatistics {
    MockOpenAIURLProtocol.responseProvider = provider
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockOpenAIURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = OpenAIUsageClient(
        session: session,
        baseURL: URL(string: "https://api.openai.test/v1")!
    )
    var settings = MonitorSettings()
    settings.featureFlags[.costsEndpoint] = costsEnabled
    configure?(&settings)
    let testSettings = settings
    return waitForAsync {
        await client.fetchStatistics(
            apiKey: "test-key-not-real",
            settings: testSettings,
            now: Date(timeIntervalSince1970: 1_783_324_800)
        )
    }
}

private func queryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }
    return components.queryItems?.first { $0.name == name }?.value
}

private func usagePageJSON(
    startTime: Int = 1_783_324_800,
    input: Int,
    cached: Int = 0,
    output: Int,
    requests: Int,
    nextPage: String? = nil,
    hasMore: Bool? = nil
) -> String {
    let next = nextPage.map { #","next_page":"\#($0)""# } ?? ""
    let more = hasMore.map { #","has_more":\#($0 ? "true" : "false")"# } ?? ""
    return """
    {"data":[{"start_time":\(startTime),"results":[{"input_tokens":\(input),"input_cached_tokens":\(cached),"output_tokens":\(output),"num_model_requests":\(requests)}]}]\(next)\(more)}
    """
}

private func costsPageJSON(
    startTime: Int = 1_783_324_800,
    value: Double,
    nextPage: String? = nil,
    hasMore: Bool? = nil
) -> String {
    let next = nextPage.map { #","next_page":"\#($0)""# } ?? ""
    let more = hasMore.map { #","has_more":\#($0 ? "true" : "false")"# } ?? ""
    return """
    {"data":[{"start_time":\(startTime),"results":[{"amount":{"value":\(value),"currency":"usd"}}]}]\(next)\(more)}
    """
}

private func emptyPageJSON() -> String {
    #"{"data":[]}"#
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

private func testOpenAIRedirectPolicyPinsHTTPSHostAndPort() {
    let original = URL(string: "https://api.openai.test/v1/organization/usage/completions")!

    expect(
        OpenAIRedirectPolicy.allowsRedirect(
            from: original,
            to: URL(string: "https://api.openai.test/v1/organization/usage/completions?page=next")!
        ),
        "OpenAI redirect policy should allow HTTPS redirects on the same host."
    )
    expect(
        !OpenAIRedirectPolicy.allowsRedirect(
            from: original,
            to: URL(string: "https://evil.example/v1/organization/usage/completions")!
        ),
        "OpenAI redirect policy should block cross-host redirects before Authorization can leave the API host."
    )
    expect(
        !OpenAIRedirectPolicy.allowsRedirect(
            from: original,
            to: URL(string: "http://api.openai.test/v1/organization/usage/completions")!
        ),
        "OpenAI redirect policy should block HTTPS downgrade redirects."
    )
    expect(
        !OpenAIRedirectPolicy.allowsRedirect(
            from: original,
            to: URL(string: "https://api.openai.test:8443/v1/organization/usage/completions")!
        ),
        "OpenAI redirect policy should block redirects to a different port."
    )
}

private func testOpenAIUsagePaginationSumsMultiplePages() {
    let stats = openAIStatsForMockedProvider { request in
        let page = queryValue("page", in: request)
        if page == "usage-page-2" {
            return .http(
                status: 200,
                body: usagePageJSON(input: 300, cached: 20, output: 40, requests: 2)
            )
        }
        return .http(
            status: 200,
            body: usagePageJSON(input: 100, cached: 10, output: 20, requests: 1, nextPage: "usage-page-2", hasMore: true)
        )
    }

    expectEqual(stats.inputTokens, 400, "Usage pagination should sum input tokens across pages.")
    expectEqual(stats.outputTokens, 60, "Usage pagination should sum output tokens across pages.")
    expectEqual(stats.cachedInputTokens, 30, "Usage pagination should sum cached input tokens across pages.")
    expectEqual(stats.requestCount, 3, "Usage pagination should sum request counts across pages.")
    expectEqual(stats.totalTokens, 460, "Usage pagination should sum total usage across pages.")
    expect(stats.issues.isEmpty, "Successful usage pagination should not produce issues.")
}

private func testOpenAICostsPaginationSumsMultiplePagesSeparatelyFromUsage() {
    let stats = openAIStatsForMockedProvider(costsEnabled: true) { request in
        guard let path = request.url?.path else {
            return .error(URLError(.badURL))
        }
        if path.contains("/organization/costs") {
            if queryValue("page", in: request) == "cost-page-2" {
                return .http(status: 200, body: costsPageJSON(value: 7.25))
            }
            return .http(status: 200, body: costsPageJSON(value: 5.25, nextPage: "cost-page-2", hasMore: true))
        }
        return .http(status: 200, body: emptyPageJSON())
    }

    expectEqual(stats.totalTokens, 0, "Empty Usage API pages should not invent token usage.")
    expectApprox(stats.dailyCostUSD ?? -1, 12.5, "Costs pagination should sum actual daily cost across pages.")
    expectApprox(stats.monthlyCostUSD ?? -1, 12.5, "Costs pagination should sum actual monthly cost across pages.")
    expect(stats.estimatedLocalDailyCostUSD == nil, "Actual Costs API pagination must not populate estimated local Codex cost.")
    expect(stats.issues.isEmpty, "Successful Costs API pagination should not produce issues.")
}

private func testOpenAIUsagePaginationKeepsPartialDataWhenLaterPageFails() {
    let stats = openAIStatsForMockedProvider { request in
        if queryValue("page", in: request) == "broken" {
            return .http(status: 503, body: #"{"error":"temporary"}"#)
        }
        return .http(
            status: 200,
            body: usagePageJSON(input: 120, output: 30, requests: 1, nextPage: "broken", hasMore: true)
        )
    }

    expectEqual(stats.totalTokens, 150, "Pagination should preserve already-read usage when a later page fails.")
    expect(stats.issues.contains(.apiServerError(503)), "Later page failures should be surfaced as warning issues.")
    expectEqual(stats.status, .warning, "Partial pagination failure should downgrade status to warning.")
}

private func testOpenAIUsagePaginationDetectsDuplicateCursor() {
    let stats = openAIStatsForMockedProvider { request in
        if queryValue("page", in: request) == "same" {
            return .http(
                status: 200,
                body: usagePageJSON(input: 20, output: 2, requests: 1, nextPage: "same", hasMore: true)
            )
        }
        return .http(
            status: 200,
            body: usagePageJSON(input: 10, output: 1, requests: 1, nextPage: "same", hasMore: true)
        )
    }

    expectEqual(stats.totalTokens, 33, "Duplicate cursor guard should keep pages already fetched before stopping.")
    expect(
        stats.issues.contains(.apiResponseInvalid("Duplicate pagination cursor was ignored.")),
        "Duplicate pagination cursors should produce an explicit issue."
    )
    expectEqual(stats.status, .warning, "Duplicate pagination cursor should downgrade status to warning.")
}

private func testOpenAIUsagePaginationDetectsMalformedCursor() {
    let stats = openAIStatsForMockedProvider { _ in
        .http(
            status: 200,
            body: #"{"data":[{"start_time":1783324800,"results":[{"input_tokens":10,"output_tokens":2,"num_model_requests":1}]}],"has_more":true,"next_page":{"bad":true}}"#
        )
    }

    expectEqual(stats.totalTokens, 12, "Malformed cursor handling should preserve current page data.")
    expect(
        stats.issues.contains(.apiResponseInvalid("Pagination indicated more pages but no valid cursor was provided.")),
        "Malformed pagination cursors should produce an explicit issue."
    )
}

private func testOpenAIUsagePaginationHasMaxPageGuard() {
    let stats = openAIStatsForMockedProvider { request in
        let current = Int(queryValue("page", in: request) ?? "0") ?? 0
        return .http(
            status: 200,
            body: usagePageJSON(input: 1, output: 0, requests: 1, nextPage: "\(current + 1)", hasMore: true)
        )
    }

    expectEqual(stats.totalTokens, 20, "Pagination max-page guard should keep the bounded set of fetched pages.")
    expect(
        stats.issues.contains(.apiResponseInvalid("Pagination page limit exceeded after 20 pages.")),
        "Pagination should report when the max page guard stops a response stream."
    )
}

private func testOpenAIUsageAndCostsPartialFailuresAreIndependent() {
    let usageSucceededCostsFailed = openAIStatsForMockedProvider(costsEnabled: true) { request in
        if request.url?.path.contains("/organization/costs") == true {
            return .http(status: 500, body: #"{"error":"costs unavailable"}"#)
        }
        return .http(status: 200, body: usagePageJSON(input: 100, output: 10, requests: 1))
    }

    expectEqual(usageSucceededCostsFailed.totalTokens, 110, "Usage data should remain visible when Costs API fails.")
    expect(usageSucceededCostsFailed.monthlyCostUSD == nil, "Failed Costs API should not invent actual cost.")
    expect(usageSucceededCostsFailed.issues.contains(.apiServerError(500)), "Costs API failure should stay visible.")

    let usageFailedCostsSucceeded = openAIStatsForMockedProvider(costsEnabled: true) { request in
        if request.url?.path.contains("/organization/costs") == true {
            return .http(status: 200, body: costsPageJSON(value: 9.5))
        }
        return .http(status: 500, body: #"{"error":"usage unavailable"}"#)
    }

    expectEqual(usageFailedCostsSucceeded.totalTokens, 0, "Failed Usage API should not invent usage tokens.")
    expectApprox(usageFailedCostsSucceeded.monthlyCostUSD ?? -1, 9.5, "Costs data should remain visible when Usage API fails.")
    expect(usageFailedCostsSucceeded.issues.contains(.apiServerError(500)), "Usage API failure should stay visible.")
}

private func testOpenAIErrorBodySanitizesSecrets() {
    let stats = openAIStatsForMockedResponse(
        .http(
            status: 400,
            body: #"{"error":"bad key sk-THIS_IS_FAKE_SECRET_VALUE authorization: Bearer FAKE_TOKEN"}"#
        )
    )
    let text = stats.issues.map(\.message).joined(separator: "\n")

    expect(!text.contains("sk-THIS_IS_FAKE_SECRET_VALUE"), "Sanitized API errors should not expose key-shaped text.")
    expect(!text.contains("FAKE_TOKEN"), "Sanitized API errors should not expose bearer tokens.")
    expect(text.contains("[REDACTED]"), "Sanitized API errors should retain useful redaction evidence.")
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
    expect(estimate.isEstimated, "Local token cost estimates should be explicitly marked estimated.")
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

private func testCostEstimatorAggregatesSampleReasoningTokens() {
    let profile = TokenPricingProfile(
        name: "Reasoning",
        inputPerMillionUSD: 0,
        cachedInputPerMillionUSD: 0,
        outputPerMillionUSD: 0,
        reasoningPerMillionUSD: 10
    )
    let estimate = CostEstimator.estimate(
        samples: [
            sample(id: "reasoning-a", timestamp: Date(timeIntervalSince1970: 1), input: 10, output: 1, reasoning: 100_000),
            sample(id: "reasoning-b", timestamp: Date(timeIntervalSince1970: 2), input: 10, output: 1, reasoning: 50_000)
        ],
        profile: profile
    )

    expectApprox(estimate.reasoningCostUSD, 1.5, "Estimator should aggregate reasoning tokens stored on samples.")
    expectApprox(estimate.totalCostUSD, 1.5, "Estimator should include sample reasoning tokens in total estimated local cost.")
}

private func testPricingProfileDecodesLegacyProfileWithoutID() throws {
    let data = """
    {
      "name": "Legacy",
      "inputPerMillionUSD": 3,
      "cachedInputPerMillionUSD": 0.3,
      "outputPerMillionUSD": 9
    }
    """.data(using: .utf8)!

    let profile = try JSONDecoder().decode(TokenPricingProfile.self, from: data)

    expectEqual(profile.name, "Legacy", "Legacy pricing profile should preserve name.")
    expect(!profile.id.isEmpty, "Legacy pricing profile should synthesize a stable id.")
    expectEqual(profile.reasoningPerMillionUSD, 0, "Legacy pricing profile should default missing reasoning price.")
    expectEqual(profile.multiplier, 1, "Legacy pricing profile should default missing multiplier.")
    expect(profile.notes == nil, "Legacy pricing profile should allow missing notes.")
}

private func testPricingProfileValidationRejectsUnsafeValues() {
    let profile = TokenPricingProfile(
        id: "bad",
        name: "  ",
        inputPerMillionUSD: -1,
        cachedInputPerMillionUSD: -0.1,
        outputPerMillionUSD: -2,
        reasoningPerMillionUSD: -3,
        multiplier: 0
    )

    expectEqual(
        profile.validationIssues,
        [
            .emptyName,
            .negativeInputPrice,
            .negativeCachedInputPrice,
            .negativeOutputPrice,
            .negativeReasoningPrice,
            .nonPositiveMultiplier
        ],
        "Pricing profile validation should reject empty names, negative prices, and non-positive multipliers."
    )
    expectThrows("Invalid pricing profiles should throw before they are persisted.") {
        _ = try profile.validated()
    }
}

private func testPricingProfilePersistenceAndReset() throws {
    let temp = try temporaryDirectory()
    let store = MonitorSettingsStore(settingsURL: temp.appendingPathComponent("settings.json"))
    var settings = MonitorSettings()
    let custom = TokenPricingProfile(
        id: "custom-pricing",
        name: "Custom Pricing",
        inputPerMillionUSD: 2,
        cachedInputPerMillionUSD: 0.2,
        outputPerMillionUSD: 8,
        reasoningPerMillionUSD: 1,
        multiplier: 1.5,
        notes: "Local estimate only."
    )

    try settings.applyPricingProfile(custom)
    try store.save(settings)
    let loaded = store.load()

    expectEqual(loaded.localPricingProfile, custom, "Settings store should persist the selected pricing profile.")
    var reset = loaded
    reset.resetPricingProfile(to: "local-priority")
    expectEqual(reset.localPricingProfile.id, "local-priority", "Settings should reset to a known default pricing profile.")
    reset.resetPricingProfile(to: "missing")
    expectEqual(reset.localPricingProfile.id, TokenPricingProfile.defaultLocalEstimate.id, "Unknown reset profile should fall back to the default local estimate.")
}

private func testPricingProfileChangeRecalculatesEstimatedLocalCost() throws {
    let temp = try temporaryDirectory()
    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    let now = Date(timeIntervalSince1970: 1_783_324_800)
    try store.resetAll(sessionStartedAt: now.addingTimeInterval(-10))
    try store.add([
        sample(id: "pricing-recalc", timestamp: now, input: 1_000_000, cachedInput: 200_000, output: 100_000)
    ])

    let low = TokenPricingProfile(
        id: "low",
        name: "Low",
        inputPerMillionUSD: 1,
        cachedInputPerMillionUSD: 0.1,
        outputPerMillionUSD: 2
    )
    let high = TokenPricingProfile(
        id: "high",
        name: "High",
        inputPerMillionUSD: 10,
        cachedInputPerMillionUSD: 1,
        outputPerMillionUSD: 20
    )

    let lowStats = store.statistics(activeSourcePath: nil, issues: [], now: now, pricingProfile: low)
    let highStats = store.statistics(activeSourcePath: nil, issues: [], now: now, pricingProfile: high)

    expectApprox(lowStats.estimatedLocalDailyCostUSD ?? -1, 1.02, "Low pricing profile should calculate estimated local cost.")
    expectApprox(highStats.estimatedLocalDailyCostUSD ?? -1, 10.2, "Changing pricing profile should recalculate estimated local cost.")
    expectEqual(highStats.estimatedLocalPricingProfileName, "High", "Statistics should expose the selected pricing profile name.")
    expect(highStats.dailyCostUSD == nil, "Estimated local cost recalculation must not populate actual OpenAI API cost.")
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

private func testCodexTokenCountPreservesReportedAndReasoningTokens() {
    let parser = TokenUsageParser()
    let url = URL(fileURLWithPath: "/tmp/codex-session.jsonl")
    let data = """
    {"timestamp":"2026-06-23T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30,"reasoning_tokens":45,"total_tokens":210}}}}
    """.data(using: .utf8)!

    let result = parser.parse(data: data, sourceURL: url, fallbackDate: Date(timeIntervalSince1970: 0))

    expect(result.issues.isEmpty, "Codex token_count with reported total should parse without issues.")
    expectEqual(result.samples.count, 1, "Codex token_count with reported total should produce one sample.")
    guard let sample = result.samples.first else { return }
    expectEqual(sample.inputTokens, 120, "Parser should preserve input tokens.")
    expectEqual(sample.cachedInputTokens, 20, "Parser should preserve cached input tokens.")
    expectEqual(sample.outputTokens, 30, "Parser should preserve output tokens.")
    expectEqual(sample.reasoningTokens, 45, "Parser should preserve reasoning tokens when present.")
    expectEqual(sample.reportedTotalTokens, 210, "Parser should preserve explicit reported total tokens.")
    expectEqual(sample.computedInputOutputTokens, 150, "Computed input/output total should stay separate from reported total.")
    expectEqual(sample.computedInputOutputReasoningTokens, 195, "Computed input/output/reasoning total should be available separately.")
    expectEqual(sample.totalTokens, 210, "Existing totalTokens should keep the reported total for compatibility.")
    expect(sample.totalDiffersFromInputOutput, "Reported total should be allowed to differ from input plus output.")
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
    try """
    [projects."/tmp/broad"]
    trust_level = "trusted"
    """.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

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
    trust_level = "trusted"

    [tools]
    trust_level = "trusted"

    [projects."/tmp/one"]
    trust_level = 'trusted'

    [projects."/tmp/two"]
    trust_level = "untrusted"
    """.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let url = sessions.appendingPathComponent("rollout.jsonl")
    try """
    {"timestamp":"2026-06-23T10:00:00.000Z","type": "event_msg","payload": {"type": "turn_context","approval_policy":"on-request","sandbox_policy":"workspace-write","permission_profile":{"type":"standard","network":"disabled"}}}
    """.write(to: url, atomically: true, encoding: .utf8)

    let snapshot = CodexPermissionMonitor(homeDirectory: temp).snapshot()

    expectEqual(snapshot.networkAccess, false, "Disabled permission_profile network should not be treated as enabled.")
    expectEqual(snapshot.trustedWorkspaceCount, 1, "Trusted workspace parser should only count trusted project tables.")
    expect(
        !snapshot.issues.contains("No trusted workspaces were found in Codex config."),
        "Trusted workspace absence/presence should not produce a misleading warning issue."
    )
}

private func testPermissionMonitorParsesSandboxPolicyNetworkStrings() throws {
    func snapshot(for networkValue: String) throws -> CodexPermissionSnapshot {
        let temp = try temporaryDirectory()
        let sessions = temp
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let url = sessions.appendingPathComponent("rollout.jsonl")
        try """
        {"timestamp":"2026-06-23T10:00:00.000Z","type":"turn_context","payload":{"approval_policy":"on-request","sandbox_policy":{"type":"workspace-write","network_access":"\(networkValue)"},"permission_profile":{"type":"standard"}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        return CodexPermissionMonitor(homeDirectory: temp).snapshot()
    }

    let restricted = try snapshot(for: "restricted")
    expectEqual(
        restricted.networkAccess,
        false,
        "Restricted sandbox_policy network access should not be treated as enabled."
    )

    let disabled = try snapshot(for: "disabled")
    expectEqual(
        disabled.networkAccess,
        false,
        "Disabled sandbox_policy network access should not be treated as enabled."
    )

    let enabled = try snapshot(for: "enabled")
    expectEqual(
        enabled.networkAccess,
        true,
        "Enabled sandbox_policy network access should be treated as enabled."
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

private func testStoreComputesEstimatedLocalCostsSeparatelyFromActualAPICosts() throws {
    let temp = try temporaryDirectory()
    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
    let todayStart = calendar.startOfDay(for: now)
    let today = todayStart.addingTimeInterval(3600)
    let profile = TokenPricingProfile(
        id: "test-cost",
        name: "Test Cost",
        inputPerMillionUSD: 10,
        cachedInputPerMillionUSD: 1,
        outputPerMillionUSD: 20,
        reasoningPerMillionUSD: 5
    )

    try store.resetAll(sessionStartedAt: todayStart)
    try store.add([
        sample(
            id: "cost-alpha",
            timestamp: today,
            input: 1_000_000,
            cachedInput: 100_000,
            output: 100_000,
            reasoning: 50_000,
            projectID: "project-alpha",
            projectName: "alpha"
        )
    ])

    let stats = store.statistics(
        activeSourcePath: nil,
        issues: [],
        now: now,
        pricingProfile: profile
    )

    expect(stats.dailyCostUSD == nil, "Local estimated cost must not populate actual OpenAI API daily cost.")
    expect(stats.monthlyCostUSD == nil, "Local estimated cost must not populate actual OpenAI API monthly cost.")
    expectApprox(stats.estimatedLocalDailyCostUSD ?? -1, 11.35, "Store should compute estimated local daily cost.")
    expectApprox(stats.estimatedLocalWeeklyCostUSD ?? -1, 11.35, "Store should compute estimated local weekly cost.")
    expectApprox(stats.estimatedLocalMonthlyCostUSD ?? -1, 11.35, "Store should compute estimated local monthly cost.")
    expectApprox(stats.estimatedLocalTotalCostUSD ?? -1, 11.35, "Store should compute estimated local total cost.")
    expectEqual(stats.estimatedLocalPricingProfileName, "Test Cost", "Store should expose the estimated local pricing profile name.")
    expectApprox(
        stats.projectBreakdown.first?.estimatedLocalCostUSD ?? -1,
        11.35,
        "Project breakdown should carry estimated local cost separately from actual API cost."
    )
    expect(stats.projectBreakdown.first?.costUSD == nil, "Project estimated local cost must not populate actual API cost.")
}

private func contextSamples(
    prefix: String,
    baselineCount: Int,
    recentCount: Int,
    baselineInput: Int,
    recentInput: Int,
    output: Int,
    cachedInput: Int = 0,
    projectID: String? = nil,
    projectName: String? = nil,
    start: Date = Date(timeIntervalSince1970: 1_783_324_800)
) -> [TokenUsageSample] {
    var outputSamples: [TokenUsageSample] = []
    for index in 0..<(baselineCount + recentCount) {
        let isRecent = index >= baselineCount
        let input = isRecent ? recentInput : baselineInput
        outputSamples.append(
            sample(
                id: "\(prefix)-\(index)",
                timestamp: start.addingTimeInterval(TimeInterval(index * 60)),
                input: input,
                cachedInput: isRecent ? cachedInput : 0,
                output: output,
                sourcePath: "/tmp/private-\(prefix).jsonl",
                projectID: projectID,
                projectName: projectName
            )
        )
    }
    return outputSamples
}

private func testContextExplosionDetectorIgnoresNormalUsage() {
    let samples = contextSamples(
        prefix: "normal",
        baselineCount: 10,
        recentCount: 5,
        baselineInput: 8_000,
        recentInput: 9_000,
        output: 2_000
    )

    let findings = ContextExplosionDetector().detect(samples: samples)

    expect(findings.isEmpty, "Normal context usage should not produce context explosion findings.")
}

private func testContextExplosionDetectorFindsRecentInputSpike() {
    let samples = contextSamples(
        prefix: "spike",
        baselineCount: 10,
        recentCount: 5,
        baselineInput: 10_000,
        recentInput: 120_000,
        output: 500
    )

    let findings = ContextExplosionDetector().detect(samples: samples)

    expectEqual(findings.count, 1, "Recent input spike should produce one context explosion finding.")
    guard let finding = findings.first else { return }
    expectEqual(finding.severity, .critical, "Huge uncached input spike should be critical.")
    expectEqual(finding.confidence, .high, "Solid baseline plus recent large input spike should be high confidence.")
    expectEqual(Int(finding.baselineInputPerRequest), 10_000, "Finding should preserve baseline input/request.")
    expectEqual(Int(finding.recentInputPerRequest), 120_000, "Finding should preserve recent input/request.")
    expect(finding.inputShare > 0.95, "Finding should expose input dominance.")
    expect(finding.triggeredBy.contains("recent input/request spike"), "Finding should explain why it triggered.")
    expect(finding.evidenceMetrics["relativeMultiplier"] ?? 0 >= 12, "Finding should expose numeric evidence metrics.")
    expect(finding.evidence.contains { $0.contains("recent input/request") }, "Finding should include numeric spike evidence.")
}

private func testContextExplosionDetectorCachedInputLowersSeverity() {
    let samples = contextSamples(
        prefix: "cached",
        baselineCount: 10,
        recentCount: 5,
        baselineInput: 10_000,
        recentInput: 120_000,
        output: 500,
        cachedInput: 60_000
    )

    let findings = ContextExplosionDetector().detect(samples: samples)

    expectEqual(findings.first?.severity, .warning, "Large context with meaningful cached input should be warning instead of critical.")
    expect((findings.first?.cachedInputShare ?? 0) >= 0.25, "Finding should expose cached input share.")
    expectEqual(findings.first?.confidence, .medium, "High cached input should lower confidence from high to medium.")
}

private func testContextExplosionDetectorIgnoresStableHeavyUsage() {
    let samples = contextSamples(
        prefix: "stable-heavy",
        baselineCount: 12,
        recentCount: 5,
        baselineInput: 120_000,
        recentInput: 125_000,
        output: 55_000
    )

    let findings = ContextExplosionDetector().detect(samples: samples)

    expect(findings.isEmpty, "Stable heavy sessions with meaningful output should not be flagged as context explosions.")
}

private func testContextExplosionDetectorIgnoresLowSampleCount() {
    let samples = contextSamples(
        prefix: "low-sample",
        baselineCount: 1,
        recentCount: 5,
        baselineInput: 1_000,
        recentInput: 500_000,
        output: 100
    )

    let findings = ContextExplosionDetector().detect(samples: samples)

    expect(findings.isEmpty, "Low sample count should not produce high-confidence context alerts.")
}

private func testContextExplosionDetectorUsesSettingsThresholds() {
    var settings = MonitorSettings()
    settings.contextExplosion = ContextExplosionSettings(
        recentWindowCount: 3,
        minimumBaselineCount: 3,
        minimumRequestCount: 6,
        minimumRecentTotalTokens: 30_000,
        relativeSpikeMultiplier: 2,
        relativeSpikeMinimumInput: 10_000,
        absoluteLargeInputThreshold: 20_000,
        inputDominanceShare: 0.90,
        inputDominanceMinimumTokens: 30_000,
        cachedMissingInputThreshold: 1_000_000,
        repeatedLargeRequestCount: 6,
        highCachedInputShare: 0.50
    )
    let samples = contextSamples(
        prefix: "custom-settings",
        baselineCount: 3,
        recentCount: 3,
        baselineInput: 6_000,
        recentInput: 22_000,
        output: 500
    )

    let findings = ContextExplosionDetector().detect(samples: samples, settings: settings)

    expectEqual(findings.count, 1, "Custom context thresholds should make smaller spikes detectable.")
    expectEqual(findings.first?.requestCount, 3, "Custom recent window should control the finding window.")
    expect(findings.first?.triggeredBy.contains("recent input/request spike") == true, "Custom thresholds should be reflected in trigger explanations.")
}

private func testContextExplosionDetectorIsolatesExplodingProject() {
    let normal = contextSamples(
        prefix: "project-normal",
        baselineCount: 10,
        recentCount: 5,
        baselineInput: 8_000,
        recentInput: 8_500,
        output: 2_000,
        projectID: "project-normal",
        projectName: "normal"
    )
    let exploding = contextSamples(
        prefix: "project-exploding",
        baselineCount: 10,
        recentCount: 5,
        baselineInput: 10_000,
        recentInput: 140_000,
        output: 500,
        projectID: "project-exploding",
        projectName: "exploding"
    )

    let findings = ContextExplosionDetector().detect(samples: normal + exploding)

    expect(
        findings.contains { $0.projectID == "project-exploding" },
        "Detector should produce a project-level finding for the exploding project."
    )
    expect(
        !findings.contains { $0.projectID == "project-normal" },
        "Detector should not flag the normal project."
    )
}

private func testContextExplosionFindingEvidenceIsPrivacySafe() {
    let privatePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("SecretProject/session.jsonl")
        .path
    let samples = contextSamples(
        prefix: "privacy",
        baselineCount: 10,
        recentCount: 5,
        baselineInput: 10_000,
        recentInput: 150_000,
        output: 250,
        projectID: "project-private",
        projectName: "safe-label"
    ).map {
        TokenUsageSample(
            id: $0.id,
            timestamp: $0.timestamp,
            inputTokens: $0.inputTokens,
            cachedInputTokens: $0.cachedInputTokens,
            outputTokens: $0.outputTokens,
            totalTokens: $0.totalTokens,
            mode: $0.mode,
            sourceID: $0.sourceID,
            sourcePath: privatePath,
            projectID: $0.projectID,
            projectName: $0.projectName
        )
    }

    let evidence = ContextExplosionDetector()
        .detect(samples: samples)
        .flatMap(\.evidence)
        .joined(separator: "\n")

    expect(!evidence.contains(FileManager.default.homeDirectoryForCurrentUser.path), "Context finding evidence should not include full private paths.")
    expect(!evidence.contains("SecretProject"), "Context finding evidence should not include private path components.")
}

private func testSpendFirewallDetectsCriticalBurnRate() {
    let now = Date(timeIntervalSince1970: 1_783_324_800)
    let profile = TokenPricingProfile(
        id: "firewall",
        name: "Firewall",
        inputPerMillionUSD: 10,
        cachedInputPerMillionUSD: 1,
        outputPerMillionUSD: 20
    )
    let settings = MonitorSettings(
        localPricingProfile: profile,
        spendFirewall: SpendFirewallSettings(
            hourlyBurnWarningUSD: 25,
            hourlyBurnCriticalUSD: 50
        )
    )
    let samples = [
        sample(id: "burn", timestamp: now.addingTimeInterval(-60), input: 6_000_000, output: 10_000)
    ]

    let alerts = SpendFirewallEvaluator().evaluate(
        snapshot: .empty,
        samples: samples,
        settings: settings,
        now: now
    )

    let burn = alerts.first { $0.kind == .highBurnRate }
    expectEqual(burn?.severity, .critical, "High estimated hourly burn should produce a critical firewall alert.")
    expect(burn?.evidence.joined(separator: "\n").contains("estimated local cost/hour") == true, "Burn alert should include estimated local cost evidence.")
    expect(
        burn?.recommendedActionItems.contains { $0.kind == .openProjectSessionBreakdown } == true,
        "High burn rate should offer a project/session breakdown action."
    )
    expect(
        burn?.recommendedActionItems.contains { $0.kind == .copyReduceContextPrompt } == true,
        "High burn rate should offer a reduce-context prompt action."
    )
}

private func testSpendFirewallDetectsDailyBudgetRisk() {
    var snapshot = TokenUsageStatistics.empty
    snapshot.estimatedLocalDailyCostUSD = 82
    let settings = MonitorSettings(
        spendFirewall: SpendFirewallSettings(dailyEstimatedBudgetUSD: 100)
    )

    let alerts = SpendFirewallEvaluator().evaluate(
        snapshot: snapshot,
        settings: settings,
        now: Date(timeIntervalSince1970: 1_783_324_800)
    )

    let budget = alerts.first { $0.kind == .dailyBudgetRisk }
    expectEqual(budget?.severity, .warning, "Daily budget risk should warn before budget is fully exhausted.")
    expect(budget?.evidence.joined(separator: "\n").contains("82.0%") == true, "Budget alert should include percent-used evidence.")
}

private func testSpendFirewallCooldownSuppressesRepeatedAlerts() {
    let now = Date(timeIntervalSince1970: 1_783_324_800)
    var snapshot = TokenUsageStatistics.empty
    snapshot.estimatedLocalDailyCostUSD = 100
    let settings = MonitorSettings(
        spendFirewall: SpendFirewallSettings(dailyEstimatedBudgetUSD: 100, alertCooldownMinutes: 15)
    )
    let previous = SpendFirewallAlert(
        kind: .dailyBudgetRisk,
        severity: .critical,
        title: "Daily estimated budget risk",
        detail: "Previous",
        evidence: [],
        recommendedActions: [],
        createdAt: now.addingTimeInterval(-5 * 60)
    )

    let alerts = SpendFirewallEvaluator().evaluate(
        snapshot: snapshot,
        settings: settings,
        previousAlerts: [previous],
        now: now
    )

    expect(!alerts.contains { $0.kind == .dailyBudgetRisk }, "Firewall should suppress repeated alerts during cooldown.")
}

private func testSpendFirewallIncludesContextExplosionAlerts() {
    let finding = ContextExplosionFinding(
        severity: .critical,
        projectID: "project-alpha",
        projectName: "alpha",
        baselineInputPerRequest: 10_000,
        recentInputPerRequest: 150_000,
        inputShare: 0.99,
        cachedInputShare: 0,
        requestCount: 5,
        timeWindowDescription: "last 5 requests",
        likelyCauses: ["large workspace"],
        recommendedActions: ["restart Codex session"],
        evidence: ["recent input/request: 150000"]
    )

    let alerts = SpendFirewallEvaluator().evaluate(
        snapshot: .empty,
        contextFindings: [finding],
        now: Date(timeIntervalSince1970: 1_783_324_800)
    )

    let context = alerts.first { $0.kind == .contextExplosion }
    expectEqual(context?.severity, .critical, "Firewall should preserve context finding severity.")
    expectEqual(context?.projectID, "project-alpha", "Firewall should preserve safe project hash.")
    expect(context?.detail.contains("Confidence") == true, "Firewall context alert should expose detector confidence.")
    expect(context?.evidence.contains("confidence: medium") == true, "Firewall context alert evidence should include confidence.")
    expect(
        context?.recommendedActionItems.contains { $0.kind == .suggestRestartOrCompactContext } == true,
        "Context explosion alerts should offer a restart/compact-context suggestion action."
    )
}

private func testSpendFirewallFlagsPermissionRiskOverlap() {
    let permission = CodexPermissionSnapshot(
        monitoringEnabled: true,
        status: .warning,
        statusReason: "test",
        approvalPolicy: "never",
        networkAccess: true
    )

    let alerts = SpendFirewallEvaluator().evaluate(
        snapshot: .empty,
        permissionSnapshot: permission,
        now: Date(timeIntervalSince1970: 1_783_324_800)
    )

    expect(alerts.contains { $0.kind == .permissionRiskOverlap }, "Firewall should flag network plus no-approval permission overlap.")
}

private func testSpendFirewallEvidenceIsPrivacySafe() {
    let now = Date(timeIntervalSince1970: 1_783_324_800)
    let privatePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("PrivateProject/session.jsonl")
        .path
    let settings = MonitorSettings(
        localPricingProfile: TokenPricingProfile(
            id: "privacy-firewall",
            name: "Privacy Firewall",
            inputPerMillionUSD: 100,
            cachedInputPerMillionUSD: 0,
            outputPerMillionUSD: 0
        ),
        spendFirewall: SpendFirewallSettings(hourlyBurnWarningUSD: 1, hourlyBurnCriticalUSD: 2)
    )
    let samples = [
        sample(id: "privacy-burn", timestamp: now, input: 100_000, output: 0, sourcePath: privatePath)
    ]

    let alerts = SpendFirewallEvaluator()
        .evaluate(snapshot: .empty, samples: samples, settings: settings, now: now)
    let evidence = alerts
        .flatMap(\.evidence)
        .joined(separator: "\n")
    let actions = alerts
        .flatMap(\.recommendedActionItems)
        .map { "\($0.title)\n\($0.detail)\n\($0.clipboardText ?? "")" }
        .joined(separator: "\n")

    expect(!evidence.contains(FileManager.default.homeDirectoryForCurrentUser.path), "Firewall evidence should not include full private paths.")
    expect(!evidence.contains("PrivateProject"), "Firewall evidence should not include private path components.")
    expect(!actions.contains(FileManager.default.homeDirectoryForCurrentUser.path), "Firewall actions should not include full private paths.")
    expect(!actions.contains("PrivateProject"), "Firewall actions should not include private path components.")
    expect(!actions.localizedCaseInsensitiveContains("authorization:"), "Firewall actions should not include Authorization headers.")
    expect(!actions.localizedCaseInsensitiveContains("sk-"), "Firewall actions should not include API-key shaped text.")
}

private func testSpendFirewallSafeModeActionRequiresConfirmation() {
    let now = Date(timeIntervalSince1970: 1_783_324_800)
    var snapshot = TokenUsageStatistics.empty
    snapshot.estimatedLocalDailyCostUSD = 150
    let settings = MonitorSettings(
        spendFirewall: SpendFirewallSettings(dailyEstimatedBudgetUSD: 100)
    )

    let alert = SpendFirewallEvaluator()
        .evaluate(snapshot: snapshot, settings: settings, now: now)
        .first { $0.kind == .dailyBudgetRisk }
    let safeMode = alert?.recommendedActionItems.first { $0.kind == .applyCodexCLISafeMode }

    expectEqual(safeMode?.requiresConfirmation, true, "Codex CLI Safe Mode action should require explicit confirmation.")
    expectEqual(safeMode?.modifiesCodexConfig, true, "Codex CLI Safe Mode action should be marked as config-modifying.")
    expect(
        safeMode?.detail.contains("Codex Desktop may need restart") == true,
        "Codex CLI Safe Mode action should warn that Codex Desktop may need restart."
    )
}

private func testSpendFirewallRecommendationsDoNotIncludeAutomaticKillOrPause() {
    let allActionText = SpendFirewallActionCatalog.standard
        .map { "\($0.title)\n\($0.detail)" }
        .joined(separator: "\n")
        .lowercased()

    expect(!allActionText.contains("kill"), "Firewall actions should not offer automatic kill behavior.")
    expect(!allActionText.contains("pause codex"), "Firewall actions should not offer automatic pause behavior.")
    expect(!allActionText.contains("stop codex"), "Firewall actions should not offer automatic stop behavior.")
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
    expectEqual(store.state.samples.first?.reasoningTokens, 0, "Legacy samples should decode missing reasoning tokens as zero.")
    expect(store.state.samples.first?.reportedTotalTokens == nil, "Legacy samples should decode missing reported totals as nil.")
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

    expectEqual(weekDisplay.headerTitle, "CODEX TODAY", "Header title should state the primary UI scope and source.")
    expectEqual(weekDisplay.primaryTokenText, "175", "Header token text should use today's tokens.")
    expectEqual(weekDisplay.primaryRequestText, "2", "Header request text should use today's requests.")
    expectEqual(weekDisplay.primaryStatus, stats.primaryDisplayStatus, "Header status should use primary display status.")
    expectEqual(weekDisplay.statusBadgeText, "OK", "Header status badge should match primary display status.")
    expectEqual(weekDisplay.primaryAverageRequestText, "88", "Header average metric should use today's tokens divided by today's requests.")
    expectEqual(weekDisplay.last10PromptAverageText, "150", "Last 10 metric should use the active session average.")
    expectEqual(weekDisplay.primaryCostTitle, "EST. CODEX", "Header cost metric should prefer estimated local Codex cost when available.")
    expectEqual(weekDisplay.primaryCostText, "$0.00", "Header cost metric should show estimated local cost when available.")
    expectEqual(weekDisplay.monthlyCostText, "n/a", "Header cost metric should format missing cost data.")
    expectEqual(weekDisplay.tooltipText, "Today: 175 | Avg/req: 88 | OK", "Menu bar tooltip should use the same Today scope.")

    expectEqual(
        weekDisplay.overviewLines,
        [
            "Status: OK · real",
            "Today tokens: 175 · 215 total",
            "Today requests: 2",
            "Estimated local daily cost: $0.00",
            "Estimated local monthly cost: $0.00",
            "Pricing profile: Default Local Codex Estimate",
            "Actual API daily cost: n/a",
            "Actual API monthly cost: n/a",
            "OpenAI Costs API may not include Codex desktop usage.",
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

private func testMarkdownReportLabelsActualAPICosts() throws {
    let temp = try temporaryDirectory()
    let store = TokenUsageStore(stateURL: temp.appendingPathComponent("stats.json"))
    let engine = TokenUsageEngine(
        store: store,
        discovery: TokenSourceDiscovery(homeDirectory: temp)
    )
    let reportURL = temp.appendingPathComponent("token-report.md")

    try engine.writeMarkdownReport(to: reportURL)
    let text = try String(contentsOf: reportURL, encoding: .utf8)

    expect(
        text.contains("Actual OpenAI API daily cost USD"),
        "Markdown report should label daily cost as actual OpenAI API cost."
    )
    expect(
        text.contains("Actual OpenAI API monthly cost USD"),
        "Markdown report should label monthly cost as actual OpenAI API cost."
    )
    expect(
        text.contains("Estimated local Codex daily cost USD"),
        "Markdown report should label local Codex cost as estimated."
    )
    expect(
        text.contains("Estimated local Codex monthly cost USD"),
        "Markdown report should label local monthly cost as estimated."
    )
    expect(
        text.contains("OpenAI Costs API may not include Codex desktop usage."),
        "Markdown report should explain that actual API costs may not include Codex desktop usage."
    )
    expect(
        !text.contains("- Daily cost USD:") && !text.contains("- Monthly cost USD:"),
        "Markdown report should not use generic cost labels that can be confused with estimated local Codex cost."
    )
}

private let tests: [(String, () throws -> Void)] = [
    ("OpenAI usage JSON parsing", testParsesOpenAIStyleUsageJSON),
    ("OpenAI API HTTP error classification", testOpenAIUsageClientClassifiesHTTPFailures),
    ("OpenAI redirect policy", testOpenAIRedirectPolicyPinsHTTPSHostAndPort),
    ("OpenAI Usage API pagination", testOpenAIUsagePaginationSumsMultiplePages),
    ("OpenAI Costs API pagination", testOpenAICostsPaginationSumsMultiplePagesSeparatelyFromUsage),
    ("OpenAI pagination partial failure", testOpenAIUsagePaginationKeepsPartialDataWhenLaterPageFails),
    ("OpenAI pagination duplicate cursor", testOpenAIUsagePaginationDetectsDuplicateCursor),
    ("OpenAI pagination malformed cursor", testOpenAIUsagePaginationDetectsMalformedCursor),
    ("OpenAI pagination max page guard", testOpenAIUsagePaginationHasMaxPageGuard),
    ("OpenAI usage/costs independent partial failures", testOpenAIUsageAndCostsPartialFailuresAreIndependent),
    ("OpenAI API error sanitization", testOpenAIErrorBodySanitizesSecrets),
    ("Estimated cost cached input pricing", testCostEstimatorSeparatesCachedInputAndMultiplier),
    ("Estimated cost sample aggregation", testCostEstimatorAggregatesSamples),
    ("Estimated cost sample reasoning aggregation", testCostEstimatorAggregatesSampleReasoningTokens),
    ("Pricing profile legacy decoding", testPricingProfileDecodesLegacyProfileWithoutID),
    ("Pricing profile validation", testPricingProfileValidationRejectsUnsafeValues),
    ("Pricing profile persistence and reset", testPricingProfilePersistenceAndReset),
    ("Pricing profile cost recalculation", testPricingProfileChangeRecalculatesEstimatedLocalCost),
    ("Codex token_count parsing", testCodexTokenCountUsesLastUsageOnly),
    ("Codex reported total and reasoning parsing", testCodexTokenCountPreservesReportedAndReasoningTokens),
    ("Parser truncation warning", testParserWarnsWhenSampleLimitTruncatesSource),
    ("Parser same-shaped request preservation", testParserKeepsDistinctRequestsWithSameTimestampAndTokens),
    ("Codex session prompt skipping", testStreamingCodexSessionParserSkipsPromptLines),
    ("Codex invalid non-token line skipping", testStreamingCodexSessionParserSkipsInvalidNonTokenLines),
    ("Codex project metadata parsing", testCodexSessionParserAttachesProjectMetadata),
    ("Codex permission monitoring", testPermissionMonitorFlagsBroadPermissions),
    ("Codex permission metadata shapes", testPermissionMonitorParsesAlternateTurnContextShapes),
    ("Codex permission network and trust parsing", testPermissionMonitorParsesNetworkAndTrustedWorkspaceSafely),
    ("Codex permission sandbox network strings", testPermissionMonitorParsesSandboxPolicyNetworkStrings),
    ("Codex permission top-level turn context parsing", testPermissionMonitorParsesTopLevelTurnContext),
    ("Permission presets", testPermissionPresetLevelsApplyExpectedRules),
    ("Permission config writer", testPermissionPresetWriterUpdatesCodexConfig),
    ("Permission config writer backup symlink refusal", testPermissionConfigWriterRejectsBackupSymlink),
    ("Permission config writer hardlink refusal", testPermissionConfigWriterRejectsHardlinkedConfig),
    ("Usage store aggregation", testStoreAggregatesSessionAndTotalStatistics),
    ("Usage store project enrichment", testStoreEnrichesExistingSampleProjectMetadata),
    ("Usage store daily history", testStorePersistsDailyHistoryAndProjectBreakdown),
    ("Usage store estimated local cost separation", testStoreComputesEstimatedLocalCostsSeparatelyFromActualAPICosts),
    ("Context detector normal usage", testContextExplosionDetectorIgnoresNormalUsage),
    ("Context detector recent spike", testContextExplosionDetectorFindsRecentInputSpike),
    ("Context detector cached input severity", testContextExplosionDetectorCachedInputLowersSeverity),
    ("Context detector stable heavy false-positive guard", testContextExplosionDetectorIgnoresStableHeavyUsage),
    ("Context detector low sample guard", testContextExplosionDetectorIgnoresLowSampleCount),
    ("Context detector settings thresholds", testContextExplosionDetectorUsesSettingsThresholds),
    ("Context detector project isolation", testContextExplosionDetectorIsolatesExplodingProject),
    ("Context detector privacy-safe evidence", testContextExplosionFindingEvidenceIsPrivacySafe),
    ("Spend firewall critical burn rate", testSpendFirewallDetectsCriticalBurnRate),
    ("Spend firewall daily budget risk", testSpendFirewallDetectsDailyBudgetRisk),
    ("Spend firewall cooldown", testSpendFirewallCooldownSuppressesRepeatedAlerts),
    ("Spend firewall context integration", testSpendFirewallIncludesContextExplosionAlerts),
    ("Spend firewall permission risk overlap", testSpendFirewallFlagsPermissionRiskOverlap),
    ("Spend firewall privacy-safe evidence", testSpendFirewallEvidenceIsPrivacySafe),
    ("Spend firewall safe mode confirmation", testSpendFirewallSafeModeActionRequiresConfirmation),
    ("Spend firewall no automatic kill or pause", testSpendFirewallRecommendationsDoNotIncludeAutomaticKillOrPause),
    ("Primary display usage scope", testPrimaryDisplayUsageUsesTodayScope),
    ("UI display model coverage", testUIDisplayModelCoversHeaderMenuAndCalendarData),
    ("Legacy state migration", testStoreDecodesLegacyStateWithoutFingerprints),
    ("Legacy cached token migration", testStoreDecodesLegacySamplesWithoutCachedInputTokens),
    ("Source fingerprint persistence", testEnginePersistsSourceFingerprintsAcrossRestart),
    ("Incremental source cursor", testEngineUsesIncrementalCursorForAppendedSessionLog),
    ("Private file symlink refusal", testPrivateFileIORejectsSymlinkDestination),
    ("Private file hardlink refusal", testPrivateFileIORejectsHardlinkDestination),
    ("Oversized JSON refusal", testParserRefusesOversizedStructuredJSONFile),
    ("Report privacy redaction", testReportPrivacyRedactsLocalPaths),
    ("Markdown actual API cost labels", testMarkdownReportLabelsActualAPICosts)
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
