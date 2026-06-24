import AppKit
import TokenUsageCore

enum UsageCalendarScope: String {
    case week
    case month
}

@MainActor
final class UsageCalendarMenuView: NSView {
    private let statistics: TokenUsageStatistics
    private let scope: UsageCalendarScope
    private let calendar = Calendar.current
    private let dayFormatter: DateFormatter
    private let monthFormatter: DateFormatter
    private let weekdayFormatter: DateFormatter

    init(
        statistics: TokenUsageStatistics,
        scope: UsageCalendarScope,
        target: AnyObject?,
        action: Selector
    ) {
        self.statistics = statistics
        self.scope = scope

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        self.dayFormatter = dayFormatter

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"
        self.monthFormatter = monthFormatter

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEE"
        self.weekdayFormatter = weekdayFormatter

        let height: CGFloat = scope == .week ? 146 : 254
        super.init(frame: NSRect(x: 0, y: 0, width: 372, height: height))

        let control = NSSegmentedControl(labels: ["Week", "Month"], trackingMode: .selectOne, target: target, action: action)
        control.segmentStyle = .roundRect
        control.selectedSegment = scope == .week ? 0 : 1
        control.frame = NSRect(x: 220, y: height - 33, width: 132, height: 24)
        addSubview(control)
    }

    required init?(coder: NSCoder) {
        self.statistics = .empty
        self.scope = .week
        self.dayFormatter = DateFormatter()
        self.monthFormatter = DateFormatter()
        self.weekdayFormatter = DateFormatter()
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let card = bounds.insetBy(dx: 10, dy: 8)
        drawCard(in: card)
        drawTitle(in: card)
        switch scope {
        case .week:
            drawWeek(in: card)
        case .month:
            drawMonth(in: card)
        }
    }

    private func drawCard(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.86).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawTitle(in rect: NSRect) {
        let title = scope == .week ? "This Week" : monthFormatter.string(from: Date())
        drawText(
            title,
            rect: NSRect(x: rect.minX + 14, y: rect.maxY - 30, width: 160, height: 18),
            size: 13,
            weight: .semibold,
            color: .white
        )
        drawText(
            "\(compact(statistics.currentMonthUsage.totalTokens)) month",
            rect: NSRect(x: rect.minX + 14, y: rect.maxY - 48, width: 160, height: 14),
            size: 10,
            weight: .medium,
            color: NSColor.white.withAlphaComponent(0.52)
        )
    }

    private func drawWeek(in rect: NSRect) {
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let summaries = summariesByDate()
        let grid = NSRect(x: rect.minX + 14, y: rect.minY + 16, width: rect.width - 28, height: 68)
        let cellWidth = grid.width / 7
        let maxTokens = max(1, weekDates(from: weekStart).map { summaries[$0]?.totalTokens ?? 0 }.max() ?? 0)

        for (index, day) in weekDates(from: weekStart).enumerated() {
            let x = grid.minX + CGFloat(index) * cellWidth
            let cell = NSRect(x: x + 3, y: grid.minY, width: cellWidth - 6, height: grid.height)
            drawDayCell(day: day, summary: summaries[day], maxTokens: maxTokens, rect: cell, showWeekday: true)
        }
    }

    private func drawMonth(in rect: NSRect) {
        let today = calendar.startOfDay(for: Date())
        let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let firstWeekStart = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let summaries = summariesByDate()
        let grid = NSRect(x: rect.minX + 14, y: rect.minY + 14, width: rect.width - 28, height: 174)
        let cellWidth = grid.width / 7
        let cellHeight = grid.height / 6
        let days = (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: firstWeekStart) }
        let maxTokens = max(1, days.map { summaries[$0]?.totalTokens ?? 0 }.max() ?? 0)

