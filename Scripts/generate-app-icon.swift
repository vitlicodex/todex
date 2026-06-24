#!/usr/bin/env swift
import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetsURL = rootURL.appendingPathComponent("Assets/AppIcon", isDirectory: true)
let iconsetURL = assetsURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = assetsURL.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

struct IconOutput {
    let name: String
    let pixels: Int
}

let outputs: [IconOutput] = [
    IconOutput(name: "icon_16x16.png", pixels: 16),
    IconOutput(name: "icon_16x16@2x.png", pixels: 32),
    IconOutput(name: "icon_32x32.png", pixels: 32),
    IconOutput(name: "icon_32x32@2x.png", pixels: 64),
    IconOutput(name: "icon_128x128.png", pixels: 128),
    IconOutput(name: "icon_128x128@2x.png", pixels: 256),
    IconOutput(name: "icon_256x256.png", pixels: 256),
    IconOutput(name: "icon_256x256@2x.png", pixels: 512),
    IconOutput(name: "icon_512x512.png", pixels: 512),
    IconOutput(name: "icon_512x512@2x.png", pixels: 1024)
]

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func scaledRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) -> NSRect {
    NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
}

func drawText(
    _ text: String,
    in rect: NSRect,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    scale: CGFloat,
    alignment: NSTextAlignment = .center
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    let font = NSFont.monospacedSystemFont(ofSize: size * scale, weight: weight)
    NSString(string: text).draw(
        in: rect,
        withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    )
}

func drawCrown(in rect: NSRect, fill: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.25))
    path.line(to: NSPoint(x: rect.minX + rect.width * 0.20, y: rect.maxY - rect.height * 0.10))
    path.line(to: NSPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.46))
    path.line(to: NSPoint(x: rect.midX, y: rect.maxY - rect.height * 0.02))
    path.line(to: NSPoint(x: rect.minX + rect.width * 0.60, y: rect.minY + rect.height * 0.46))
    path.line(to: NSPoint(x: rect.minX + rect.width * 0.80, y: rect.maxY - rect.height * 0.10))
    path.line(to: NSPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY + rect.height * 0.25))
    path.line(to: NSPoint(x: rect.maxX - rect.width * 0.14, y: rect.minY + rect.height * 0.05))
    path.line(to: NSPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.05))
    path.close()

    fill.setFill()
    path.fill()
    color(0xfff2b2, alpha: 0.42).setStroke()
    path.lineWidth = max(0.7, rect.width * 0.025)
    path.stroke()
}

func drawWordmark(scale: CGFloat) {
    let primary = color(0xf6f8fb)
    let green = color(0x58f29a)
    let gold = color(0xf6c453)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 22 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    drawText(
        "T",
        in: scaledRect(198, 422, 108, 166, scale),
        size: 130,
        weight: .bold,
        color: primary,
        scale: scale,
        alignment: .left
    )
    drawText(
        "DEX",
        in: scaledRect(444, 422, 360, 166, scale),
        size: 130,
        weight: .bold,
        color: primary,
        scale: scale,
        alignment: .left
    )

    let center = NSPoint(x: 376 * scale, y: 511 * scale)
    let radius: CGFloat = 58 * scale
    let ringRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let ring = NSBezierPath(ovalIn: ringRect)
    primary.setStroke()
    ring.lineWidth = max(2, 18 * scale)
    ring.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 215, endAngle: 318)
    green.setStroke()
    arc.lineWidth = max(2, 18 * scale)
    arc.lineCapStyle = .round
    arc.stroke()
    NSGraphicsContext.restoreGraphicsState()

    drawCrown(in: scaledRect(414, 565, 80, 58, scale), fill: gold)
}

func drawIcon(pixels: Int) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create icon bitmap."])
    }

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "IconGeneration", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create icon graphics context."])
    }

    let scale = CGFloat(pixels) / 1024
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.shouldAntialias = true

    NSColor.clear.setFill()
    bounds.fill()

    let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 48 * scale, dy: 48 * scale), xRadius: 218 * scale, yRadius: 218 * scale)
    NSGradient(colors: [
        color(0x27313d),
        color(0x101419)
    ])?.draw(in: outer, angle: 115)

    color(0xffffff, alpha: 0.16).setStroke()
    outer.lineWidth = max(1, 8 * scale)
    outer.stroke()

    let glow = NSBezierPath(ovalIn: scaledRect(384, 184, 520, 520, scale))
    color(0x58f29a, alpha: 0.10).setFill()
    glow.fill()

    let halo = NSBezierPath(ovalIn: scaledRect(262, 356, 500, 284, scale))
    color(0xffffff, alpha: 0.045).setFill()
    halo.fill()

    drawWordmark(scale: scale)

    let underline = NSBezierPath(roundedRect: scaledRect(278, 366, 470, 18, scale), xRadius: 9 * scale, yRadius: 9 * scale)
    NSGradient(colors: [
        color(0x58f29a, alpha: 0.92),
        color(0xf6c453, alpha: 0.90)
    ])?.draw(in: underline, angle: 0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not render PNG."])
    }
    try data.write(to: url, options: .atomic)
}

for output in outputs {
    let rep = try drawIcon(pixels: output.pixels)
    try writePNG(rep, to: iconsetURL.appendingPathComponent(output.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "IconGeneration", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed."])
}

print("Generated app icon at \(icnsURL.path)")
