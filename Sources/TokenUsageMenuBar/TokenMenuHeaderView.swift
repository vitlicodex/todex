import AppKit
import TokenUsageCore

@MainActor
final class TokenMenuHeaderView: NSView {
    var statistics: TokenUsageStatistics
    var permissionSnapshot: CodexPermissionSnapshot
    var isAPIKeyUnlocked: Bool
    var hasStoredAPIKey: Bool

    init(
        statistics: TokenUsageStatistics,
        permissionSnapshot: CodexPermissionSnapshot,
        isAPIKeyUnlocked: Bool,
        hasStoredAPIKey: Bool
    ) {
        self.statistics = statistics
        self.permissionSnapshot = permissionSnapshot
        self.isAPIKeyUnlocked = isAPIKeyUnlocked
        self.hasStoredAPIKey = hasStoredAPIKey
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 154))
    }

    required init?(coder: NSCoder) {
        self.statistics = .empty
        self.permissionSnapshot = .disabled
        self.isAPIKeyUnlocked = false
        self.hasStoredAPIKey = false
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let card = bounds.insetBy(dx: 8, dy: 8)
        drawCard(in: card)
        drawHeader(in: card)
        drawMetrics(in: card)
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
        let display = TokenUsageUIDisplay(statistics: statistics)
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
        drawBadge(
            text: isAPIKeyUnlocked ? "KEY" : (hasStoredAPIKey ? "LOCK" : "LOCAL"),
            color: isAPIKeyUnlocked ? .systemBlue : .systemGray,
            rect: NSRect(x: rect.maxX - 94, y: rect.maxY - 78, width: 74, height: 23)
        )
    }

    private func drawMetrics(in rect: NSRect) {
        let display = TokenUsageUIDisplay(statistics: statistics)
        let y = rect.minY + 18
        let width = (rect.width - 56) / 3
        drawMetric(
            title: "LAST 10",
            value: display.last10PromptAverageText,
            rect: NSRect(x: rect.minX + 18, y: y, width: width, height: 45)
        )
        drawMetric(
            title: "REQUESTS",
            value: display.primaryRequestText,
            rect: NSRect(x: rect.minX + 28 + width, y: y, width: width, height: 45)
        )
        drawMetric(
            title: "COST",
            value: display.monthlyCostText,
            rect: NSRect(x: rect.minX + 38 + width * 2, y: y, width: width, height: 45)
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
            rect: NSRect(x: rect.minX + 10, y: rect.maxY - 19, width: rect.width - 20, height: 12),
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
