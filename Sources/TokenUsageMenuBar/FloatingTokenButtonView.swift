import AppKit
import TokenUsageCore

@MainActor
protocol FloatingTokenButtonViewDelegate: AnyObject {
    func floatingTokenButtonDidClick(_ view: FloatingTokenButtonView)
    func floatingTokenButton(_ view: FloatingTokenButtonView, didMovePanelBy delta: NSSize)
    func floatingTokenButtonDidFinishMoving(_ view: FloatingTokenButtonView)
}

@MainActor
final class FloatingTokenButtonView: NSView {
    weak var delegate: FloatingTokenButtonViewDelegate?

    var title: String = "Tok" {
        didSet { needsDisplay = true }
    }

    var tokenText: String = "0" {
        didSet { needsDisplay = true }
    }

    var status: TokenUsageStatus = .ok {
        didSet { needsDisplay = true }
    }

    var permissionStatus: TokenUsageStatus = .ok {
        didSet { needsDisplay = true }
    }

    var isAPIKeyUnlocked: Bool = false {
        didSet { needsDisplay = true }
    }

    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Open Codex Token Monitor"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        toolTip = "Open Codex Token Monitor"
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = bounds.insetBy(dx: 1, dy: 1)
        drawBackground(in: bounds)
        drawStatusRail(in: bounds)
        drawText(in: bounds)
        drawBadges(in: bounds)
        drawHandle(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previousPoint = mouseDownPoint else { return }
        let point = event.locationInWindow
        let delta = NSSize(width: point.x - previousPoint.x, height: point.y - previousPoint.y)
        if abs(delta.width) > 2 || abs(delta.height) > 2 {
            didDrag = true
            delegate?.floatingTokenButton(self, didMovePanelBy: delta)
            mouseDownPoint = point
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            didDrag = false
        }

        if didDrag {
            delegate?.floatingTokenButtonDidFinishMoving(self)
        } else {
            delegate?.floatingTokenButtonDidClick(self)
        }
    }

    private func drawBackground(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 17, yRadius: 17)
        let gradient = NSGradient(colors: [
            NSColor(calibratedWhite: 0.18, alpha: 0.92),
            NSColor(calibratedWhite: 0.08, alpha: 0.92)
        ])
        gradient?.draw(in: path, angle: 90)

        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let topLine = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        NSColor.white.withAlphaComponent(0.10).setStroke()
        topLine.lineWidth = 1
        topLine.stroke()
    }

    private func drawStatusRail(in rect: NSRect) {
        let color = statusColor(status)
        let rail = NSBezierPath(
            roundedRect: NSRect(x: rect.minX + 10, y: rect.minY + 8, width: 5, height: rect.height - 16),
            xRadius: 2.5,
            yRadius: 2.5
        )
        color.withAlphaComponent(0.95).setFill()
        rail.fill()

        color.withAlphaComponent(0.20).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 6, y: rect.midY - 8, width: 16, height: 16)).fill()
    }

    private func drawText(in rect: NSRect) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.68)
        ]
        let tokenAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.white
        ]

        NSString(string: "TOK").draw(
            in: NSRect(x: rect.minX + 28, y: rect.minY + 20, width: 44, height: 15),
            withAttributes: titleAttrs
        )

        NSString(string: tokenText).draw(
            in: NSRect(x: rect.minX + 28, y: rect.minY + 4, width: 74, height: 22),
            withAttributes: tokenAttrs
        )
    }

    private func drawBadges(in rect: NSRect) {
        let statusLabel: String
        switch status {
        case .ok:
            statusLabel = "OK"
        case .warning:
            statusLabel = "WARN"
        case .highUsage:
            statusLabel = "HIGH"
        }

        drawBadge(
            text: statusLabel,
            color: statusColor(status),
            rect: NSRect(x: rect.maxX - 62, y: rect.minY + 18, width: 48, height: 18)
        )

        let securityText = isAPIKeyUnlocked ? "KEY" : "LOC"
        let securityColor = isAPIKeyUnlocked
            ? NSColor.systemBlue
            : NSColor.systemGray
        drawBadge(
            text: securityText,
            color: permissionStatus == .highUsage ? NSColor.systemRed : securityColor,
            rect: NSRect(x: rect.maxX - 62, y: rect.minY + 4, width: 48, height: 18)
        )
    }

    private func drawBadge(text: String, color: NSColor, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        color.withAlphaComponent(0.18).setFill()
        path.fill()
        color.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: color
        ]
        let size = NSString(string: text).size(withAttributes: attrs)
        NSString(string: text).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    private func drawHandle(in rect: NSRect) {
        let color = NSColor.white.withAlphaComponent(0.26)
        color.setFill()
        for index in 0..<3 {
            let y = rect.midY + CGFloat(index - 1) * 5
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 9, y: y - 1.5, width: 3, height: 3)).fill()
        }
    }

    private func statusColor(_ status: TokenUsageStatus) -> NSColor {
        switch status {
        case .ok:
            return NSColor.systemGreen
        case .warning:
            return NSColor.systemYellow
        case .highUsage:
            return NSColor.systemRed
        }
    }
}
