import AppKit
import Foundation
import SwiftUI
import TokenUsageCore

@MainActor
final class TokenUsageViewModel: ObservableObject {
    @Published private(set) var statistics: TokenUsageStatistics = .empty
    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published var lastErrorMessage: String?

    private let engine: TokenUsageEngine
    private let launchAtLogin = LaunchAtLoginController()
    private var timer: Timer?

    init(engine: TokenUsageEngine = TokenUsageEngine()) {
        self.engine = engine
        self.launchAtLoginEnabled = launchAtLogin.isEnabled
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task(priority: .utility) { @MainActor in
                self?.refresh()
            }
        }
        timer?.tolerance = 1
    }

    var indicatorText: String {
        "Tokens: \(Self.compact(statistics.sessionTokens)) | Last 10: \(Self.compact(Int(statistics.last10PromptsAverage))) | \(statistics.status.rawValue)"
    }

    var statusSystemImage: String {
        switch statistics.status {
        case .ok:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .highUsage:
            return "flame"
        }
    }

    func refresh() {
        statistics = engine.refresh()
    }

    func openFullReport() {
        do {
            let url = engine.defaultReportURL()
            try engine.writeMarkdownReport(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func openUsageSource() {
        if let source = engine.activeSourceURL {
            NSWorkspace.shared.open(source)
        } else {
            NSWorkspace.shared.open(TokenUsageStore.defaultStateURL().deletingLastPathComponent())
        }
    }

    func resetSession() {
        do {
            statistics = try engine.resetSession()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func confirmResetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all token statistics?"
        alert.informativeText = "Existing numeric statistics will be cleared. Current source files will be marked as already seen so old usage is not imported again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                statistics = try engine.resetAllWithCurrentSourcesAsBaseline()
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "codex-token-report.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try engine.writeReportJSON(to: url)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLogin.setEnabled(enabled)
            launchAtLoginEnabled = launchAtLogin.isEnabled
        } catch {
            launchAtLoginEnabled = launchAtLogin.isEnabled
            showError(error.localizedDescription)
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        lastErrorMessage = message
        let alert = NSAlert()
        alert.messageText = "Token monitor error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.0fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }
}
