import Foundation

public enum UsageCalendarScope: String, Codable, Sendable {
    case week
    case month
}

public struct TokenUsageUIDisplay: Equatable, Sendable {
    public var headerTitle: String
    public var primaryTokenText: String
    public var primaryRequestText: String
    public var primaryStatus: TokenUsageStatus
    public var statusBadgeText: String
    public var last10PromptAverageText: String
    public var monthlyCostText: String
    public var tooltipText: String
    public var overviewLines: [String]
    public var usageLogLines: [String]
    public var calendar: UsageCalendarDisplay

    public init(
        statistics: TokenUsageStatistics,
        calendarScope: UsageCalendarScope = .week,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let primaryUsage = statistics.primaryDisplayUsage
        let primaryStatus = statistics.primaryDisplayStatus
        self.headerTitle = "CODEX TODAY"
        self.primaryTokenText = Self.compact(primaryUsage.totalTokens)
        self.primaryRequestText = "\(primaryUsage.requests)"
        self.primaryStatus = primaryStatus
        self.statusBadgeText = Self.statusBadgeText(primaryStatus)
        self.last10PromptAverageText = Self.compact(Int(statistics.last10PromptsAverage))
        self.monthlyCostText = Self.formatUSD(statistics.monthlyCostUSD)
        self.tooltipText = "Today: \(Self.compact(primaryUsage.totalTokens)) | Last 10: \(Self.compact(Int(statistics.last10PromptsAverage))) | \(primaryStatus.rawValue)"
        self.overviewLines = [
            "Status: \(primaryStatus.rawValue) · \(statistics.mode.rawValue)",
            "Today tokens: \(primaryUsage.totalTokens) · \(statistics.totalTokens) total",
            "Today requests: \(primaryUsage.requests)",
            "Input tokens today: \(primaryUsage.inputTokens)",
            "Output tokens today: \(primaryUsage.outputTokens)",
            "Cached input tokens: \(statistics.cachedInputTokens)",
            "Average tokens per prompt: \(Self.integer(statistics.averageTokensPerPrompt))",
            "Last 10 prompts average: \(Self.integer(statistics.last10PromptsAverage))",
            "Peak prompt cost: \(statistics.peakPromptCost)"
        ]
        self.usageLogLines = [
            Self.periodLine(statistics.todayUsage),
            Self.periodLine(statistics.yesterdayUsage),
            Self.periodLine(statistics.currentWeekUsage),
            Self.periodLine(statistics.currentMonthUsage)
        ]
        self.calendar = UsageCalendarDisplay(
            statistics: statistics,
            scope: calendarScope,
            now: now,
            calendar: calendar
        )
    }

    public static func compact(_ value: Int) -> String {
        if value >= 1_000_000_000_000 {
            return String(format: "%.1ft", Double(value) / 1_000_000_000_000.0)
        }
        if value >= 1_000_000_000 {
            return String(format: "%.1fb", Double(value) / 1_000_000_000.0)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.0fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    public static func periodLine(_ summary: UsagePeriodSummary) -> String {
        "\(summary.label): \(compact(summary.totalTokens)) tok · \(summary.requests) req · in \(compact(summary.inputTokens)) / out \(compact(summary.outputTokens))"
    }

    public static func integer(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    public static func formatUSD(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        if value >= 1_000 {
            return String(format: "$%.1fk", value / 1_000)
        }
        if value >= 10 {
            return String(format: "$%.0f", value)
        }
        return String(format: "$%.2f", value)
    }

    public static func statusBadgeText(_ status: TokenUsageStatus) -> String {
        switch status {
        case .ok:
            return "OK"
        case .warning:
            return "WARN"
        case .highUsage:
            return "HIGH"
        }
    }
}

public struct UsageCalendarDisplay: Equatable, Sendable {
    public var scope: UsageCalendarScope
    public var title: String
    public var subtitle: String
    public var days: [UsageCalendarDay]
    public var maxTokens: Int

    public init(
        statistics: TokenUsageStatistics,
        scope: UsageCalendarScope,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let today = calendar.startOfDay(for: now)
        let summaries = Self.summariesByDate(statistics: statistics, today: today, calendar: calendar)
        let days: [Date]

        switch scope {
        case .week:
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart).map(calendar.startOfDay) }
            self.title = "This Week"
        case .month:
            let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
            let firstWeekStart = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
            days = (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: firstWeekStart).map(calendar.startOfDay) }
            self.title = Self.monthTitle(for: today, calendar: calendar)
        }

        self.scope = scope
        self.subtitle = "\(TokenUsageUIDisplay.compact(statistics.currentMonthUsage.totalTokens)) month"
        self.maxTokens = max(1, days.map { summaries[$0]?.totalTokens ?? 0 }.max() ?? 0)
        self.days = days.map { day in
            let summary = summaries[day] ?? UsagePeriodSummary(label: Self.dayLabel(for: day), requests: 0)
            let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
            return UsageCalendarDay(
                date: day,
                dayNumber: calendar.component(.day, from: day),
                weekday: Self.weekdayLabel(for: day, calendar: calendar),
                totalTokens: summary.totalTokens,
                requests: summary.requests,
                isToday: calendar.isDate(day, inSameDayAs: today),
                isCurrentMonth: calendar.isDate(day, equalTo: monthStart, toGranularity: .month)
            )
        }
    }

    private static func summariesByDate(
        statistics: TokenUsageStatistics,
        today: Date,
        calendar: Calendar
    ) -> [Date: UsagePeriodSummary] {
        var byDate: [Date: UsagePeriodSummary] = [today: statistics.todayUsage]
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            byDate[yesterday] = statistics.yesterdayUsage
        }

        var byLabel: [String: UsagePeriodSummary] = [:]
        for summary in statistics.recentDailyUsage {
            byLabel[summary.label] = summary
        }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "MMM d"

        for offset in 0..<45 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let label: String
            if offset == 0 {
                label = "Today"
            } else if offset == 1 {
                label = "Yesterday"
            } else {
                label = dayFormatter.string(from: day)
            }
            if let summary = byLabel[label] {
                byDate[calendar.startOfDay(for: day)] = summary
            }
        }
        return byDate
    }

    private static func monthTitle(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private static func weekdayLabel(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private static func dayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

public struct UsageCalendarDay: Equatable, Sendable {
    public var date: Date
    public var dayNumber: Int
    public var weekday: String
    public var totalTokens: Int
    public var requests: Int
    public var isToday: Bool
    public var isCurrentMonth: Bool

    public var hasUsage: Bool {
        totalTokens > 0
    }
}
