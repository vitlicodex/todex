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
    private static let usageGreen = NSColor(calibratedRed: 0.30, green: 0.92, blue: 0.48, alpha: 1)
    private static let peakGold = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.24, alpha: 1)

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
            let cell = NSRect(x: x + 4, y: grid.minY + 2, width: cellWidth - 8, height: grid.height - 4)
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
            let cell = NSRect(x: x + 4, y: y + 4, width: cellWidth - 8, height: cellHeight - 8)
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
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)

        if day.hasUsage {
            Self.usageGreen.withAlphaComponent(0.13 + intensity * 0.24).setFill()
            path.fill()
        }

        let stroke: NSColor
        if day.isPeakUsageDay {
            stroke = Self.peakGold.withAlphaComponent(0.74)
        } else if day.isToday {
            stroke = Self.usageGreen.withAlphaComponent(0.70)
        } else if day.hasUsage {
            stroke = Self.usageGreen.withAlphaComponent(0.28)
        } else {
            stroke = NSColor.white.withAlphaComponent(day.isCurrentMonth ? 0.045 : 0.020)
        }
        stroke.setStroke()
        path.lineWidth = day.isToday || day.isPeakUsageDay ? 1.2 : 1
        path.stroke()

        let primaryColor = day.hasUsage
            ? NSColor.white.withAlphaComponent(day.isCurrentMonth ? 0.88 : 0.32)
            : NSColor.white.withAlphaComponent(day.isCurrentMonth ? 0.42 : 0.18)
        let secondaryColor = day.hasUsage
            ? Self.usageGreen.withAlphaComponent(day.isCurrentMonth ? 0.94 : 0.42)
            : NSColor.white.withAlphaComponent(day.isCurrentMonth ? 0.24 : 0.12)

        if showWeekday {
            if day.isPeakUsageDay {
                drawPeakMarker(in: NSRect(x: rect.maxX - 18, y: rect.maxY - 18, width: 12, height: 12))
            }
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
            if day.hasUsage {
                drawText(
                    calendarTokenText(day.totalTokens),
                    rect: NSRect(x: rect.minX + 4, y: rect.minY + 8, width: rect.width - 8, height: 13),
                    size: 9,
                    weight: .semibold,
                    color: secondaryColor,
                    alignment: .center,
                    monospacedDigits: true
                )
            }
        } else {
            if day.isPeakUsageDay {
                drawPeakMarker(in: NSRect(x: rect.maxX - 15, y: rect.maxY - 14, width: 10, height: 10))
            }
            drawText(
                "\(day.dayNumber)",
                rect: NSRect(x: rect.minX + 4, y: rect.maxY - 15, width: rect.width - 8, height: 11),
                size: 8.5,
                weight: day.isToday ? .bold : .medium,
                color: primaryColor,
                alignment: .center,
                monospacedDigits: true
            )
            if day.hasUsage {
                drawText(
                    calendarTokenText(day.totalTokens),
                    rect: NSRect(x: rect.minX + 2, y: rect.minY + 2, width: rect.width - 4, height: 10),
                    size: 7.2,
                    weight: .semibold,
                    color: secondaryColor,
                    alignment: .center,
                    monospacedDigits: true
                )
            }
        }
    }

    private func drawPeakMarker(in rect: NSRect) {
        if let crown = NSImage(systemSymbolName: "crown.fill", accessibilityDescription: "Peak usage")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)) {
            crown.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.95)
            return
        }

        drawText(
            "*",
            rect: rect,
            size: rect.height,
            weight: .bold,
            color: Self.peakGold,
            alignment: .center
        )
    }

    private func calendarTokenText(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fb", Double(value) / 1_000_000_000.0)
        }
        if value >= 1_000_000 {
            return String(format: "%.0fm", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.0fk", Double(value) / 1_000.0)
        }
        return "\(value)"
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
