import AppKit
import TokenUsageCore

@MainActor
enum StatusBarIconRenderer {
    private static var cache: [String: NSImage] = [:]

    static func image(for status: TokenUsageStatus, permissionStatus: TokenUsageStatus) -> NSImage {
        let key = "\(status.rawValue)|\(permissionStatus.rawValue)"
        if let cached = cache[key] {
            return cached
        }

        let image = render(status: status, permissionStatus: permissionStatus)
        cache[key] = image
        return image
    }

    private static func render(status: TokenUsageStatus, permissionStatus: TokenUsageStatus) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.isTemplate = false
        image.lockFocus()

        NSGraphicsContext.current?.shouldAntialias = true
        NSGraphicsContext.current?.imageInterpolation = .high

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let severityColor = color(for: status)
        let permissionColor = color(for: permissionStatus)
        let center = NSPoint(x: 9.3, y: 8.8)
        let radius: CGFloat = 6.6

        drawSoftShadow(center: center, radius: radius)
        drawOrb(center: center, radius: radius, severityColor: severityColor)
        drawFractalOrbits(center: center, radius: radius, severityColor: severityColor, permissionColor: permissionColor)
        drawCore(center: center, severityColor: severityColor)
        drawMicroCrown(in: NSRect(x: 13.5, y: 11.4, width: 5.7, height: 4.7))

        image.unlockFocus()
        image.size = size
        return image
    }

    private static func drawSoftShadow(center: NSPoint, radius: CGFloat) {
        let shadow = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius - 1.4,
            y: center.y - radius - 2.0,
            width: (radius + 1.4) * 2,
            height: (radius + 1.0) * 2
        ))
        NSColor.black.withAlphaComponent(0.34).setFill()
        shadow.fill()
    }

    private static func drawOrb(center: NSPoint, radius: CGFloat, severityColor: NSColor) {
        let orbRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let orb = NSBezierPath(ovalIn: orbRect)
        NSGradient(colors: [
            severityColor.withAlphaComponent(0.88),
            NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.15, alpha: 0.95)
        ])?.draw(in: orb, angle: 132)

        NSColor.white.withAlphaComponent(0.34).setStroke()
        orb.lineWidth = 0.75
        orb.stroke()

        let highlight = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius * 0.48,
            y: center.y + radius * 0.10,
            width: radius * 0.78,
            height: radius * 0.50
        ))
        NSColor.white.withAlphaComponent(0.22).setFill()
        highlight.fill()
    }

    private static func drawFractalOrbits(
        center: NSPoint,
        radius: CGFloat,
        severityColor: NSColor,
        permissionColor: NSColor
    ) {
        drawRotatedOval(
            center: center,
            width: radius * 2.45,
            height: radius * 0.82,
            degrees: -28,
            color: severityColor.withAlphaComponent(0.86),
            lineWidth: 0.85
        )
        drawRotatedOval(
            center: center,
            width: radius * 2.10,
            height: radius * 0.74,
            degrees: 28,
            color: permissionColor.withAlphaComponent(0.70),
            lineWidth: 0.7
        )
        drawRotatedOval(
            center: center,
            width: radius * 1.50,
            height: radius * 0.54,
            degrees: 72,
            color: NSColor.white.withAlphaComponent(0.30),
            lineWidth: 0.55
        )

        for index in 0..<6 {
            let angle = CGFloat(index) * (.pi / 3)
            let point = NSPoint(
                x: center.x + cos(angle) * radius * 0.72,
                y: center.y + sin(angle) * radius * 0.72
            )
            let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 0.55, y: point.y - 0.55, width: 1.1, height: 1.1))
            NSColor.white.withAlphaComponent(index.isMultiple(of: 2) ? 0.42 : 0.22).setFill()
            dot.fill()
        }
    }

    private static func drawRotatedOval(
        center: NSPoint,
        width: CGFloat,
        height: CGFloat,
        degrees: CGFloat,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()

        let path = NSBezierPath(ovalIn: NSRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        ))
        color.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCore(center: NSPoint, severityColor: NSColor) {
        let core = NSBezierPath(ovalIn: NSRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2))
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.92),
            severityColor.withAlphaComponent(0.84)
        ])?.draw(in: core, angle: 110)
    }

    private static func drawMicroCrown(in rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.28))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.20, y: rect.maxY - rect.height * 0.12))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.48))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.58, y: rect.minY + rect.height * 0.48))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.80, y: rect.maxY - rect.height * 0.12))
        path.line(to: NSPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY + rect.height * 0.28))
        path.line(to: NSPoint(x: rect.maxX - rect.width * 0.14, y: rect.minY + rect.height * 0.06))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.06))
        path.close()

        NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.27, alpha: 1).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.30).setStroke()
        path.lineWidth = 0.35
        path.stroke()
    }

    private static func color(for status: TokenUsageStatus) -> NSColor {
        switch status {
        case .ok:
            return NSColor(calibratedRed: 0.32, green: 0.95, blue: 0.60, alpha: 1)
        case .warning:
            return NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.30, alpha: 1)
        case .highUsage:
            return NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.30, alpha: 1)
        }
    }
}
