import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let imageDir = root
    .appendingPathComponent("Documentation", isDirectory: true)
    .appendingPathComponent("Help", isDirectory: true)
    .appendingPathComponent("images", isDirectory: true)
try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

struct MenuRow {
    var title: String
    var detail: String?
    var isHeader: Bool = false
    var isAction: Bool = false
    var state: String? = nil
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func attributes(size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> [NSAttributedString.Key: Any] {
    [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
}

func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat = 15, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
    let rect = NSRect(x: x, y: y, width: width, height: size + 7)
    NSString(string: text).draw(in: rect, withAttributes: attributes(size: size, weight: weight, color: color))
}

func roundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

func saveImage(_ image: NSImage, name: String) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "generate-help-images", code: 1)
    }
    try png.write(to: imageDir.appendingPathComponent(name), options: .atomic)
}

func makeHelpImage(name: String, title: String, subtitle: String, rows: [MenuRow], footer: String) throws {
    let width: CGFloat = 900
    let rowStep: CGFloat = 38
    let height: CGFloat = max(780, CGFloat(rows.count) * rowStep + 340)
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()

    color(0x0f1419).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    roundedRect(NSRect(x: 34, y: height - 86, width: 226, height: 56), radius: 18, fill: color(0x20262d), stroke: color(0x6d7782))
    roundedRect(NSRect(x: 48, y: height - 73, width: 6, height: 30), radius: 3, fill: color(0xff453a))
    drawText("TOK", x: 68, y: height - 58, width: 48, size: 12, weight: .bold, color: color(0xbcc5cd))
    drawText("8.7m", x: 68, y: height - 78, width: 72, size: 18, weight: .semibold, color: .white)
    roundedRect(NSRect(x: 172, y: height - 62, width: 58, height: 22), radius: 11, fill: color(0xff453a, alpha: 0.16), stroke: color(0xff453a, alpha: 0.70))
    drawText("HIGH", x: 184, y: height - 57, width: 48, size: 10, weight: .bold, color: color(0xff7b72))

    roundedRect(NSRect(x: 34, y: 34, width: width - 68, height: height - 128), radius: 18, fill: color(0x171d22), stroke: color(0x59636d))
    drawText(title, x: 62, y: height - 128, width: width - 124, size: 24, weight: .semibold, color: .white)
    drawText(subtitle, x: 62, y: height - 156, width: width - 124, size: 14, color: color(0xaeb7c0))

    var y = height - 205
    for row in rows {
        if row.isHeader {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 62, y: y + 25))
            line.line(to: NSPoint(x: width - 62, y: y + 25))
            color(0x3a444d).setStroke()
            line.lineWidth = 1
            line.stroke()
            drawText(row.title, x: 62, y: y, width: 280, size: 14, weight: .semibold, color: color(0xaeb7c0))
        } else {
            let rowColor = row.isAction ? color(0xffffff) : color(0xd8dde2)
            drawText(row.title, x: 82, y: y, width: 380, size: 16, weight: row.isAction ? .semibold : .regular, color: rowColor)
            if let detail = row.detail {
                drawText(detail, x: 462, y: y, width: 330, size: 15, color: color(0xaeb7c0))
            }
            if let state = row.state {
                let badgeColor: NSColor = state.contains("HIGH") ? color(0xff453a) : (state.contains("WARN") ? color(0xffcc00) : color(0x32d74b))
                roundedRect(NSRect(x: width - 190, y: y - 2, width: 112, height: 25), radius: 12, fill: badgeColor.withAlphaComponent(0.18), stroke: badgeColor.withAlphaComponent(0.7))
                drawText(state, x: width - 172, y: y + 3, width: 92, size: 12, weight: .semibold, color: badgeColor)
            }
        }
        y -= rowStep
    }

    drawText(footer, x: 62, y: 56, width: width - 124, size: 13, color: color(0x89939d))
    image.unlockFocus()
    try saveImage(image, name: name)
}

try makeHelpImage(
    name: "menu-overview.png",
    title: "Main menu overview",
    subtitle: "Dashboard first, then the few sections you actually use.",
    rows: [
        MenuRow(title: "Top Dashboard", detail: "tokens, last 10, requests, cost", state: "HIGH"),
        MenuRow(title: "Sections", isHeader: true),
        MenuRow(title: "Overview", detail: "refresh, tokens, requests, averages"),
        MenuRow(title: "Reports & Data", detail: "safe report, export, raw source warning"),
        MenuRow(title: "Codex Permissions", detail: "approval, sandbox, filesystem, network"),
        MenuRow(title: "API Key & Security", detail: "unlock, lock, clear, clipboard"),
        MenuRow(title: "App Settings", detail: "launch at login"),
        MenuRow(title: "Advanced", detail: "feature switches, reset, diagnostics")
    ],
    footer: "The first level stays short; detailed numbers live inside Overview and Reports."
)

