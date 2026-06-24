import AppKit
import TokenUsageCore

@MainActor
final class UsageCalendarMenuView: NSView {
    private let statistics: TokenUsageStatistics
    private var scope: UsageCalendarScope
    private let onScopeChange: (UsageCalendarScope) -> Void
    private let segmentedControl: NSSegmentedControl
    private let calendar = Calendar.current
    private static let viewWidth: CGFloat = 372
    private static let viewHeight: CGFloat = 254

    init(
        statistics: TokenUsageStatistics,
        scope: UsageCalendarScope,
        onScopeChange: @escaping (UsageCalendarScope) -> Void
    ) {
        self.statistics = statistics
        self.scope = scope
        self.onScopeChange = onScopeChange
        self.segmentedControl = NSSegmentedControl(labels: ["Week", "Month"], trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))

        segmentedControl.segmentStyle = .roundRect
        segmentedControl.target = self
        segmentedControl.action = #selector(selectScope(_:))
        layoutSegmentedControl()
        addSubview(segmentedControl)
    }

    required init?(coder: NSCoder) {
        self.statistics = .empty
        self.scope = .week
        self.onScopeChange = { _ in }
        self.segmentedControl = NSSegmentedControl(labels: ["Week", "Month"], trackingMode: .selectOne, target: nil, action: nil)
        super.init(coder: coder)
    }

    @objc private func selectScope(_ sender: NSSegmentedControl) {
        let nextScope: UsageCalendarScope = sender.selectedSegment == 1 ? .month : .week
        guard nextScope != scope else { return }
        scope = nextScope
        layoutSegmentedControl()
        needsDisplay = true
        onScopeChange(nextScope)
    }

    private func layoutSegmentedControl() {
        segmentedControl.selectedSegment = scope == .week ? 0 : 1
        segmentedControl.frame = NSRect(x: 220, y: bounds.height - 33, width: 132, height: 24)
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
        let display = calendarDisplay()
        drawText(
            display.title,
            rect: NSRect(x: rect.minX + 14, y: rect.maxY - 30, width: 160, height: 18),
            size: 13,
            weight: .semibold,
            color: .white
        )
        drawText(
            display.subtitle,
            rect: NSRect(x: rect.minX + 14, y: rect.maxY - 48, width: 160, height: 14),
            size: 10,
            weight: .medium,
            color: NSColor.white.withAlphaComponent(0.52)
        )
    }

    private func drawWeek(in rect: NSRect) {
        let display = calendarDisplay()
        let grid = NSRect(x: rect.minX + 14, y: rect.minY + 16, width: rect.width - 28, height: 68)
        let cellWidth = grid.width / 7

        for (index, day) in display.days.enumerated() {
            let x = grid.minX + CGFloat(index) * cellWidth
            let cell = NSRect(x: x + 3, y: grid.minY, width: cellWidth - 6, height: grid.height)
            drawDayCell(day: day, maxTokens: display.maxTokens, rect: cell, showWeekday: true)
        }
    }

    private func drawMonth(in rect: NSRect) {
        let display = calendarDisplay()
        let grid = NSRect(x: rect.minX + 14, y: rect.minY + 14, width: rect.width - 28, height: 174)
        let cellWidth = grid.width / 7
        let cellHeight = grid.height / 6

        for index in 0..<7 {
            guard display.days.indices.contains(index) else { continue }
            drawText(
                display.days[index].weekday.uppercased(),
                rect: NSRect(x: grid.minX + CGFloat(index) * cellWidth, y: grid.maxY + 5, width: cellWidth, height: 12),
                size: 8,
                weight: .bold,
                color: NSColor.white.withAlphaComponent(0.36),
                alignment: .center
            )
        }

        for (index, day) in display.days.enumerated() {
            let column = index % 7
            let row = index / 7
            let x = grid.minX + CGFloat(column) * cellWidth
            let y = grid.maxY - CGFloat(row + 1) * cellHeight
            let cell = NSRect(x: x + 3, y: y + 3, width: cellWidth - 6, height: cellHeight - 6)
            drawDayCell(
                day: day,
                maxTokens: display.maxTokens,
                rect: cell,
                showWeekday: false
            )
        }
    }

    private func drawDayCell(
        day: UsageCalendarDay,
        maxTokens: Int,
        rect: NSRect,
        showWeekday: Bool
    ) {
        let intensity = day.hasUsage ? max(0.18, min(0.82, Double(day.totalTokens) / Double(maxTokens))) : 0
        let fill: NSColor
        if day.hasUsage {
            fill = NSColor.systemBlue.withAlphaComponent(0.20 + intensity * 0.42)
        } else {
            fill = NSColor.white.withAlphaComponent(day.isCurrentMonth ? 0.045 : 0.018)
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        fill.setFill()
        path.fill()
        (day.isToday ? NSColor.systemBlue.withAlphaComponent(0.78) : NSColor.white.withAlphaComponent(0.06)).setStroke()
        path.lineWidth = day.isToday ? 1.2 : 1
        path.stroke()

        let primaryColor = NSColor.white.withAlphaComponent(day.isCurrentMonth ? 0.86 : 0.26)
        let secondaryColor = day.hasUsage
            ? NSColor.white.withAlphaComponent(day.isCurrentMonth ? 0.74 : 0.30)
            : NSColor.white.withAlphaComponent(day.isCurrentMonth ? 0.34 : 0.18)

        if showWeekday {
            drawText(
                day.weekday,
                rect: NSRect(x: rect.minX + 5, y: rect.maxY - 18, width: rect.width - 10, height: 12),
                size: 9,
                weight: .medium,
                color: secondaryColor,
                alignment: .center
            )
            drawText(
                "\(day.dayNumber)",
                rect: NSRect(x: rect.minX + 5, y: rect.maxY - 36, width: rect.width - 10, height: 16),
                size: 14,
                weight: .semibold,
                color: primaryColor,
                alignment: .center,
                monospacedDigits: true
            )
            drawText(
                day.hasUsage ? TokenUsageUIDisplay.compact(day.totalTokens) : "0",
                rect: NSRect(x: rect.minX + 4, y: rect.minY + 8, width: rect.width - 8, height: 13),
                size: 9,
                weight: .medium,
                color: secondaryColor,
                alignment: .center,
                monospacedDigits: true
            )
        } else {
            drawText(
                "\(day.dayNumber)",
                rect: NSRect(x: rect.minX + 4, y: rect.maxY - 17, width: rect.width - 8, height: 12),
                size: 9,
                weight: day.isToday ? .bold : .medium,
                color: primaryColor,
                alignment: .center,
                monospacedDigits: true
            )
            if day.hasUsage {
                drawText(
                    TokenUsageUIDisplay.compact(day.totalTokens),
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

    private func calendarDisplay() -> UsageCalendarDisplay {
        TokenUsageUIDisplay(statistics: statistics, calendarScope: scope, calendar: calendar).calendar
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
