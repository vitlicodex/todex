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

func drawText(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, scale: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
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
        color(0x232832),
        color(0x101319)
    ])?.draw(in: outer, angle: 115)

    color(0xffffff, alpha: 0.16).setStroke()
    outer.lineWidth = max(1, 8 * scale)
    outer.stroke()

    let glow = NSBezierPath(ovalIn: scaledRect(376, 164, 512, 512, scale))
    color(0x42d392, alpha: 0.10).setFill()
    glow.fill()

    let rail = NSBezierPath(roundedRect: scaledRect(178, 198, 32, 628, scale), xRadius: 16 * scale, yRadius: 16 * scale)
    NSGradient(colors: [
        color(0x44d27f),
        color(0xf2b84b),
        color(0xff5a62)
    ])?.draw(in: rail, angle: 90)

    let railGlow = NSBezierPath(ovalIn: scaledRect(134, 438, 120, 120, scale))
    color(0x44d27f, alpha: 0.18).setFill()
    railGlow.fill()

    let card = NSBezierPath(roundedRect: scaledRect(260, 238, 584, 524, scale), xRadius: 72 * scale, yRadius: 72 * scale)
    color(0xffffff, alpha: 0.07).setFill()
    card.fill()
    color(0xffffff, alpha: 0.12).setStroke()
    card.lineWidth = max(1, 4 * scale)
    card.stroke()

    drawText(
        "Tok",
        in: scaledRect(282, 468, 540, 164, scale),
        size: 138,
        weight: .bold,
        color: .white,
        scale: scale
    )

    drawText(
        "124k",
        in: scaledRect(320, 356, 464, 92, scale),
        size: 72,
        weight: .semibold,
        color: color(0xb9c4cf),
        scale: scale
    )

    let bars: [(CGFloat, UInt32)] = [
        (86, 0x44d27f),
        (130, 0x44d27f),
        (188, 0xf2b84b),
        (252, 0xff5a62)
    ]
    for (index, item) in bars.enumerated() {
        let barWidth: CGFloat = 60
        let x = 334 + CGFloat(index) * 88
        let bar = NSBezierPath(
            roundedRect: scaledRect(x, 276, barWidth, item.0, scale),
            xRadius: 18 * scale,
            yRadius: 18 * scale
        )
        color(item.1, alpha: 0.90).setFill()
        bar.fill()
    }

    let shine = NSBezierPath(roundedRect: scaledRect(142, 730, 612, 108, scale), xRadius: 54 * scale, yRadius: 54 * scale)
    color(0xffffff, alpha: 0.075).setFill()
    shine.fill()

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