try makeHelpImage(
    name: "permissions.png",
    title: "Codex Permissions + policy bundles",
    subtitle: "Monitor current permissions, then set local allowed/disabled policy by bundle or rule.",
    rows: [
        MenuRow(title: "Monitoring", detail: "on"),
        MenuRow(title: "Status", detail: "disabled permission active", state: "HIGH RISK"),
        MenuRow(title: "Approval", detail: "never"),
        MenuRow(title: "Sandbox", detail: "danger-full-access"),
        MenuRow(title: "Filesystem", detail: "unrestricted or unknown"),
        MenuRow(title: "Network", detail: "enabled / unknown"),
        MenuRow(title: "Permission Preset", isHeader: true),
        MenuRow(title: "Level 1: Full Access", detail: "allow every detected permission"),
        MenuRow(title: "Level 2: Automation", detail: "workspace automation + network, no full filesystem"),
        MenuRow(title: "Level 3: Balanced", detail: "workspace edits, approval required, local only"),
        MenuRow(title: "Level 4: Guarded", detail: "workspace edits only, no trusted shortcuts"),
        MenuRow(title: "Level 5: Locked Down", detail: "monitoring only"),
        MenuRow(title: "Bundles And Rules", isHeader: true),
        MenuRow(title: "Programming", detail: "tools, code edits"),
        MenuRow(title: "File System", detail: "workspace writes, full filesystem"),
        MenuRow(title: "Network", detail: "external access"),
        MenuRow(title: "Automation", detail: "approval prompts, full-access mode"),
        MenuRow(title: "Secrets & Privacy", detail: "trusted workspaces, session metadata"),
        MenuRow(title: "Policy Actions", isHeader: true),
        MenuRow(title: "Refresh Permissions", isAction: true),
        MenuRow(title: "Open Codex Config", isAction: true),
        MenuRow(title: "Reset Permission Policy", isAction: true),
        MenuRow(title: "Disable Permission Monitoring", isAction: true)
    ],
    footer: "Unchecked permissions are disabled in local policy. The app reports violations; it does not silently rewrite Codex runtime permissions."
)

try makeHelpImage(
    name: "api-key-security.png",
    title: "API key security",
    subtitle: "The key is optional for Codex token counting and only needed for OpenAI Platform costs.",
    rows: [
        MenuRow(title: "Storage", detail: "local encrypted vault"),
        MenuRow(title: "Encryption", detail: "AES-GCM + PBKDF2-HMAC-SHA256"),
        MenuRow(title: "Unlock", detail: "16+ char password + Touch ID / Mac password"),
        MenuRow(title: "Memory", detail: "auto-lock after 10 minutes"),
        MenuRow(title: "Clipboard", detail: "cleared after matching paste"),
        MenuRow(title: "Reports", detail: "numeric stats only, no API key"),
        MenuRow(title: "Actions", isHeader: true),
        MenuRow(title: "Set OpenAI Admin API Key", isAction: true),
        MenuRow(title: "Unlock API Key", isAction: true),
        MenuRow(title: "Lock API Key", isAction: true),
        MenuRow(title: "Clear Stored API Key", isAction: true)
    ],
    footer: "Touch ID gates decrypt. It is not a magical shield against malware already running as your macOS user."
)

try makeHelpImage(
    name: "data-flow.png",
    title: "Data flow",
    subtitle: "The app keeps data local and stores only numeric usage statistics.",
    rows: [
        MenuRow(title: "1. Codex session logs", detail: "read token_count lines only"),
        MenuRow(title: "2. Token parser", detail: "extracts input/output/total numbers"),
        MenuRow(title: "3. Local stats store", detail: "~/Library/Application Support/CodexTokenMenuBar"),
        MenuRow(title: "4. Menu bar", detail: "Tok 8.7m HIGH"),
        MenuRow(title: "5. Optional API", detail: "OpenAI organization costs only"),
        MenuRow(title: "Privacy", isHeader: true),
        MenuRow(title: "No prompt contents stored", detail: "reports are numeric"),
        MenuRow(title: "No telemetry sent out", detail: "local machine only"),
        MenuRow(title: "Raw logs warning", detail: "shown before opening JSONL")
    ],
    footer: "Use Open Full Token Report for a safer view than raw Codex session files."
)

print("Generated help images in \(imageDir.path)")