        for index in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: index, to: firstWeekStart) else { continue }
            drawText(
                weekdayFormatter.string(from: day).uppercased(),
                rect: NSRect(x: grid.minX + CGFloat(index) * cellWidth, y: grid.maxY + 5, width: cellWidth, height: 12),
                size: 8,
                weight: .bold,
                color: NSColor.white.withAlphaComponent(0.36),
                alignment: .center
            )
        }

        for (index, day) in days.enumerated() {
            let column = index % 7
            let row = index / 7
            let x = grid.minX + CGFloat(column) * cellWidth
            let y = grid.maxY - CGFloat(row + 1) * cellHeight
            let cell = NSRect(x: x + 3, y: y + 3, width: cellWidth - 6, height: cellHeight - 6)
            let isCurrentMonth = calendar.isDate(day, equalTo: monthStart, toGranularity: .month)
            drawDayCell(
                day: day,
                summary: summaries[calendar.startOfDay(for: day)],
                maxTokens: maxTokens,
                rect: cell,
                showWeekday: false,
                isCurrentMonth: isCurrentMonth
            )
        }
    }

    private func drawDayCell(
        day: Date,
        summary: UsagePeriodSummary?,
        maxTokens: Int,
        rect: NSRect,
        showWeekday: Bool,
        isCurrentMonth: Bool = true
    ) {
        let total = summary?.totalTokens ?? 0
        let hasUsage = total > 0
        let today = calendar.isDateInToday(day)
        let intensity = hasUsage ? max(0.18, min(0.82, Double(total) / Double(maxTokens))) : 0
        let fill: NSColor
        if hasUsage {
            fill = NSColor.systemBlue.withAlphaComponent(0.20 + intensity * 0.42)
        } else {
            fill = NSColor.white.withAlphaComponent(isCurrentMonth ? 0.045 : 0.018)
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        fill.setFill()
        path.fill()
        (today ? NSColor.systemBlue.withAlphaComponent(0.78) : NSColor.white.withAlphaComponent(0.06)).setStroke()
        path.lineWidth = today ? 1.2 : 1
        path.stroke()

        let primaryColor = NSColor.white.withAlphaComponent(isCurrentMonth ? 0.86 : 0.26)
        let secondaryColor = hasUsage
            ? NSColor.white.withAlphaComponent(isCurrentMonth ? 0.74 : 0.30)
            : NSColor.white.withAlphaComponent(isCurrentMonth ? 0.34 : 0.18)

        if showWeekday {
            drawText(
                weekdayFormatter.string(from: day),
                rect: NSRect(x: rect.minX + 5, y: rect.maxY - 18, width: rect.width - 10, height: 12),
                size: 9,
                weight: .medium,
                color: secondaryColor,
                alignment: .center
            )
            drawText(
                dayNumber(day),
                rect: NSRect(x: rect.minX + 5, y: rect.maxY - 36, width: rect.width - 10, height: 16),
                size: 14,
                weight: .semibold,
                color: primaryColor,
                alignment: .center,
                monospacedDigits: true
            )
            drawText(
                hasUsage ? compact(total) : "0",
                rect: NSRect(x: rect.minX + 4, y: rect.minY + 8, width: rect.width - 8, height: 13),
                size: 9,
                weight: .medium,
                color: secondaryColor,
                alignment: .center,
                monospacedDigits: true
            )
        } else {
            drawText(
                dayNumber(day),
                rect: NSRect(x: rect.minX + 4, y: rect.maxY - 17, width: rect.width - 8, height: 12),
                size: 9,
                weight: today ? .bold : .medium,
                color: primaryColor,
                alignment: .center,
                monospacedDigits: true
            )
            if hasUsage {
                drawText(
                    compact(total),
                    rect: NSRect(x: rect.minX + 2, y: rect.minY + 4, width: rect.width - 4, height: 11),
                    size: 7,
                    weight: .medium,
                    color: secondaryColor,
                    alignment: .center,
                    monospacedDigits: true
                )
            }
        }
    }

    private func weekDates(from start: Date) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start).map(calendar.startOfDay) }
    }

    private func summariesByDate() -> [Date: UsagePeriodSummary] {
        let today = calendar.startOfDay(for: Date())
        var byDate: [Date: UsagePeriodSummary] = [today: statistics.todayUsage]
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            byDate[yesterday] = statistics.yesterdayUsage
        }

        let byLabel = Dictionary(uniqueKeysWithValues: statistics.recentDailyUsage.map { ($0.label, $0) })
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

    private func dayNumber(_ date: Date) -> String {
        String(calendar.component(.day, from: date))
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fb", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private func drawText(
        _ text: String,
        rect: NSRect,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        monospacedDigits: Bool = false
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        NSString(string: text).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}
