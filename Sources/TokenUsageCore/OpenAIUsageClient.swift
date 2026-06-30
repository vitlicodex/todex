import Foundation

public enum OpenAIRedirectPolicy {
    public static func allowsRedirect(from originalURL: URL?, to redirectedURL: URL?) -> Bool {
        guard let originalURL,
              let redirectedURL,
              originalURL.scheme?.lowercased() == "https",
              redirectedURL.scheme?.lowercased() == "https",
              originalURL.host?.lowercased() == redirectedURL.host?.lowercased(),
              normalizedPort(originalURL) == normalizedPort(redirectedURL) else {
            return false
        }
        return true
    }

    private static func normalizedPort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : -1)
    }
}

private final class OpenAIUsageRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard OpenAIRedirectPolicy.allowsRedirect(
            from: task.originalRequest?.url,
            to: request.url
        ) else {
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }
}

public final class OpenAIUsageClient: @unchecked Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let maxPaginationPages = 20

    public init(
        session: URLSession = OpenAIUsageClient.defaultSession,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    private static let redirectDelegate = OpenAIUsageRedirectDelegate()

    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = false
        return URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }()

    public func fetchStatistics(
        apiKey: String,
        settings: MonitorSettings,
        now: Date = Date()
    ) async -> TokenUsageStatistics {
        var issues: [TokenMonitorIssue] = []
        var usage: TokenUsageStatistics

        if settings.isEnabled(.costsEndpoint) {
            async let usageRequest = captureUsage(apiKey: apiKey, settings: settings, now: now)
            async let costsRequest = captureCosts(apiKey: apiKey, settings: settings, now: now)

            switch await usageRequest {
            case .success(let statistics):
                usage = statistics
                issues.append(contentsOf: statistics.issues)
            case .failure(let issue):
                issues.append(issue)
                usage = emptyAPIStatistics(issues: issues)
            }

            switch await costsRequest {
            case .success(let costs):
                apply(costs: costs, to: &usage, settings: settings)
                issues.append(contentsOf: costs.issues)
            case .failure(let issue):
                issues.append(issue)
            }
        } else {
            do {
                usage = try await fetchUsage(apiKey: apiKey, settings: settings, now: now)
                issues.append(contentsOf: usage.issues)
            } catch let error as OpenAIUsageError {
                issues.append(error.issue)
                return emptyAPIStatistics(issues: issues)
            } catch {
                issues.append(.apiRequestFailed(error.localizedDescription))
                return emptyAPIStatistics(issues: issues)
            }
        }

        usage.issues = issues
        usage.status = issues.isEmpty ? classify(statistics: usage, settings: settings) : .warning
        return usage
    }

    private func captureUsage(
        apiKey: String,
        settings: MonitorSettings,
        now: Date
    ) async -> Result<TokenUsageStatistics, TokenMonitorIssue> {
        do {
            return .success(try await fetchUsage(apiKey: apiKey, settings: settings, now: now))
        } catch {
            return .failure(issue(from: error))
        }
    }

    private func captureCosts(
        apiKey: String,
        settings: MonitorSettings,
        now: Date
    ) async -> Result<CostSnapshot, TokenMonitorIssue> {
        do {
            return .success(try await fetchCosts(apiKey: apiKey, settings: settings, now: now))
        } catch {
            return .failure(issue(from: error))
        }
    }

    private func issue(from error: Error) -> TokenMonitorIssue {
        if let error = error as? OpenAIUsageError {
            return error.issue
        }
        return .apiRequestFailed(error.localizedDescription)
    }

    private func emptyAPIStatistics(issues: [TokenMonitorIssue]) -> TokenUsageStatistics {
        var empty = TokenUsageStatistics.empty
        empty.mode = .api
        empty.dataSource = "OpenAI Usage API"
        empty.activeSourcePath = "https://api.openai.com/v1/organization/usage/completions"
        empty.issues = issues
        empty.status = .warning
        return empty
    }

    private func fetchUsage(apiKey: String, settings: MonitorSettings, now: Date) async throws -> TokenUsageStatistics {
        let paginated = try await requestPaginatedJSON(
            path: "/organization/usage/completions",
            queryItems: usageQueryItems(settings: settings, now: now),
            apiKey: apiKey
        )

        var issues = paginated.issues
        var buckets: [[String: Any]] = []
        for page in paginated.pages {
            guard let pageBuckets = page["data"] as? [[String: Any]] else {
                if buckets.isEmpty {
                    throw OpenAIUsageError(.apiResponseInvalid("Missing usage data buckets."))
                }
                issues.append(.apiResponseInvalid("A paginated usage page was missing data buckets."))
                continue
            }
            buckets.append(contentsOf: pageBuckets)
        }

        let calendar = Self.utcCalendar
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: todayStart, end: tomorrowStart)
        let monthStart = Self.monthStart(for: now)
        var monthlyInput = 0
        var monthlyOutput = 0
        var monthlyCached = 0
        var monthlyRequests = 0
        var dailyInput = 0
        var dailyOutput = 0
        var dailyCached = 0
        var dailyRequests = 0
        var modelBreakdown: [String: UsageBreakdown] = [:]
        var projectBreakdown: [String: UsageBreakdown] = [:]
        var todayProjectBreakdown: [String: UsageBreakdown] = [:]
        var apiKeyBreakdown: [String: UsageBreakdown] = [:]
        var dailyUsage: [Date: UsagePeriodSummary] = [:]
        var latestDate: Date?

        for bucket in buckets {
            let bucketStart = dateFromEpoch(bucket["start_time"]) ?? monthStart
            let bucketDay = calendar.startOfDay(for: bucketStart)
            latestDate = maxDate(latestDate, bucketStart)
            guard let results = bucket["results"] as? [[String: Any]] else { continue }

            for result in results {
                let input = intValue(result["input_tokens"]) + intValue(result["input_audio_tokens"])
                let output = intValue(result["output_tokens"]) + intValue(result["output_audio_tokens"])
                let cached = intValue(in: result, keys: [
                    "input_cached_tokens",
                    "cached_input_tokens",
                    "inputCachedTokens",
                    "cachedInputTokens"
                ])
                let requests = intValue(result["num_model_requests"])

                accumulateDailyUsage(&dailyUsage, day: bucketDay, input: input, cached: cached, output: output, requests: requests)

                if bucketStart >= monthStart {
                    monthlyInput += input
                    monthlyOutput += output
                    monthlyCached += cached
                    monthlyRequests += requests
                }

                if calendar.isDate(bucketStart, inSameDayAs: todayStart) {
                    dailyInput += input
                    dailyOutput += output
                    dailyCached += cached
                    dailyRequests += requests
                }

                if settings.isEnabled(.modelBreakdown), bucketStart >= monthStart, let model = result["model"] as? String {
                    accumulate(&modelBreakdown, label: model, input: input, output: output, cached: cached, requests: requests)
                }
                if settings.isEnabled(.projectBreakdown), let project = result["project_id"] as? String {
                    if bucketStart >= monthStart {
                        accumulate(&projectBreakdown, label: project, input: input, output: output, cached: cached, requests: requests)
                    }
                    if calendar.isDate(bucketStart, inSameDayAs: todayStart) {
                        accumulate(&todayProjectBreakdown, label: project, input: input, output: output, cached: cached, requests: requests)
                    }
                }
                if settings.isEnabled(.apiKeyBreakdown), bucketStart >= monthStart, let apiKeyID = result["api_key_id"] as? String {
                    accumulate(&apiKeyBreakdown, label: apiKeyID, input: input, output: output, cached: cached, requests: requests)
                }
            }
        }

        let dailyTokens = dailyInput + dailyOutput
        let monthlyTokens = monthlyInput + monthlyOutput
        let dailyAverage = dailyRequests > 0 ? Double(dailyTokens) / Double(dailyRequests) : 0
        let weekSummary = periodSummary(label: "This week", dailyUsage: dailyUsage, interval: weekInterval)
        let yesterdayUsage = dailyUsage[yesterdayStart] ?? UsagePeriodSummary(label: "Yesterday")
        let todayUsage = UsagePeriodSummary(
            label: "Today",
            inputTokens: dailyInput,
            cachedInputTokens: dailyCached,
            outputTokens: dailyOutput,
            totalTokens: dailyTokens,
            requests: dailyRequests
        )
        let monthUsage = UsagePeriodSummary(
            label: "This month",
            inputTokens: monthlyInput,
            cachedInputTokens: monthlyCached,
            outputTokens: monthlyOutput,
            totalTokens: monthlyTokens,
            requests: monthlyRequests
        )

        return TokenUsageStatistics(
            currentSessionPrompts: dailyRequests,
            totalPrompts: monthlyRequests,
            sessionTokens: dailyTokens,
            totalTokens: monthlyTokens,
            inputTokens: dailyInput,
            outputTokens: dailyOutput,
            averageTokensPerPrompt: dailyAverage,
            last10PromptsAverage: dailyAverage,
            peakPromptCost: 0,
            mode: .api,
            status: TokenUsageStatus.classify(sessionTokens: dailyTokens, last10Average: dailyAverage),
            lastUpdatedAt: latestDate,
            activeSourcePath: "https://api.openai.com/v1/organization/usage/completions",
            issues: issues,
            cachedInputTokens: dailyCached,
            requestCount: dailyRequests,
            dailyCostUSD: nil,
            monthlyCostUSD: nil,
            budgetUSD: settings.monthlyBudgetUSD,
            budgetUsedRatio: nil,
            dataSource: "OpenAI Usage API",
            modelBreakdown: sortedBreakdown(modelBreakdown),
            projectBreakdown: sortedBreakdown(projectBreakdown),
            apiKeyBreakdown: sortedBreakdown(apiKeyBreakdown),
            todayUsage: todayUsage,
            yesterdayUsage: UsagePeriodSummary(
                label: "Yesterday",
                inputTokens: yesterdayUsage.inputTokens,
                cachedInputTokens: yesterdayUsage.cachedInputTokens,
                outputTokens: yesterdayUsage.outputTokens,
                totalTokens: yesterdayUsage.totalTokens,
                requests: yesterdayUsage.requests
            ),
            currentWeekUsage: weekSummary,
            currentMonthUsage: monthUsage,
            recentDailyUsage: recentDailyUsage(from: dailyUsage, calendar: calendar, todayStart: todayStart),
            todayProjectBreakdown: sortedBreakdown(todayProjectBreakdown)
        )
    }

    private func apply(costs: CostSnapshot, to usage: inout TokenUsageStatistics, settings: MonitorSettings) {
        usage.dailyCostUSD = costs.dailyCostUSD
        usage.monthlyCostUSD = costs.monthlyCostUSD
        usage.budgetUSD = settings.monthlyBudgetUSD
        if settings.monthlyBudgetUSD > 0, let monthlyCostUSD = costs.monthlyCostUSD {
            usage.budgetUsedRatio = monthlyCostUSD / settings.monthlyBudgetUSD
        }
        usage.projectBreakdown = mergeCosts(costs.projectCosts, into: usage.projectBreakdown)
        usage.apiKeyBreakdown = mergeCosts(costs.apiKeyCosts, into: usage.apiKeyBreakdown)
    }

    private func fetchCosts(apiKey: String, settings: MonitorSettings, now: Date) async throws -> CostSnapshot {
        let paginated = try await requestPaginatedJSON(
            path: "/organization/costs",
            queryItems: costsQueryItems(settings: settings, now: now),
            apiKey: apiKey
        )

        var issues = paginated.issues
        var buckets: [[String: Any]] = []
        for page in paginated.pages {
            guard let pageBuckets = page["data"] as? [[String: Any]] else {
                if buckets.isEmpty {
                    throw OpenAIUsageError(.apiResponseInvalid("Missing costs data buckets."))
                }
                issues.append(.apiResponseInvalid("A paginated costs page was missing data buckets."))
                continue
            }
            buckets.append(contentsOf: pageBuckets)
        }

        let calendar = Self.utcCalendar
        let todayStart = calendar.startOfDay(for: now)
        let monthStart = Self.monthStart(for: now)
        var dailyCost = 0.0
        var monthlyCost = 0.0
        var projectCosts: [String: Double] = [:]
        var apiKeyCosts: [String: Double] = [:]

        for bucket in buckets {
            let bucketStart = dateFromEpoch(bucket["start_time"]) ?? todayStart
            guard let results = bucket["results"] as? [[String: Any]] else { continue }

            for result in results {
                let value = amountValue(result["amount"])
                if bucketStart >= monthStart {
                    monthlyCost += value
                }
                if calendar.isDate(bucketStart, inSameDayAs: todayStart) {
                    dailyCost += value
                }
                if settings.isEnabled(.projectBreakdown), bucketStart >= monthStart, let project = result["project_id"] as? String {
                    projectCosts[project, default: 0] += value
                }
                if settings.isEnabled(.apiKeyBreakdown), bucketStart >= monthStart, let apiKeyID = result["api_key_id"] as? String {
                    apiKeyCosts[apiKeyID, default: 0] += value
                }
            }
        }

        return CostSnapshot(
            dailyCostUSD: dailyCost,
            monthlyCostUSD: monthlyCost,
            projectCosts: projectCosts,
            apiKeyCosts: apiKeyCosts,
            issues: issues
        )
    }

    private func requestPaginatedJSON(
        path: String,
        queryItems: [URLQueryItem],
        apiKey: String
    ) async throws -> PaginatedPayload {
        var pages: [[String: Any]] = []
        var issues: [TokenMonitorIssue] = []
        var nextQueryItems = queryItems
        var seenCursors = Set<String>()

        for pageIndex in 0..<maxPaginationPages {
            let payload: Any
            do {
                payload = try await requestJSON(path: path, queryItems: nextQueryItems, apiKey: apiKey)
            } catch {
                if pages.isEmpty {
                    throw error
                }
                issues.append(issue(from: error))
                break
            }

            guard let page = payload as? [String: Any] else {
                if pages.isEmpty {
                    throw OpenAIUsageError(.apiResponseInvalid("Paginated API response was not a JSON object."))
                }
                issues.append(.apiResponseInvalid("A paginated API response was not a JSON object."))
                break
            }

            pages.append(page)

            guard let cursor = paginationCursor(from: page) else {
                if hasMorePages(page) == true {
                    issues.append(.apiResponseInvalid("Pagination indicated more pages but no valid cursor was provided."))
                }
                break
            }

            let cursorKey = "\(cursor.queryName)=\(cursor.value)"
            guard seenCursors.insert(cursorKey).inserted else {
                issues.append(.apiResponseInvalid("Duplicate pagination cursor was ignored."))
                break
            }

            if pageIndex == maxPaginationPages - 1 {
                issues.append(.apiResponseInvalid("Pagination page limit exceeded after \(maxPaginationPages) pages."))
                break
            }

            nextQueryItems = queryItemsForNextPage(base: queryItems, cursor: cursor)
        }

        guard !pages.isEmpty else {
            throw OpenAIUsageError(.apiResponseInvalid("Paginated API response did not contain any pages."))
        }

        return PaginatedPayload(pages: pages, issues: issues)
    }

    private func paginationCursor(from page: [String: Any]) -> PaginationCursor? {
        if let value = paginationString(page["next_page"] ?? page["nextPage"]) {
            return PaginationCursor(queryName: "page", value: value)
        }
        if let value = paginationString(page["next_cursor"] ?? page["nextCursor"]) {
            return PaginationCursor(queryName: "cursor", value: value)
        }
        if let value = paginationString(page["after"]) {
            return PaginationCursor(queryName: "after", value: value)
        }
        return nil
    }

    private func paginationString(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let int = value as? Int {
            return "\(int)"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func hasMorePages(_ page: [String: Any]) -> Bool? {
        boolValue(page["has_more"] ?? page["hasMore"] ?? page["more"])
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func queryItemsForNextPage(base: [URLQueryItem], cursor: PaginationCursor) -> [URLQueryItem] {
        var output = base.filter { item in
            !["page", "cursor", "after"].contains(item.name)
        }
        output.append(URLQueryItem(name: cursor.queryName, value: cursor.value))
        return output
    }

    private func requestJSON(path: String, queryItems: [URLQueryItem], apiKey: String) async throws -> Any {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw OpenAIUsageError(.apiResponseInvalid("Could not build URL for \(path)."))
        }
        guard url.scheme?.lowercased() == "https" else {
            throw OpenAIUsageError(.apiRequestFailed("Refusing to send Authorization header to a non-HTTPS API URL."))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAIUsageError(.apiTimeout)
        } catch {
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIUsageError(.apiRequestFailed("Missing HTTP response."))
        }
        guard http.statusCode != 401 && http.statusCode != 403 else {
            throw OpenAIUsageError(.apiUnauthorized)
        }
        if http.statusCode == 408 {
            throw OpenAIUsageError(.apiTimeout)
        }
        if http.statusCode == 429 {
            throw OpenAIUsageError(.apiRateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After")))
        }
        if http.statusCode == 404 {
            throw OpenAIUsageError(.apiEndpointUnavailable(http.statusCode))
        }
        if (500..<600).contains(http.statusCode) {
            throw OpenAIUsageError(.apiServerError(http.statusCode))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIUsageError(.apiRequestFailed("HTTP \(http.statusCode): \(sanitizedResponseBody(data))"))
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OpenAIUsageError(.apiResponseInvalid(error.localizedDescription))
        }
    }

    private func usageQueryItems(settings: MonitorSettings, now: Date) -> [URLQueryItem] {
        var items = commonQueryItems(now: now)
        var groups: [String] = []
        if settings.isEnabled(.modelBreakdown) { groups.append("model") }
        if settings.isEnabled(.projectBreakdown) { groups.append("project_id") }
        if settings.isEnabled(.apiKeyBreakdown) { groups.append("api_key_id") }
        items.append(contentsOf: groups.map { URLQueryItem(name: "group_by[]", value: $0) })
        return items
    }

    private func costsQueryItems(settings: MonitorSettings, now: Date) -> [URLQueryItem] {
        var items = commonQueryItems(now: now)
        var groups: [String] = []
        if settings.isEnabled(.projectBreakdown) { groups.append("project_id") }
        if settings.isEnabled(.apiKeyBreakdown) { groups.append("api_key_id") }
        items.append(contentsOf: groups.map { URLQueryItem(name: "group_by[]", value: $0) })
        return items
    }

    private func commonQueryItems(now: Date) -> [URLQueryItem] {
        let calendar = Self.utcCalendar
        let todayStart = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -13, to: todayStart) ?? todayStart
        let monthStart = Self.monthStart(for: now)
        let queryStart = min(recentStart, monthStart)
        return [
            URLQueryItem(name: "start_time", value: "\(Int(queryStart.timeIntervalSince1970))"),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "62")
        ]
    }

    private func classify(statistics: TokenUsageStatistics, settings: MonitorSettings) -> TokenUsageStatus {
        if settings.isEnabled(.budgetAlerts), let ratio = statistics.budgetUsedRatio {
            if ratio >= 0.9 { return .highUsage }
            if ratio >= 0.75 { return .warning }
        }
        return TokenUsageStatus.classify(
            sessionTokens: statistics.sessionTokens,
            last10Average: statistics.averageTokensPerPrompt
        )
    }

    private func mergeCosts(_ costs: [String: Double], into breakdown: [UsageBreakdown]) -> [UsageBreakdown] {
        var byLabel = Dictionary(uniqueKeysWithValues: breakdown.map { ($0.label, $0) })
        for (label, cost) in costs {
            var item = byLabel[label] ?? UsageBreakdown(label: label)
            item.costUSD = cost
            byLabel[label] = item
        }
        return byLabel.values.sorted { lhs, rhs in
            (lhs.costUSD ?? 0, lhs.totalTokens) > (rhs.costUSD ?? 0, rhs.totalTokens)
        }
    }

    private func accumulate(
        _ breakdown: inout [String: UsageBreakdown],
        label: String,
        input: Int,
        output: Int,
        cached: Int,
        requests: Int
    ) {
        var item = breakdown[label] ?? UsageBreakdown(label: label)
        item.inputTokens += input
        item.outputTokens += output
        item.cachedInputTokens += cached
        item.totalTokens += input + output
        item.requests += requests
        breakdown[label] = item
    }

    private func sortedBreakdown(_ breakdown: [String: UsageBreakdown]) -> [UsageBreakdown] {
        breakdown.values.sorted { $0.totalTokens > $1.totalTokens }
    }

    private func accumulateDailyUsage(
        _ dailyUsage: inout [Date: UsagePeriodSummary],
        day: Date,
        input: Int,
        cached: Int,
        output: Int,
        requests: Int
    ) {
        var summary = dailyUsage[day] ?? UsagePeriodSummary(label: Self.dayLabel(for: day))
        summary.inputTokens += input
        summary.cachedInputTokens += cached
        summary.outputTokens += output
        summary.totalTokens += input + output
        summary.requests += requests
        dailyUsage[day] = summary
    }

    private func periodSummary(
        label: String,
        dailyUsage: [Date: UsagePeriodSummary],
        interval: DateInterval
    ) -> UsagePeriodSummary {
        dailyUsage.reduce(UsagePeriodSummary(label: label)) { partial, entry in
            guard interval.contains(entry.key) else {
                return partial
            }
            let summary = entry.value
            return UsagePeriodSummary(
                label: label,
                inputTokens: partial.inputTokens + summary.inputTokens,
                cachedInputTokens: partial.cachedInputTokens + summary.cachedInputTokens,
                outputTokens: partial.outputTokens + summary.outputTokens,
                totalTokens: partial.totalTokens + summary.totalTokens,
                requests: partial.requests + summary.requests
            )
        }
    }

    private func recentDailyUsage(
        from dailyUsage: [Date: UsagePeriodSummary],
        calendar: Calendar,
        todayStart: Date
    ) -> [UsagePeriodSummary] {
        let monthStart = Self.monthStart(for: todayStart)
        let dayCount = (calendar.dateComponents([.day], from: monthStart, to: todayStart).day ?? 0) + 1
        var output: [UsagePeriodSummary] = []
        output.reserveCapacity(dayCount)

        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else {
                continue
            }
            let raw = dailyUsage[day] ?? UsagePeriodSummary(label: Self.dayLabel(for: day))
            let label: String
            if offset == 0 {
                label = "Today"
            } else if offset == 1 {
                label = "Yesterday"
            } else {
                label = raw.label
            }
            output.append(
                UsagePeriodSummary(
                    label: label,
                    inputTokens: raw.inputTokens,
                    cachedInputTokens: raw.cachedInputTokens,
                    outputTokens: raw.outputTokens,
                    totalTokens: raw.totalTokens,
                    requests: raw.requests
                )
            )
        }

        return output
    }

    private static func dayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = utcCalendar
        formatter.timeZone = utcCalendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private func intValue(in dictionary: [String: Any], keys: [String]) -> Int {
        for key in keys {
            let value = intValue(dictionary[key])
            if value != 0 {
                return value
            }
        }
        return 0
    }

    private func amountValue(_ value: Any?) -> Double {
        guard let dictionary = value as? [String: Any] else { return 0 }
        if let double = dictionary["value"] as? Double { return double }
        if let number = dictionary["value"] as? NSNumber { return number.doubleValue }
        if let string = dictionary["value"] as? String { return Double(string) ?? 0 }
        return 0
    }

    private func sanitizedResponseBody(_ data: Data) -> String {
        guard var body = String(data: data, encoding: .utf8), !body.isEmpty else {
            return "empty response body"
        }

        let patterns: [(String, String)] = [
            (#"sk-[A-Za-z0-9_\-]{8,}"#, "[REDACTED]"),
            (#"Bearer\s+[A-Za-z0-9_\-\.]+"#, "Bearer [REDACTED]"),
            (#"(?i)(OPENAI_API_KEY\s*=\s*)[^\s]+"#, "$1[REDACTED]"),
            (#"(?i)(api[_-]?key\s*[:=]\s*)[^\s,;]+"#, "$1[REDACTED]"),
            (#"(?i)(authorization\s*[:=]\s*)[^\s,;]+"#, "$1[REDACTED]")
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            body = regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: template)
        }

        body = body.replacingOccurrences(of: "\n", with: " ")
        if body.count > 300 {
            return String(body.prefix(300)) + "..."
        }
        return body
    }

    private func dateFromEpoch(_ value: Any?) -> Date? {
        if let int = value as? Int { return Date(timeIntervalSince1970: TimeInterval(int)) }
        if let double = value as? Double { return Date(timeIntervalSince1970: double) }
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        return nil
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    public static func monthStart(for date: Date) -> Date {
        utcCalendar.date(from: utcCalendar.dateComponents([.year, .month], from: date)) ?? date
    }
}

private struct CostSnapshot {
    var dailyCostUSD: Double?
    var monthlyCostUSD: Double?
    var projectCosts: [String: Double]
    var apiKeyCosts: [String: Double]
    var issues: [TokenMonitorIssue] = []
}

private struct PaginatedPayload {
    var pages: [[String: Any]]
    var issues: [TokenMonitorIssue]
}

private struct PaginationCursor: Hashable {
    var queryName: String
    var value: String
}

private struct OpenAIUsageError: Error {
    var issue: TokenMonitorIssue

    init(_ issue: TokenMonitorIssue) {
        self.issue = issue
    }
}
