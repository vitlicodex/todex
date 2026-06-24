import Foundation

public final class OpenAIUsageClient: @unchecked Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(
        session: URLSession = OpenAIUsageClient.defaultSession,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public func fetchStatistics(
        apiKey: String,
        settings: MonitorSettings,
        now: Date = Date()
    ) async -> TokenUsageStatistics {
        var issues: [TokenMonitorIssue] = []
        var usage: TokenUsageStatistics

        if settings.isEnabled(.costsEndpoint) {
            async let usageRequest = fetchUsage(apiKey: apiKey, settings: settings, now: now)
            async let costsRequest = fetchCosts(apiKey: apiKey, settings: settings, now: now)

            do {
                usage = try await usageRequest
            } catch let error as OpenAIUsageError {
                issues.append(error.issue)
                return emptyAPIStatistics(issues: issues)
            } catch {
                issues.append(.apiRequestFailed(error.localizedDescription))
                return emptyAPIStatistics(issues: issues)
            }

            do {
                let costs = try await costsRequest
                usage.dailyCostUSD = costs.dailyCostUSD
                usage.monthlyCostUSD = costs.monthlyCostUSD
                usage.budgetUSD = settings.monthlyBudgetUSD
                if settings.monthlyBudgetUSD > 0, let monthlyCostUSD = costs.monthlyCostUSD {
                    usage.budgetUsedRatio = monthlyCostUSD / settings.monthlyBudgetUSD
                }
                usage.projectBreakdown = mergeCosts(costs.projectCosts, into: usage.projectBreakdown)
                usage.apiKeyBreakdown = mergeCosts(costs.apiKeyCosts, into: usage.apiKeyBreakdown)
            } catch let error as OpenAIUsageError {
                issues.append(error.issue)
            } catch {
                issues.append(.apiRequestFailed(error.localizedDescription))
            }
        } else {
            do {
                usage = try await fetchUsage(apiKey: apiKey, settings: settings, now: now)
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
        let payload = try await requestJSON(
            path: "/organization/usage/completions",
            queryItems: usageQueryItems(settings: settings, now: now),
            apiKey: apiKey
        )

        guard let page = payload as? [String: Any],
              let buckets = page["data"] as? [[String: Any]] else {
            throw OpenAIUsageError(.apiResponseInvalid("Missing usage data buckets."))
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
                let cached = intValue(result["input_cached_tokens"])
                let requests = intValue(result["num_model_requests"])

                accumulateDailyUsage(&dailyUsage, day: bucketDay, input: input, output: output, requests: requests)

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
        let average = monthlyRequests > 0 ? Double(monthlyTokens) / Double(monthlyRequests) : 0
        let weekSummary = periodSummary(label: "This week", dailyUsage: dailyUsage, interval: weekInterval)
        let yesterdayUsage = dailyUsage[yesterdayStart] ?? UsagePeriodSummary(label: "Yesterday")
        let todayUsage = UsagePeriodSummary(
            label: "Today",
            inputTokens: dailyInput,
            outputTokens: dailyOutput,
            totalTokens: dailyTokens,
            requests: dailyRequests
        )
        let monthUsage = UsagePeriodSummary(
            label: "This month",
            inputTokens: monthlyInput,
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
            averageTokensPerPrompt: average,
            last10PromptsAverage: average,
            peakPromptCost: 0,
            mode: .api,
            status: TokenUsageStatus.classify(sessionTokens: dailyTokens, last10Average: average),
            lastUpdatedAt: latestDate,
            activeSourcePath: "https://api.openai.com/v1/organization/usage/completions",
            issues: [],
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

    private func fetchCosts(apiKey: String, settings: MonitorSettings, now: Date) async throws -> CostSnapshot {
        let payload = try await requestJSON(
            path: "/organization/costs",
            queryItems: costsQueryItems(settings: settings, now: now),
            apiKey: apiKey
        )

        guard let page = payload as? [String: Any],
              let buckets = page["data"] as? [[String: Any]] else {
            throw OpenAIUsageError(.apiResponseInvalid("Missing costs data buckets."))
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
            apiKeyCosts: apiKeyCosts
        )
    }

    private func requestJSON(path: String, queryItems: [URLQueryItem], apiKey: String) async throws -> Any {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw OpenAIUsageError(.apiResponseInvalid("Could not build URL for \(path)."))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIUsageError(.apiRequestFailed("Missing HTTP response."))
        }
        guard http.statusCode != 401 && http.statusCode != 403 else {
            throw OpenAIUsageError(.apiUnauthorized)
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
        output: Int,
        requests: Int
    ) {
        var summary = dailyUsage[day] ?? UsagePeriodSummary(label: Self.dayLabel(for: day))
        summary.inputTokens += input
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
        var output: [UsagePeriodSummary] = []
        output.reserveCapacity(14)

        for offset in stride(from: 13, through: 0, by: -1) {
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
}

private struct OpenAIUsageError: Error {
    var issue: TokenMonitorIssue

    init(_ issue: TokenMonitorIssue) {
        self.issue = issue
    }
}
