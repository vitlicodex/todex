import AppKit
import TokenUsageCore

@MainActor
final class UsageLogExpandableMenuView: NSView {
    private let statistics: TokenUsageStatistics
    private let onScopeChange: (UsageCalendarScope) -> Void
    private var scope: UsageCalendarScope
    private var calendarView: UsageCalendarMenuView?
    private var trackingArea: NSTrackingArea?
    private var isExpanded = false

    private static let viewWidth: CGFloat = 372
    private static let collapsedHeight: CGFloat = 34
    private static let horizontalPadding: CGFloat = 18
    private static let lineHeight: CGFloat = 22
    private static let topLinePadding: CGFloat = 8
    private static let bottomLinePadding: CGFloat = 12
    private static let calendarBottomPadding: CGFloat = 8
    private static let separatorGap: CGFloat = 8

    init(
        statistics: TokenUsageStatistics,
        scope: UsageCalendarScope,
        onScopeChange: @escaping (UsageCalendarScope) -> Void
    ) {
        self.statistics = statistics
        self.scope = scope
        self.onScopeChange = onScopeChange
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.collapsedHeight))
    }

    required init?(coder: NSCoder) {
        self.statistics = .empty
        self.scope = .week
        self.onScopeChange = { _ in }
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextArea)
        trackingArea = nextArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        setExpanded(true)
    }

    override func mouseExited(with event: NSEvent) {
        setExpanded(false)
    }

    override func mouseDown(with event: NSEvent) {
        setExpanded(!isExpanded)
    }

    override func layout() {
        super.layout()
        layoutCalendar()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawRow()
        guard isExpanded else { return }
        drawUsageLines()
        drawSeparator()
    }

    private var usageLines: [String] {
        TokenUsageUIDisplay(statistics: statistics).usageLogLines
    }

    private var lineBlockHeight: CGFloat {
        Self.topLinePadding + CGFloat(usageLines.count) * Self.lineHeight + Self.bottomLinePadding
    }

    private var expandedHeight: CGFloat {
        let calendarHeight = calendarView?.frame.height ?? 0
        return Self.collapsedHeight
            + lineBlockHeight
            + calendarHeight
            + Self.calendarBottomPadding
            + Self.separatorGap
    }

    private var rowRect: NSRect {
        NSRect(x: 0, y: bounds.maxY - Self.collapsedHeight, width: bounds.width, height: Self.collapsedHeight)
    }

    private func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        resizeForCurrentState()
    }

    private func resizeForCurrentState() {
        if isExpanded {
            _ = ensureCalendarView()
        }
        let targetHeight = isExpanded ? expandedHeight : Self.collapsedHeight
        setFrameSize(NSSize(width: Self.viewWidth, height: targetHeight))
        calendarView?.isHidden = !isExpanded
        layoutCalendar()
        needsDisplay = true
        superview?.needsLayout = true
        updateTrackingAreas()
    }

    private func layoutCalendar() {
        guard let calendarView else { return }
        calendarView.frame.origin = NSPoint(x: 0, y: Self.calendarBottomPadding)
    }

    private func ensureCalendarView() -> UsageCalendarMenuView {
        if let calendarView {
            return calendarView
        }

        let view = UsageCalendarMenuView(statistics: statistics, scope: scope) { [weak self] nextScope in
            guard let self else { return }
            scope = nextScope
            onScopeChange(nextScope)
            resizeForCurrentState()
        }
        view.isHidden = !isExpanded
        addSubview(view)
        calendarView = view
        return view
    }

    private func drawRow() {
        let row = rowRect.insetBy(dx: 8, dy: 2)
        if isExpanded {
            let highlight = NSBezierPath(roundedRect: row, xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.setFill()
            highlight.fill()
        }

        let textColor = isExpanded ? NSColor.white : NSColor.labelColor
        drawText(
            "Usage Log",
            rect: NSRect(
                x: Self.horizontalPadding,
                y: rowRect.minY + 7,
                width: bounds.width - 62,
                height: 18
            ),
            size: 14,
            weight: .regular,
            color: textColor
        )
        drawChevron(
            expanded: isExpanded,
            rect: NSRect(x: bounds.maxX - 30, y: rowRect.minY + 10, width: 14, height: 14),
            color: textColor
        )
    }

    private func drawUsageLines() {
        let muted = NSColor.labelColor.withAlphaComponent(0.58)
        var y = rowRect.minY - Self.topLinePadding - Self.lineHeight
        for line in usageLines {
            drawText(
                line,
                rect: NSRect(
                    x: Self.horizontalPadding,
                    y: y,
                    width: bounds.width - Self.horizontalPadding * 2,
                    height: Self.lineHeight
                ),
                size: 11,
                weight: .medium,
                color: muted
            )
            y -= Self.lineHeight
        }
    }

    private func drawSeparator() {
        guard let calendarView else { return }
        let y = calendarView.frame.maxY + Self.separatorGap / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: Self.horizontalPadding, y: y))
        path.line(to: NSPoint(x: bounds.maxX - Self.horizontalPadding, y: y))
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawChevron(expanded: Bool, rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if expanded {
            path.move(to: NSPoint(x: rect.minX + 2, y: rect.midY + 2))
            path.line(to: NSPoint(x: rect.midX, y: rect.midY - 3))
            path.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY + 2))
        } else {
            path.move(to: NSPoint(x: rect.midX - 3, y: rect.minY + 2))
            path.line(to: NSPoint(x: rect.midX + 3, y: rect.midY))
            path.line(to: NSPoint(x: rect.midX - 3, y: rect.maxY - 2))
        }

        color.withAlphaComponent(0.92).setStroke()
        path.stroke()
    }

    private func drawText(
        _ text: String,
        rect: NSRect,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSString(string: text).draw(
            in: rect,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}
