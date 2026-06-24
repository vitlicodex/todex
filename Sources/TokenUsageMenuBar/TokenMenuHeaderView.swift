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
    private static let cardInset: CGFloat = 6
    private static let headerHeight: CGFloat = 118
    private static let usageStripHeight: CGFloat = 54
    private static let calendarGap: CGFloat = 0
    private static let usageGreen = NSColor(calibratedRed: 0.30, green: 0.92, blue: 0.48, alpha: 1)
    private static let usageAmber = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.30, alpha: 1)

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
            showsSubtitle: false,
            compactMode: true
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
            x: card.minX + 12,
            y: calendarTop,
            width: card.width - 24,
            height: Self.usageStripHeight - 4
        )
    }

    private func drawCard(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
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
            roundedRect: NSRect(x: rect.minX + 17, y: rect.maxY - 54, width: 5, height: 32),
            xRadius: 2.5,
            yRadius: 2.5
        ).fill()

        drawText(
            display.headerTitle,
            rect: NSRect(x: rect.minX + 32, y: rect.maxY - 34, width: 170, height: 16),
            size: 10.5,
            weight: .bold,
            color: NSColor.white.withAlphaComponent(0.62)
        )
        drawText(
            display.primaryTokenText,
            rect: NSRect(x: rect.minX + 32, y: rect.maxY - 69, width: 155, height: 34),
            size: 28,
            weight: .semibold,
            color: .white,
            monospacedDigits: true
        )
        drawBadge(
            text: dashboardStatusText(display.primaryStatus),
            color: color,
            rect: NSRect(x: rect.maxX - 99, y: rect.maxY - 45, width: 80, height: 22)
        )
    }

    private func drawMetrics(in rect: NSRect) {
        let display = TokenUsageUIDisplay(statistics: statistics, calendarScope: usageCalendarScope)
        let y = rect.minY + 8
        let gap: CGFloat = 8
        let width = (rect.width - 32 - gap * 2) / 3
        drawMetric(
            title: "AVG / REQ",
            value: display.primaryAverageRequestText,
            rect: NSRect(x: rect.minX + 16, y: y, width: width, height: 39)
        )
        drawMetric(
            title: "REQUESTS",
            value: display.primaryRequestText,
            rect: NSRect(x: rect.minX + 16 + width + gap, y: y, width: width, height: 39)
        )
        drawMetric(
            title: "COST",
            value: display.monthlyCostText,
            rect: NSRect(x: rect.minX + 16 + (width + gap) * 2, y: y, width: width, height: 39)
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
            rect: NSRect(x: rect.minX + 10, y: rect.maxY - 16, width: rect.width - 20, height: 11),
            size: 7.5,
            weight: .bold,
            color: NSColor.white.withAlphaComponent(0.48)
        )
        drawText(
            value,
            rect: NSRect(x: rect.minX + 10, y: rect.minY + 6, width: rect.width - 20, height: 18),
            size: 14,
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
                rect: NSRect(x: x, y: rect.minY + 4, width: width, height: rect.height - 8)
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
            rect: NSRect(x: rect.minX + 10, y: rect.maxY - 15, width: rect.width - 20, height: 10),
            size: 7,
            weight: .bold,
            color: NSColor.white.withAlphaComponent(0.42)
        )
        drawText(
            TokenUsageUIDisplay.compact(summary.totalTokens),
            rect: NSRect(x: rect.minX + 10, y: rect.minY + 14, width: rect.width - 20, height: 17),
            size: 13,
            weight: .semibold,
            color: summary.totalTokens > 0 ? Self.usageGreen : NSColor.white.withAlphaComponent(0.36),
            monospacedDigits: true
        )
        drawText(
            "\(summary.requests) req",
            rect: NSRect(x: rect.minX + 10, y: rect.minY + 4, width: rect.width - 20, height: 9),
            size: 7,
            weight: .medium,
            color: NSColor.white.withAlphaComponent(0.35),
            monospacedDigits: true
        )
    }

    private func drawBadge(text: String, color: NSColor, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        color.withAlphaComponent(0.12).setFill()
        path.fill()
        color.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
        drawText(text, rect: rect.insetBy(dx: 6, dy: 3), size: 9.5, weight: .bold, color: color, alignment: .center)
    }

    private func dashboardStatusText(_ status: TokenUsageStatus) -> String {
        switch status {
        case .ok:
            return "OK"
        case .warning:
            return "WATCH"
        case .highUsage:
            return "HIGH USE"
        }
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
            return Self.usageGreen
        case .warning:
            return NSColor(calibratedRed: 0.95, green: 0.74, blue: 0.28, alpha: 1)
        case .highUsage:
            return Self.usageAmber
        }
    }
}
