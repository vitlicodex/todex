import AppKit
import TokenUsageCore

@MainActor
final class TokenMenuHeaderView: NSView {
    private let statistics: TokenUsageStatistics
    private let permissionSnapshot: CodexPermissionSnapshot
    private var usageCalendarScope: UsageCalendarScope
    private let onScopeChange: (UsageCalendarScope) -> Void
    private var calendarView: UsageCalendarMenuView?

    private static let viewWidth: CGFloat = 372
    private static let cardInset: CGFloat = 8
    private static let headerHeight: CGFloat = 138
    private static let usageStripHeight: CGFloat = 70
    private static let calendarGap: CGFloat = 2
    private static let usageGreen = NSColor(calibratedRed: 0.30, green: 0.92, blue: 0.48, alpha: 1)

    init(
        statistics: TokenUsageStatistics,
        permissionSnapshot: CodexPermissionSnapshot,
        usageCalendarScope: UsageCalendarScope,
        onScopeChange: @escaping (UsageCalendarScope) -> Void
    ) {
        self.statistics = statistics
        self.permissionSnapshot = permissionSnapshot
        self.usageCalendarScope = usageCalendarScope
        self.onScopeChange = onScopeChange
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: 154))

        let calendar = UsageCalendarMenuView(
            statistics: statistics,
            scope: usageCalendarScope,
            drawsCardBackground: false,
            showsSubtitle: false
        ) { [weak self] scope in
            guard let self else { return }
            self.usageCalendarScope = scope
            onScopeChange(scope)
            resizeToFitCalendar()
        }
        calendarView = calendar
        addSubview(calendar)
        resizeToFitCalendar()
    }

    required init?(coder: NSCoder) {
        self.statistics = .empty
        self.permissionSnapshot = .disabled
        self.usageCalendarScope = .week
        self.onScopeChange = { _ in }
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        layoutCalendar()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let card = bounds.insetBy(dx: Self.cardInset, dy: Self.cardInset)
        drawCard(in: card)
        drawHeader(in: headerRect(in: card))
        drawMetrics(in: headerRect(in: card))
        drawUsageStrip(in: usageStripRect(in: card))
    }

    private var dashboardHeight: CGFloat {
        Self.cardInset * 2
            + Self.headerHeight
            + Self.usageStripHeight
            + Self.calendarGap
            + (calendarView?.frame.height ?? 0)
    }

    private func resizeToFitCalendar() {
        setFrameSize(NSSize(width: Self.viewWidth, height: dashboardHeight))
        layoutCalendar()
        needsDisplay = true
        superview?.needsLayout = true
    }

    private func layoutCalendar() {
        guard let calendarView else { return }
        calendarView.frame.origin = NSPoint(x: 0, y: Self.cardInset)
    }

    private func headerRect(in card: NSRect) -> NSRect {
        NSRect(x: card.minX, y: card.maxY - Self.headerHeight, width: card.width, height: Self.headerHeight)
    }

    private func usageStripRect(in card: NSRect) -> NSRect {
        let calendarTop = (calendarView?.frame.maxY ?? card.minY) + Self.calendarGap
        return NSRect(
            x: card.minX + 14,
            y: calendarTop,
            width: card.width - 28,
            height: Self.usageStripHeight - 8
        )
    }

    private func drawCard(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 0.98),
            NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.22, alpha: 0.98)
        ])?.draw(in: path, angle: 110)

        NSColor.white.withAlphaComponent(0.13).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawHeader(in rect: NSRect) {
        let display = TokenUsageUIDisplay(statistics: statistics, calendarScope: usageCalendarScope)
        let color = statusColor(display.primaryStatus)
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX + 18, y: rect.maxY - 64, width: 5, height: 36),
            xRadius: 2.5,
            yRadius: 2.5
        ).fill()

        drawText(
            display.headerTitle,
            rect: NSRect(x: rect.minX + 34, y: rect.maxY - 40, width: 170, height: 18),
            size: 11,
            weight: .bold,
            color: NSColor.white.withAlphaComponent(0.62)
        )
        drawText(
            display.primaryTokenText,
            rect: NSRect(x: rect.minX + 34, y: rect.maxY - 76, width: 150, height: 36),
            size: 30,
            weight: .semibold,
            color: .white,
            monospacedDigits: true
        )
        drawBadge(
            text: display.statusBadgeText,
            color: color,
            rect: NSRect(x: rect.maxX - 94, y: rect.maxY - 48, width: 74, height: 23)
        )
    }

    private func drawMetrics(in rect: NSRect) {
        let display = TokenUsageUIDisplay(statistics: statistics, calendarScope: usageCalendarScope)
        let y = rect.minY + 16
        let width = (rect.width - 56) / 3
        drawMetric(
            title: "LAST 10",
            value: display.last10PromptAverageText,
            rect: NSRect(x: rect.minX + 18, y: y, width: width, height: 43)
        )
        drawMetric(
            title: "REQUESTS",
            value: display.primaryRequestText,
            rect: NSRect(x: rect.minX + 28 + width, y: y, width: width, height: 43)
        )
        drawMetric(
            title: "COST",
            value: display.monthlyCostText,
            rect: NSRect(x: rect.minX + 38 + width * 2, y: y, width: width, height: 43)
        )
    }

    private func drawMetric(title: String, value: String, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.055).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.07).setStroke()
        path.lineWidth = 1
        path.stroke()

        drawText(
            title,
            rect: NSRect(x: rect.minX + 10, y: rect.maxY - 18, width: rect.width - 20, height: 12),
            size: 8,
            weight: .bold,
            color: NSColor.white.withAlphaComponent(0.48)
        )
        drawText(
            value,
            rect: NSRect(x: rect.minX + 10, y: rect.minY + 7, width: rect.width - 20, height: 20),
            size: 15,
            weight: .semibold,
            color: .white,
            monospacedDigits: true
        )
    }

    private func drawUsageStrip(in rect: NSRect) {
        let summaries: [(String, UsagePeriodSummary)] = [
            ("YESTERDAY", statistics.yesterdayUsage),
            ("WEEK", statistics.currentWeekUsage),
            ("MONTH", statistics.currentMonthUsage)
        ]
        let gap: CGFloat = 8
        let width = (rect.width - gap * 2) / 3

        for (index, item) in summaries.enumerated() {
            let x = rect.minX + CGFloat(index) * (width + gap)
            drawUsageChip(
                title: item.0,
                summary: item.1,
                rect: NSRect(x: x, y: rect.minY + 8, width: width, height: rect.height - 12)
            )
        }
    }

    private func drawUsageChip(title: String, summary: UsagePeriodSummary, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        Self.usageGreen.withAlphaComponent(summary.totalTokens > 0 ? 0.075 : 0.025).setFill()
        path.fill()
        Self.usageGreen.withAlphaComponent(summary.totalTokens > 0 ? 0.18 : 0.06).setStroke()
        path.lineWidth = 1
        path.stroke()

        drawText(
            title,
            rect: NSRect(x: rect.minX + 10, y: rect.maxY - 18, width: rect.width - 20, height: 11),
            size: 7.5,
            weight: .bold,
            color: NSColor.white.withAlphaComponent(0.42)
        )
        drawText(
            TokenUsageUIDisplay.compact(summary.totalTokens),
            rect: NSRect(x: rect.minX + 10, y: rect.minY + 18, width: rect.width - 20, height: 19),
            size: 14,
            weight: .semibold,
            color: summary.totalTokens > 0 ? Self.usageGreen : NSColor.white.withAlphaComponent(0.36),
            monospacedDigits: true
        )
        drawText(
            "\(summary.requests) req",
            rect: NSRect(x: rect.minX + 10, y: rect.minY + 6, width: rect.width - 20, height: 10),
            size: 7.5,
            weight: .medium,
            color: NSColor.white.withAlphaComponent(0.35),
            monospacedDigits: true
        )
    }

    private func drawBadge(text: String, color: NSColor, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        color.withAlphaComponent(0.17).setFill()
        path.fill()
        color.withAlphaComponent(0.68).setStroke()
        path.lineWidth = 1
        path.stroke()
        drawText(text, rect: rect.insetBy(dx: 6, dy: 3), size: 10, weight: .bold, color: color, alignment: .center)
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

    private func statusColor(_ status: TokenUsageStatus) -> NSColor {
        switch status {
        case .ok:
            return .systemGreen
        case .warning:
            return .systemYellow
        case .highUsage:
            return .systemRed
        }
    }
}
