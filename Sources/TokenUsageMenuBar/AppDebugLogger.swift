import Foundation
import TokenUsageCore

enum AppDebugLogger {
    private static let maxLogBytes: UInt64 = 512 * 1024

    private static var logURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        return logs.appendingPathComponent("TODEX.log")
    }

    static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) \(redact(message))\n"

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: logURL.path) {
                rotateIfNeeded()
                let handle = try FileHandle(forWritingTo: logURL)
                defer {
                    try? handle.close()
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        } catch {
            // Logging must never affect the menu bar app itself.
        }
    }

    private static func redact(_ message: String) -> String {
        var output = message
        let patterns: [(String, String)] = [
            (#"sk-[A-Za-z0-9_\-]{8,}"#, "[REDACTED]"),
            (#"Bearer\s+[A-Za-z0-9_\-\.]+"#, "Bearer [REDACTED]"),
            (#"(?i)(OPENAI_API_KEY\s*=\s*)[^\s]+"#, "$1[REDACTED]"),
            (#"(?i)(api[_-]?key\s*[:=]\s*)[^\s,;]+"#, "$1[REDACTED]"),
            (#"(?i)(authorization\s*[:=]\s*)[^\s,;]+"#, "$1[REDACTED]")
        ]

        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return TokenReportPrivacy.redactSensitivePaths(in: output)
    }

    private static func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value > maxLogBytes else {
            return
        }
        let rotatedURL = logURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: logURL, to: rotatedURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotatedURL.path)
    }
}
