import AppKit
import Foundation
import TokenUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TokenStatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDebugLogger.log("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)
        controller = TokenStatusController()
        controller?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDebugLogger.log("applicationWillTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
final class TokenStatusController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let worker = TokenRefreshWorker()
    private let permissionWorker = PermissionRefreshWorker()
    private let launchAtLogin = LaunchAtLoginController()
    private let settingsStore = MonitorSettingsStore()
    private let keyStore = APIKeyStore()
    private let helpWindowController = HelpWindowController()
    private var timer: Timer?
    private var refreshInFlight = false
    private var permissionRefreshInFlight = false
    private var statistics: TokenUsageStatistics = .empty
    private var permissionSnapshot: CodexPermissionSnapshot = .disabled
    private var lastPermissionSignature: String?
    private var lastPermissionRefreshAt: Date?
    private var lastButtonRenderSignature: String?
    private var lastMenuRenderSignature: String?
    private var usageCalendarScope: UsageCalendarScope = .week
    private var settings = MonitorSettings()
    private var startupWindow: NSWindow?
    private var apiKeyWindow: NSWindow?
    private var apiKeyField: NSSecureTextField?
    private var apiKeyPassphraseField: NSSecureTextField?
    private var apiKeyPassphraseConfirmField: NSSecureTextField?
    private var unlockedAPIKey: String?
    private var apiKeyUnlockedUntil: Date?
    private let apiUnlockDuration: TimeInterval = 10 * 60
    private let permissionRefreshThrottleSeconds: TimeInterval = 20

    func start() {
        settings = settingsStore.load()
        launchAtLogin.cleanupLegacyLogs()
        permissionSnapshot = pendingPermissionSnapshot()
        if let button = statusItem.button {
            button.title = "TODEX"
            button.image = nil
            button.imagePosition = .noImage
            button.toolTip = "TODEX"
            AppDebugLogger.log("status button created text=TODEX")
        } else {
            AppDebugLogger.log("status button missing")
        }

        statusItem.isVisible = true
        updateButton()
        rebuildMenu()
        showStartupWindow()
        loadCachedStatistics()
        refreshPermissionsAsync(logChanges: false, force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh()
        }

        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task(priority: .utility) { @MainActor in
                self?.refresh()
            }
        }
        timer?.tolerance = timerTolerance(for: settings.refreshIntervalSeconds)
    }

    @objc private func refresh() {
        refresh(force: false)
    }

    private func refresh(force: Bool) {
        guard !refreshInFlight else { return }
        expireUnlockedAPIKeyIfNeeded()

        if settings.isEnabled(.apiUsageSource),
           unlockedAPIKey == nil,
           !settings.isEnabled(.localFallback) {
            statistics = lockedOrMissingAPIKeyStatistics()
            updateButton()
            rebuildMenu()
            return
        }

        refreshInFlight = true
        AppDebugLogger.log(force ? "refresh queued force=true" : "refresh queued")

        let currentSettings = settings
        let currentAPIKey = unlockedAPIKey
        let worker = worker
        let shouldShowLocalBeforeAPI = currentSettings.isEnabled(.apiUsageSource)
            && currentSettings.isEnabled(.localFallback)
            && currentAPIKey != nil

        Task(priority: force ? .userInitiated : .utility) { [weak self] in
            if shouldShowLocalBeforeAPI {
                let localStatistics = await worker.localRefresh(force: force)
                await MainActor.run {
                    guard let self, self.refreshInFlight else { return }
                    self.statistics = localStatistics
                    self.updateButton()
                    self.rebuildMenu()
                    AppDebugLogger.log("local fallback rendered before api refresh todayTokens=\(localStatistics.primaryDisplayUsage.totalTokens) todayRequests=\(localStatistics.primaryDisplayUsage.requests) sessionTokens=\(localStatistics.sessionTokens)")
                }
            }

            let nextStatistics = await worker.refresh(
                settings: currentSettings,
                apiKey: currentAPIKey,
                force: force
            )
            await MainActor.run {
                guard let self else { return }
                self.statistics = nextStatistics
                self.refreshInFlight = false
                self.updateButton()
                self.rebuildMenu()
                self.refreshPermissionsAsync(logChanges: true, force: force)
                let issueText = nextStatistics.issues.map(\.message).joined(separator: " | ")
                AppDebugLogger.log("refresh finished todayTokens=\(nextStatistics.primaryDisplayUsage.totalTokens) todayRequests=\(nextStatistics.primaryDisplayUsage.requests) sessionTokens=\(nextStatistics.sessionTokens) sessionRequests=\(nextStatistics.requestCount) issues=\(nextStatistics.issues.count) \(issueText)")
            }
        }
    }

    private func loadCachedStatistics() {
        let worker = worker
        Task(priority: .utility) { [weak self] in
            let cachedStatistics = await worker.cachedLocalStatistics()
            await MainActor.run {
                guard let self, !self.refreshInFlight else { return }
                self.statistics = cachedStatistics
                self.updateButton()
                self.rebuildMenu()
                AppDebugLogger.log("cached statistics rendered todayTokens=\(cachedStatistics.primaryDisplayUsage.totalTokens) todayRequests=\(cachedStatistics.primaryDisplayUsage.requests) sessionTokens=\(cachedStatistics.sessionTokens)")
            }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }

        let display = TokenUsageUIDisplay(statistics: statistics, calendarScope: usageCalendarScope)
        let title = menuBarTitle()
        let tooltip = display.tooltipText
        let signature = buttonRenderSignature(title: title, tooltip: tooltip)
        guard signature != lastButtonRenderSignature else { return }
        lastButtonRenderSignature = signature

        statusItem.length = NSStatusItem.variableLength
        button.title = title
        button.image = nil
        button.imagePosition = .noImage
        button.toolTip = tooltip
        AppDebugLogger.log("status updated title=\(title) status=\(statistics.status.rawValue)")
    }

    private func rebuildMenu() {
        let signature = menuRenderSignature()
        guard signature != lastMenuRenderSignature else { return }
        lastMenuRenderSignature = signature

        let menu = NSMenu()
        menu.autoenablesItems = false

        addMenuHeader(to: menu)

        if !statistics.issues.isEmpty {
            menu.addItem(.separator())
            addDisabled("Issue: \(statistics.issues[0].message)", to: menu)
        }

        menu.addItem(.separator())
        addOverviewSubmenu(to: menu)
        addUsageLogSubmenu(to: menu)
        addReportsSubmenu(to: menu)
        addPermissionsSubmenu(to: menu)
        addAPIKeySecuritySubmenu(to: menu)
        addAppSettingsSubmenu(to: menu)
        addAdvancedSubmenu(to: menu)

        menu.addItem(.separator())
        addAction("Show Control Window", #selector(showControlWindow), to: menu)
        addAction("Help", #selector(openHelp), to: menu)
        addAction("Quit App", #selector(quit), to: menu)

        statusItem.menu = menu
    }

    private func buttonRenderSignature(title: String, tooltip: String) -> String {
        let display = TokenUsageUIDisplay(statistics: statistics, calendarScope: usageCalendarScope)
        return [
            title,
            tooltip,
            "\(display.calendar.scope.rawValue)",
            display.primaryTokenText,
            display.primaryRequestText,
            display.primaryStatus.rawValue,
            permissionSnapshot.status.rawValue,
            unlockedAPIKey == nil ? "locked" : "unlocked",
            keyStore.hasStoredKey() ? "stored-key" : "no-key"
        ].joined(separator: "|")
    }

    private func menuRenderSignature() -> String {
        [
            statisticsRenderSignature(),
            permissionMenuSignature(),
            settingsRenderSignature(),
            "launch:\(launchAtLogin.isEnabled)",
            "api:\(apiKeyStateSignature())"
        ].joined(separator: "||")
    }

    private func statisticsRenderSignature() -> String {
        [
            "\(statistics.currentSessionPrompts)",
            "\(statistics.totalPrompts)",
            "\(statistics.sessionTokens)",
            "\(statistics.totalTokens)",
            "\(statistics.inputTokens)",
            "\(statistics.outputTokens)",
            "\(statistics.cachedInputTokens)",
            "\(statistics.requestCount)",
            "\(Int(statistics.averageTokensPerPrompt))",
            "\(Int(statistics.last10PromptsAverage))",
            "\(statistics.peakPromptCost)",
            statistics.mode.rawValue,
            statistics.status.rawValue,
            statistics.dataSource ?? "none",
            statistics.activeSourcePath ?? "none",
            formatUSD(statistics.dailyCostUSD),
            formatUSD(statistics.monthlyCostUSD),
            formatBudget(),
            periodSignature(statistics.todayUsage),
            periodSignature(statistics.yesterdayUsage),
            periodSignature(statistics.currentWeekUsage),
            periodSignature(statistics.currentMonthUsage),
            statistics.recentDailyUsage.map(periodSignature).joined(separator: ","),
            usageCalendarScope.rawValue,
            statistics.issues.map(\.message).joined(separator: "\u{1f}")
        ].joined(separator: "|")
            + "|\(breakdownSignature(statistics.modelBreakdown))"
            + "|\(breakdownSignature(statistics.projectBreakdown))"
            + "|\(breakdownSignature(statistics.apiKeyBreakdown))"
            + "|\(breakdownSignature(statistics.todayProjectBreakdown))"
    }

    private func breakdownSignature(_ rows: [UsageBreakdown]) -> String {
        rows.prefix(5)
            .map { row in
                "\(row.label):\(row.inputTokens):\(row.outputTokens):\(row.cachedInputTokens):\(row.requests):\(row.costUSD ?? -1)"
            }
            .joined(separator: ",")
    }

    private func periodSignature(_ summary: UsagePeriodSummary) -> String {
        "\(summary.label):\(summary.inputTokens):\(summary.outputTokens):\(summary.totalTokens):\(summary.requests)"
    }

    private func permissionMenuSignature() -> String {
        [
            permissionSignature(permissionSnapshot),
            permissionSnapshot.statusReason,
            permissionSnapshot.issues.joined(separator: "\u{1f}"),
            permissionSnapshot.configSourcePath ?? "none",
            permissionSnapshot.sessionSourcePath ?? "none"
        ].joined(separator: "|")
    }

    private func settingsRenderSignature() -> String {
        let featureText = MonitorFeatureFlag.allCases
            .map { "\($0.rawValue)=\(settings.isEnabled($0))" }
            .joined(separator: ",")
        let bundleText = CodexPermissionBundle.allCases
            .map { "\($0.rawValue)=\(settings.isPermissionBundleAllowed($0))" }
            .joined(separator: ",")
        let ruleText = CodexPermissionRule.allCases
            .map { "\($0.rawValue)=\(settings.isPermissionRuleAllowed($0))" }
            .joined(separator: ",")
        return [
            featureText,
            settings.codexPermissionPreset?.rawValue ?? "custom",
            bundleText,
            ruleText,
            "\(settings.refreshIntervalSeconds)",
            "\(settings.monthlyBudgetUSD)"
        ].joined(separator: "|")
    }

    private func apiKeyStateSignature() -> String {
        if unlockedAPIKey != nil {
            return "unlocked:\(apiUnlockRemainingMinutes())"
        }
        return keyStore.hasStoredKey() ? "locked" : "missing"
    }

    private func addMenuHeader(to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = TokenMenuHeaderView(
            statistics: statistics,
            permissionSnapshot: permissionSnapshot,
            isAPIKeyUnlocked: unlockedAPIKey != nil,
            hasStoredAPIKey: keyStore.hasStoredKey()
        )
        menu.addItem(item)
    }

    private func addOverviewSubmenu(to menu: NSMenu) {
        addSubmenu("Overview", to: menu) { submenu in
            let display = TokenUsageUIDisplay(statistics: statistics, calendarScope: usageCalendarScope)
            addDisabled(display.overviewLines[0], to: submenu)
            addAction("Refresh Now", #selector(refreshNow), to: submenu)
            submenu.addItem(.separator())
            for line in display.overviewLines.dropFirst() {
                addDisabled(line, to: submenu)
            }
            submenu.addItem(.separator())
            addDisabled("Daily cost: \(formatUSD(statistics.dailyCostUSD))", to: submenu)
            addDisabled("Monthly cost: \(formatUSD(statistics.monthlyCostUSD))", to: submenu)
            addDisabled("Budget: \(formatBudget())", to: submenu)
        }
    }

    private func addUsageLogSubmenu(to menu: NSMenu) {
        let item = NSMenuItem(title: "Usage Log", action: nil, keyEquivalent: "")
        item.view = UsageLogExpandableMenuView(
            statistics: statistics,
            scope: usageCalendarScope
        ) { [weak self] scope in
            self?.usageCalendarScope = scope
            self?.lastMenuRenderSignature = nil
        }
        menu.addItem(item)
    }

    private func addReportsSubmenu(to menu: NSMenu) {
        addSubmenu("Reports & Data", to: menu) { submenu in
            addDisabled("Source: \(compactMenuText(statistics.dataSource ?? "not connected", maxLength: 34))", to: submenu)
            addSourceSummary(to: submenu)
            submenu.addItem(.separator())
            addAction("Open Full Token Report", #selector(openFullReport), to: submenu)
            addAction("Open Token Usage JSON/Log File", #selector(openUsageSource), to: submenu)
            addAction("Export Token Report...", #selector(exportReport), to: submenu)
            submenu.addItem(.separator())
            addBreakdown(title: "Models", rows: statistics.modelBreakdown, to: submenu)
            addBreakdown(title: "Projects", rows: statistics.projectBreakdown, to: submenu)
            addBreakdown(title: "API keys", rows: statistics.apiKeyBreakdown, to: submenu)
            if statistics.modelBreakdown.isEmpty,
               statistics.projectBreakdown.isEmpty,
               statistics.apiKeyBreakdown.isEmpty {
                addDisabled("No breakdown data yet", to: submenu)
            }
        }
    }

    private func addPermissionsSubmenu(to menu: NSMenu) {
        addSubmenu("Codex Permissions", to: menu) { submenu in
            addDisabled("Monitoring: \(permissionSnapshot.monitoringEnabled ? "on" : "off")", to: submenu)
            addDisabled("Preset: \(permissionPresetTitle())", to: submenu)
            addDisabled("Status: \(permissionStatusLabel(permissionSnapshot.status))", to: submenu)
            addDisabled("Reason: \(permissionSnapshot.statusReason)", to: submenu)
            if !permissionSnapshot.policyViolations.isEmpty {
                addDisabled("Violations: \(permissionSnapshot.policyViolations.count)", to: submenu)
            }
            submenu.addItem(.separator())
            addDisabled("Approval: \(permissionSnapshot.approvalPolicy ?? "unknown")", to: submenu)
            addDisabled("Sandbox: \(permissionSnapshot.sandboxPolicy ?? "unknown")", to: submenu)
            addDisabled("Filesystem: \(permissionSnapshot.fileSystemPolicy ?? "unknown")", to: submenu)
            addDisabled("Network: \(networkText(permissionSnapshot.networkAccess))", to: submenu)
            submenu.addItem(.separator())
            addPermissionPresetSubmenu(to: submenu)
            submenu.addItem(.separator())
            addPermissionBundleSubmenus(to: submenu)
            submenu.addItem(.separator())
            addAction("Refresh Permissions", #selector(refreshPermissionsNow), to: submenu)
            addAction("Open Codex Config", #selector(openCodexConfig), to: submenu)
            addAction("Reset Permission Policy", #selector(resetCodexPermissionPolicy), to: submenu)
            addAction(
                settings.isEnabled(.codexPermissionMonitoring) ? "Disable Permission Monitoring" : "Enable Permission Monitoring",
                #selector(togglePermissionMonitoring),
                to: submenu
            )
            if !permissionSnapshot.issues.isEmpty {
                submenu.addItem(.separator())
                for issue in permissionSnapshot.issues.prefix(5) {
                    addDisabled(issue, to: submenu)
                }
            }
        }
    }

    private func addPermissionPresetSubmenu(to menu: NSMenu) {
        addSubmenu("Permission Preset", to: menu) { submenu in
            for preset in CodexPermissionPreset.allCases {
                let item = NSMenuItem(
                    title: "Level \(preset.level): \(preset.title)",
                    action: #selector(applyCodexPermissionPreset(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = preset.rawValue
                item.state = settings.codexPermissionPreset == preset ? .on : .off
                submenu.addItem(item)
                addDisabled(preset.detail, to: submenu)
                if preset != CodexPermissionPreset.allCases.last {
                    submenu.addItem(.separator())
                }
            }
        }
    }

    private func addAPIKeySecuritySubmenu(to menu: NSMenu) {
        addSubmenu("API Key & Security", to: menu) { submenu in
            if unlockedAPIKey != nil {
                addDisabled("API key: unlocked in memory\(apiUnlockRemainingText())", to: submenu)
            } else if keyStore.hasStoredKey() {
                addDisabled("API key: locked", to: submenu)
            } else if settings.isEnabled(.apiUsageSource) {
                addDisabled("API key: missing", to: submenu)
            } else {
                addDisabled("API source: disabled", to: submenu)
            }
            submenu.addItem(.separator())
            addAction("Unlock API Key...", #selector(unlockAPIKey), to: submenu)
            addAction("Lock API Key", #selector(lockAPIKey), to: submenu)
            addAction("Set OpenAI Admin API Key...", #selector(setAPIKey), to: submenu)
            addAction("Use Clipboard Key for This Session", #selector(useClipboardKeyForSession), to: submenu)
            addAction("Clear Stored API Key", #selector(clearAPIKey), to: submenu)
        }
    }

    private func addAppSettingsSubmenu(to menu: NSMenu) {
        addSubmenu("App Settings", to: menu) { submenu in
            addToggle(
                "Launch at Login",
                isOn: launchAtLogin.isEnabled,
                action: #selector(toggleLaunchAtLogin),
                representedObject: "",
                to: submenu
            )
        }
    }

    private func addAdvancedSubmenu(to menu: NSMenu) {
        addSubmenu("Advanced", to: menu) { submenu in
            addFeatureSwitches(to: submenu)
            submenu.addItem(.separator())
            addAction("Reset Session Statistics", #selector(resetSession), to: submenu)
            addAction("Reset All Statistics...", #selector(resetAll), to: submenu)
            if !statistics.issues.isEmpty {
                submenu.addItem(.separator())
                addDisabled("Diagnostics", to: submenu)
                for issue in statistics.issues {
                    addDisabled(issue.message, to: submenu)
                }
            }
        }
    }

    private func addFeatureSwitches(to menu: NSMenu) {
        addDisabled("Feature Switches", to: menu)
        for feature in MonitorFeatureFlag.allCases where feature != .menuBarSpend {
            let item = NSMenuItem(title: feature.title, action: #selector(toggleFeature(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = feature.rawValue
            item.state = settings.isEnabled(feature) ? .on : .off
            menu.addItem(item)
        }
    }

    private func addDisabled(_ title: String, to menu: NSMenu, toolTip: String? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = toolTip
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func addSubmenu(_ title: String, to menu: NSMenu, build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        build(submenu)
        item.submenu = submenu
        menu.addItem(item)
    }

    private func addBreakdown(title: String, rows: [UsageBreakdown], to menu: NSMenu) {
        guard !rows.isEmpty else { return }
        menu.addItem(.separator())
        addDisabled(title, to: menu)
        for row in rows.prefix(5) {
            let cost = row.costUSD.map { " · \(formatUSD($0))" } ?? ""
            let label = compactMenuText(row.label, maxLength: 28)
            addDisabled("\(label): \(Self.compact(row.totalTokens)) tok · \(row.requests) req\(cost)", to: menu, toolTip: row.label)
        }
    }

    private func periodLine(_ summary: UsagePeriodSummary) -> String {
        "\(summary.label): \(Self.compact(summary.totalTokens)) tok · \(summary.requests) req · in \(Self.compact(summary.inputTokens)) / out \(Self.compact(summary.outputTokens))"
    }

    private func projectLine(_ row: UsageBreakdown) -> String {
        "\(compactMenuText(row.label, maxLength: 28)): \(Self.compact(row.totalTokens)) tok · \(row.requests) req"
    }

    private func addSourceSummary(to menu: NSMenu) {
        guard let activeSourcePath = statistics.activeSourcePath, !activeSourcePath.isEmpty else {
            addDisabled("File: none", to: menu)
            return
        }

        if activeSourcePath.hasPrefix("http://") || activeSourcePath.hasPrefix("https://") {
            addDisabled(
                "Endpoint: \(compactMenuText(activeSourcePath, maxLength: 48))",
                to: menu,
                toolTip: activeSourcePath
            )
            return
        }

        let sourceURL = URL(fileURLWithPath: activeSourcePath)
        let fileName = sourceURL.lastPathComponent.isEmpty ? "unknown" : sourceURL.lastPathComponent
        let folder = sourceURL.deletingLastPathComponent().path
        addDisabled(
            "File: \(compactMenuText(fileName, maxLength: 40))",
            to: menu,
            toolTip: activeSourcePath
        )
        addDisabled(
            "Folder: \(compactPath(folder, maxLength: 44))",
            to: menu,
            toolTip: activeSourcePath
        )
    }

    private func addPermissionBundleSubmenus(to menu: NSMenu) {
        addDisabled("Permission Bundles", to: menu)
        for bundle in CodexPermissionBundle.allCases {
            addSubmenu(bundle.title, to: menu) { submenu in
                let bundleAllowed = settings.isPermissionBundleAllowed(bundle)
                addToggle(
                    bundleAllowed ? "Bundle Allowed" : "Bundle Disabled",
                    isOn: bundleAllowed,
                    action: #selector(toggleCodexPermissionBundle(_:)),
                    representedObject: bundle.rawValue,
                    to: submenu
                )
                submenu.addItem(.separator())

                for rule in CodexPermissionRule.allCases where rule.bundle == bundle {
                    let allowed = settings.isPermissionRuleAllowed(rule)
                    let active = isPermissionRuleActive(rule)
                    let violation = permissionSnapshot.policyViolations.first { $0.rule == rule }
                    let title = "\(rule.title)\(active ? " · active" : "")"
                    addToggle(
                        title,
                        isOn: allowed,
                        action: #selector(toggleCodexPermissionRule(_:)),
                        representedObject: rule.rawValue,
                        to: submenu
                    )
                    addDisabled(rule.detail, to: submenu)
                    if let violation {
                        addDisabled("Violation: \(violation.detail)", to: submenu)
                    }
                    submenu.addItem(.separator())
                }
            }
        }
    }

    private func addToggle(
        _ title: String,
        isOn: Bool,
        action: Selector,
        representedObject: Any,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.state = isOn ? .on : .off
        menu.addItem(item)
    }

    @objc private func refreshNow() {
        refresh(force: true)
    }

    @objc private func openHelp() {
        helpWindowController.show()
    }

    @objc private func refreshPermissionsNow() {
        refreshPermissionsAsync(logChanges: true, force: true)
    }

    @objc private func togglePermissionMonitoring() {
        settings.toggle(.codexPermissionMonitoring)
        permissionSnapshot = pendingPermissionSnapshot()
        do {
            try settingsStore.save(settings)
            updateButton()
            rebuildMenu()
            refreshPermissionsAsync(logChanges: false, force: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func toggleCodexPermissionBundle(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let bundle = CodexPermissionBundle(rawValue: rawValue) else {
            return
        }

        settings.togglePermissionBundle(bundle)
        savePermissionPolicyAndRefresh()
    }

    @objc private func toggleCodexPermissionRule(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let rule = CodexPermissionRule(rawValue: rawValue) else {
            return
        }

        settings.togglePermissionRule(rule)
        savePermissionPolicyAndRefresh()
    }

    @objc private func applyCodexPermissionPreset(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = CodexPermissionPreset(rawValue: rawValue) else {
            return
        }

        settings.applyPermissionPreset(preset)
        savePermissionPolicyAndRefresh()
    }

    @objc private func resetCodexPermissionPolicy() {
        settings.resetPermissionPolicy()
        savePermissionPolicyAndRefresh()
    }

    private func savePermissionPolicyAndRefresh() {
        permissionSnapshot = pendingPermissionSnapshot()
        do {
            try settingsStore.save(settings)
            updateButton()
            rebuildMenu()
            refreshPermissionsAsync(logChanges: true, force: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func openCodexConfig() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError("Codex config.toml was not found.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func unlockAPIKey() {
        guard let passphrase = promptForEncryptionPassword() else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                self.unlockedAPIKey = try await self.keyStore.readKeyWithTouchID(
                    reason: "Unlock OpenAI Admin API key for TODEX",
                    passphrase: passphrase
                )
                self.apiKeyUnlockedUntil = Date().addingTimeInterval(self.apiUnlockDuration)
                self.rebuildMenu()
                self.refresh(force: true)
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func lockAPIKey() {
        unlockedAPIKey = nil
        apiKeyUnlockedUntil = nil
        statistics = lockedOrMissingAPIKeyStatistics()
        updateButton()
        rebuildMenu()
    }

    @objc private func setAPIKey() {
        showAPIKeyWindow()
    }

    @objc private func pasteAPIKeyFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            showError("Clipboard does not contain text.")
            return
        }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyField?.stringValue = key
        clearClipboardIfMatches(key)
        apiKeyWindow?.makeFirstResponder(apiKeyField)
    }

    @objc private func useClipboardKeyForSession() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            showError("Clipboard does not contain text.")
            return
        }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        setUnlockedAPIKey(key)
        clearClipboardIfMatches(key)
        rebuildMenu()
        refresh(force: true)
    }

    @objc private func saveAPIKeyFromWindow() {
        let key = apiKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let passphrase = apiKeyPassphraseField?.stringValue ?? ""
        let confirm = apiKeyPassphraseConfirmField?.stringValue ?? ""
        guard !key.isEmpty else { return }
        guard !passphrase.isEmpty else {
            showError("Create a local encryption password before saving the API key.")
            return
        }
        guard passphrase == confirm else {
            showError("The local encryption passwords do not match.")
            return
        }

        do {
            try keyStore.saveKey(key, passphrase: passphrase)
            setUnlockedAPIKey(key)
            clearClipboardIfMatches(key)
            clearAPIKeyWindowFields()
            apiKeyWindow?.orderOut(nil)
            DispatchQueue.main.async { [weak self] in
                self?.refresh(force: true)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func clearAPIKey() {
        do {
            try keyStore.deleteKey()
            unlockedAPIKey = nil
            apiKeyUnlockedUntil = nil
            refresh(force: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func openFullReport() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = await self.worker.defaultReportURL()
                try await self.worker.writeMarkdownReport(to: url)
                NSWorkspace.shared.open(url)
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func openUsageSource() {
        Task { [weak self] in
            guard let self else { return }
            if let source = await self.worker.activeSourceURL() {
                guard self.confirmOpeningRawSource(source) else {
                    return
                }
                NSWorkspace.shared.open(source)
            } else {
                NSWorkspace.shared.open(TokenUsageStore.defaultStateURL().deletingLastPathComponent())
            }
        }
    }

    @objc private func resetSession() {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.statistics = try await self.worker.resetSession()
                self.updateButton()
                self.rebuildMenu()
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all token statistics?"
        alert.informativeText = "Existing numeric statistics will be cleared. Current source files will be marked as already seen so old usage is not imported again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                self.statistics = try await self.worker.resetAllWithCurrentSourcesAsBaseline()
                self.updateButton()
                self.rebuildMenu()
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "codex-token-report.json"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.worker.writeReportJSON(to: url)
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func showControlWindow() {
        showStartupWindow()
    }

    @objc private func openMenuFromControlWindow(_ sender: NSButton) {
        lastMenuRenderSignature = nil
        rebuildMenu()
        guard let menu = statusItem.menu else {
            showError("Menu is not ready yet. Try Refresh Now, then Open Menu again.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            rebuildMenu()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func toggleFeature(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let feature = MonitorFeatureFlag(rawValue: rawValue) else {
            return
        }
        settings.toggle(feature)
        do {
            try settingsStore.save(settings)
            restartTimer()
            rebuildMenu()
            refresh(force: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func quit() {
        unlockedAPIKey = nil
        apiKeyUnlockedUntil = nil
        clearAPIKeyWindowFields()
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "TODEX error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func compact(_ value: Int) -> String {
        if value >= 1_000_000_000_000 {
            return String(format: "%.1ft", Double(value) / 1_000_000_000_000.0)
        }
        if value >= 1_000_000_000 {
            return String(format: "%.1fb", Double(value) / 1_000_000_000.0)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.0fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    private func compactPath(_ path: String, maxLength: Int) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let abbreviated = path.hasPrefix(home)
            ? "~" + String(path.dropFirst(home.count))
            : path
        return compactMenuText(abbreviated, maxLength: maxLength)
    }

    private func compactMenuText(_ text: String, maxLength: Int) -> String {
        guard maxLength > 8, text.count > maxLength else {
            return text
        }

        let visibleCharacters = maxLength - 3
        let headCount = max(3, visibleCharacters / 2)
        let tailCount = max(3, visibleCharacters - headCount)
        return "\(text.prefix(headCount))...\(text.suffix(tailCount))"
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task(priority: .utility) { @MainActor in
                self?.refresh()
            }
        }
        timer?.tolerance = timerTolerance(for: settings.refreshIntervalSeconds)
    }

    private func timerTolerance(for interval: TimeInterval) -> TimeInterval {
        min(30, max(5, interval * 0.15))
    }

    private func menuBarTitle() -> String {
        "TODEX"
    }

    private func formatUSD(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return formatUSD(value)
    }

    private func formatUSD(_ value: Double) -> String {
        if value >= 1_000 {
            return String(format: "$%.1fk", value / 1_000)
        }
        if value >= 10 {
            return String(format: "$%.0f", value)
        }
        return String(format: "$%.2f", value)
    }

    private func formatBudget() -> String {
        guard let ratio = statistics.budgetUsedRatio else {
            return formatUSD(settings.monthlyBudgetUSD)
        }
        return "\(formatUSD(settings.monthlyBudgetUSD)) · \(Self.integer(ratio * 100))%"
    }

    private static func integer(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func pendingPermissionSnapshot() -> CodexPermissionSnapshot {
        guard settings.isEnabled(.codexPermissionMonitoring) else {
            return .disabled
        }

        return CodexPermissionSnapshot(
            monitoringEnabled: true,
            status: .ok,
            statusReason: "Permission scan is running in the background."
        )
    }

    private func refreshPermissionsAsync(logChanges: Bool, force: Bool = false) {
        let now = Date()
        guard !permissionRefreshInFlight else { return }
        if !force,
           let lastPermissionRefreshAt,
           now.timeIntervalSince(lastPermissionRefreshAt) < permissionRefreshThrottleSeconds {
            return
        }

        lastPermissionRefreshAt = now
        permissionRefreshInFlight = true

        let currentSettings = settings
        let worker = permissionWorker
        Task(priority: force ? .userInitiated : .utility) { [weak self] in
            let snapshot = await worker.snapshot(settings: currentSettings)
            await MainActor.run {
                guard let self else { return }
                self.permissionRefreshInFlight = false
                self.applyPermissionSnapshot(snapshot, logChanges: logChanges)
                self.updateButton()
                self.rebuildMenu()
            }
        }
    }

    private func applyPermissionSnapshot(_ snapshot: CodexPermissionSnapshot, logChanges: Bool) {
        permissionSnapshot = snapshot
        let signature = permissionSignature(snapshot)
        if lastPermissionSignature == nil {
            AppDebugLogger.log("codex permissions status=\(permissionStatusLabel(snapshot.status)) monitoring=\(snapshot.monitoringEnabled ? "on" : "off") approval=\(snapshot.approvalPolicy ?? "unknown") sandbox=\(snapshot.sandboxPolicy ?? "unknown") filesystem=\(snapshot.fileSystemPolicy ?? "unknown") network=\(networkText(snapshot.networkAccess))")
        } else if logChanges, let lastPermissionSignature, lastPermissionSignature != signature {
            AppDebugLogger.log("codex permissions changed status=\(permissionStatusLabel(snapshot.status)) approval=\(snapshot.approvalPolicy ?? "unknown") sandbox=\(snapshot.sandboxPolicy ?? "unknown") filesystem=\(snapshot.fileSystemPolicy ?? "unknown") network=\(networkText(snapshot.networkAccess))")
        }
        lastPermissionSignature = signature
    }

    private func isPermissionRuleActive(_ rule: CodexPermissionRule) -> Bool {
        let approval = permissionSnapshot.approvalPolicy?.lowercased() ?? ""
        let sandbox = permissionSnapshot.sandboxPolicy?.lowercased() ?? ""
        let profile = permissionSnapshot.permissionProfile?.lowercased() ?? ""
        let filesystem = permissionSnapshot.fileSystemPolicy?.lowercased() ?? ""

        switch rule {
        case .runWithoutApproval:
            return approval == "never"
        case .workspaceCodeWrite, .workspaceFileWrite:
            return sandbox == "workspace-write"
        case .fullFileSystemAccess:
            return profile == "disabled" || filesystem == "unrestricted" || sandbox == "danger-full-access"
        case .networkAccess:
            return permissionSnapshot.networkAccess == true
        case .unattendedAutomation:
            return approval == "never"
        case .fullAccessMode:
            return profile == "disabled" || sandbox == "danger-full-access"
        case .trustedWorkspaces:
            return permissionSnapshot.trustedWorkspaceCount > 0
        case .localSessionMetadataRead:
            return permissionSnapshot.monitoringEnabled
        }
    }

    private func permissionSignature(_ snapshot: CodexPermissionSnapshot) -> String {
        [
            snapshot.monitoringEnabled ? "on" : "off",
            snapshot.status.rawValue,
            snapshot.approvalPolicy ?? "unknown",
            snapshot.sandboxPolicy ?? "unknown",
            snapshot.permissionProfile ?? "unknown",
            snapshot.fileSystemPolicy ?? "unknown",
            networkText(snapshot.networkAccess),
            "\(snapshot.trustedWorkspaceCount)",
            "violations:\(snapshot.policyViolations.map { $0.rule.rawValue }.joined(separator: ","))"
        ].joined(separator: "|")
    }

    private func permissionStatusLabel(_ status: TokenUsageStatus) -> String {
        switch status {
        case .ok:
            return "OK"
        case .warning:
            return "WARNING"
        case .highUsage:
            return "HIGH RISK"
        }
    }

    private func permissionPresetTitle() -> String {
        guard let preset = settings.codexPermissionPreset else {
            return "Custom"
        }
        return "Level \(preset.level) · \(preset.title)"
    }

    private func networkText(_ value: Bool?) -> String {
        guard let value else { return "unknown" }
        return value ? "enabled" : "disabled"
    }

    private func setUnlockedAPIKey(_ key: String) {
        unlockedAPIKey = key
        apiKeyUnlockedUntil = Date().addingTimeInterval(apiUnlockDuration)
    }

    private func expireUnlockedAPIKeyIfNeeded() {
        guard let apiKeyUnlockedUntil,
              Date() >= apiKeyUnlockedUntil else {
            return
        }
        unlockedAPIKey = nil
        self.apiKeyUnlockedUntil = nil
        AppDebugLogger.log("api key auto-locked")
    }

    private func apiUnlockRemainingText() -> String {
        guard let apiKeyUnlockedUntil else {
            return ""
        }
        return " · auto-lock \(apiUnlockRemainingMinutes(until: apiKeyUnlockedUntil))m"
    }

    private func apiUnlockRemainingMinutes(until date: Date? = nil) -> Int {
        guard let date = date ?? apiKeyUnlockedUntil else {
            return 0
        }
        let seconds = max(0, date.timeIntervalSinceNow)
        return max(1, Int(ceil(seconds / 60)))
    }

    private func showStartupWindow() {
        if let window = startupWindow {
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 224),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "TODEX"
        window.center()

        let content = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 460, height: 224))
        content.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "TODEX is running")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 24, y: 172, width: 412, height: 22)
        content.addSubview(title)

        let body = NSTextField(labelWithString: "The main control is the “TODEX” item on the right side of the macOS menu bar. If macOS hides it, use Open Menu here. Closing this window keeps the monitor running in the background.")
        body.font = NSFont.systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 3
        body.frame = NSRect(x: 24, y: 112, width: 412, height: 48)
        content.addSubview(body)

        let openMenuButton = NSButton(title: "Open Menu", target: self, action: #selector(openMenuFromControlWindow(_:)))
        openMenuButton.keyEquivalent = "\r"
        openMenuButton.frame = NSRect(x: 24, y: 64, width: 112, height: 32)
        content.addSubview(openMenuButton)

        let keyButton = NSButton(title: "Set API Key", target: self, action: #selector(setAPIKey))
        keyButton.frame = NSRect(x: 148, y: 64, width: 112, height: 32)
        content.addSubview(keyButton)

        let helpButton = NSButton(title: "Help", target: self, action: #selector(openHelp))
        helpButton.frame = NSRect(x: 272, y: 64, width: 76, height: 32)
        content.addSubview(helpButton)

        let closeButton = NSButton(title: "Hide Window", target: window, action: #selector(NSWindow.close))
        closeButton.frame = NSRect(x: 24, y: 24, width: 112, height: 32)
        content.addSubview(closeButton)

        let quitButton = NSButton(title: "Quit App", target: self, action: #selector(quit))
        quitButton.frame = NSRect(x: 348, y: 24, width: 88, height: 32)
        content.addSubview(quitButton)

        window.contentView = content
        startupWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        AppDebugLogger.log("startup window shown")
    }

    private func showAPIKeyWindow() {
        if let window = apiKeyWindow {
            apiKeyField?.stringValue = ""
            apiKeyPassphraseField?.stringValue = ""
            apiKeyPassphraseConfirmField?.stringValue = ""
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(apiKeyField)
            AppDebugLogger.log("api key window reused")
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "Set OpenAI Admin API Key"
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 330))

        let title = NSTextField(labelWithString: "Paste the full secret key")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 24, y: 282, width: 452, height: 22)
        content.addSubview(title)

        let body = NSTextField(labelWithString: "The key is encrypted locally before it is written to disk. Unlocking later requires this password plus Touch ID or your Mac password.")
        body.font = NSFont.systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 2
        body.frame = NSRect(x: 24, y: 236, width: 452, height: 38)
        content.addSubview(body)

        let field = NSSecureTextField(frame: NSRect(x: 24, y: 198, width: 452, height: 28))
        field.placeholderString = "sk-admin-... or sk-proj-..."
        field.allowsEditingTextAttributes = false
        field.isEditable = true
        field.isSelectable = true
        content.addSubview(field)
        apiKeyField = field

        let passwordLabel = NSTextField(labelWithString: "Local encryption password")
        passwordLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        passwordLabel.frame = NSRect(x: 24, y: 166, width: 452, height: 18)
        content.addSubview(passwordLabel)

        let passwordField = NSSecureTextField(frame: NSRect(x: 24, y: 136, width: 452, height: 28))
        passwordField.placeholderString = "Used only on this Mac to decrypt the saved key"
        passwordField.allowsEditingTextAttributes = false
        passwordField.isEditable = true
        passwordField.isSelectable = true
        content.addSubview(passwordField)
        apiKeyPassphraseField = passwordField

        let confirmLabel = NSTextField(labelWithString: "Confirm local encryption password")
        confirmLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        confirmLabel.frame = NSRect(x: 24, y: 104, width: 452, height: 18)
        content.addSubview(confirmLabel)

        let confirmField = NSSecureTextField(frame: NSRect(x: 24, y: 74, width: 452, height: 28))
        confirmField.placeholderString = "Repeat password"
        confirmField.allowsEditingTextAttributes = false
        confirmField.isEditable = true
        confirmField.isSelectable = true
        content.addSubview(confirmField)
        apiKeyPassphraseConfirmField = confirmField

        let pasteButton = NSButton(title: "Paste from Clipboard", target: self, action: #selector(pasteAPIKeyFromClipboard))
        pasteButton.frame = NSRect(x: 24, y: 24, width: 150, height: 32)
        content.addSubview(pasteButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveAPIKeyFromWindow))
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 314, y: 24, width: 76, height: 32)
        content.addSubview(saveButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAPIKeyWindow))
        cancelButton.frame = NSRect(x: 402, y: 24, width: 74, height: 32)
        content.addSubview(cancelButton)

        window.contentView = content
        apiKeyWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        AppDebugLogger.log("api key window shown")
    }

    @objc private func cancelAPIKeyWindow() {
        clearAPIKeyWindowFields()
        apiKeyWindow?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === apiKeyWindow else {
            return
        }
        clearAPIKeyWindowFields()
    }

    private func promptForEncryptionPassword() -> String? {
        let alert = NSAlert()
        alert.messageText = "Unlock stored API key"
        alert.informativeText = "Enter the local encryption password you created when saving the key. Touch ID or your Mac password will be requested after this."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        field.placeholderString = "Local encryption password"
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let passphrase = field.stringValue
        guard !passphrase.isEmpty else {
            showError("Enter the local encryption password.")
            return nil
        }
        return passphrase
    }

    private func clearClipboardIfMatches(_ secret: String) {
        let normalizedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSecret.isEmpty,
              NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedSecret else {
            return
        }
        NSPasteboard.general.clearContents()
    }

    private func clearAPIKeyWindowFields() {
        apiKeyField?.stringValue = ""
        apiKeyPassphraseField?.stringValue = ""
        apiKeyPassphraseConfirmField?.stringValue = ""
    }

    private func confirmOpeningRawSource(_ source: URL) -> Bool {
        guard source.isFileURL else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Open raw token source?"
        alert.informativeText = "This source file can contain raw Codex session data, including prompt text. Token reports are safer because they contain numeric statistics only."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Raw File")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func lockedOrMissingAPIKeyStatistics() -> TokenUsageStatistics {
        var stats = TokenUsageStatistics.empty
        stats.mode = .api
        stats.status = .warning
        stats.dataSource = "OpenAI Usage API"
        stats.activeSourcePath = "https://api.openai.com/v1/organization/usage/completions"
        stats.issues = [keyStore.hasStoredKey() ? .apiKeyLocked : .apiKeyMissing]
        return stats
    }
}

private struct APICacheEntry {
    var signature: String
    var fetchedAt: Date
    var statistics: TokenUsageStatistics
}

actor PermissionRefreshWorker {
    private let monitor = CodexPermissionMonitor()

    func snapshot(settings: MonitorSettings) -> CodexPermissionSnapshot {
        monitor.snapshot(settings: settings)
    }
}

actor TokenRefreshWorker {
    private let localEngine = TokenUsageEngine()
    private let apiClient = OpenAIUsageClient()
    private var lastStatistics: TokenUsageStatistics = .empty
    private var apiCache: APICacheEntry?

    func localRefresh(force: Bool = false) -> TokenUsageStatistics {
        let statistics = localEngine.refresh(force: force)
        lastStatistics = statistics
        return statistics
    }

    func cachedLocalStatistics() -> TokenUsageStatistics {
        let statistics = localEngine.cachedStatistics()
        lastStatistics = statistics
        return statistics
    }

    func refresh(settings: MonitorSettings, apiKey: String?, force: Bool = false) async -> TokenUsageStatistics {
        if settings.isEnabled(.apiUsageSource) {
            if let apiKey, !apiKey.isEmpty {
                let apiStatistics = await apiStatistics(
                    apiKey: apiKey,
                    settings: settings,
                    force: force
                )
                if settings.isEnabled(.localFallback) {
                    let localStatistics = localEngine.refresh(force: force)
                    if shouldShowLocalStatistics(apiStatistics: apiStatistics, localStatistics: localStatistics) {
                        lastStatistics = merge(localStatistics: localStatistics, apiStatistics: apiStatistics)
                        return lastStatistics
                    }
                }

                lastStatistics = apiStatistics
                return lastStatistics
            }
            if !settings.isEnabled(.localFallback) {
                var stats = TokenUsageStatistics.empty
                stats.mode = .api
                stats.dataSource = "OpenAI Usage API"
                stats.activeSourcePath = "https://api.openai.com/v1/organization/usage/completions"
                stats.issues = [.apiKeyMissing]
                lastStatistics = stats
                return stats
            }
        }

        lastStatistics = localEngine.refresh(force: force)
        return lastStatistics
    }

    private func apiStatistics(
        apiKey: String,
        settings: MonitorSettings,
        force: Bool
    ) async -> TokenUsageStatistics {
        let signature = apiRequestSignature(apiKey: apiKey, settings: settings)
        let now = Date()
        if !force,
           let apiCache,
           apiCache.signature == signature,
           now.timeIntervalSince(apiCache.fetchedAt) < apiCacheTTL(settings: settings) {
            AppDebugLogger.log("api usage cache reused age=\(Int(now.timeIntervalSince(apiCache.fetchedAt)))s")
            return apiCache.statistics
        }

        let statistics = await apiClient.fetchStatistics(apiKey: apiKey, settings: settings, now: now)
        apiCache = APICacheEntry(signature: signature, fetchedAt: now, statistics: statistics)
        return statistics
    }

    private func apiCacheTTL(settings: MonitorSettings) -> TimeInterval {
        min(300, max(60, settings.refreshIntervalSeconds * 2))
    }

    private func apiRequestSignature(apiKey: String, settings: MonitorSettings) -> String {
        let relevantFeatures: [MonitorFeatureFlag] = [
            .costsEndpoint,
            .budgetAlerts,
            .modelBreakdown,
            .projectBreakdown,
            .apiKeyBreakdown
        ]
        let featureText = relevantFeatures
            .map { "\($0.rawValue)=\(settings.isEnabled($0))" }
            .joined(separator: ",")
        return [
            apiKeyFingerprint(apiKey),
            featureText,
            "budget=\(settings.monthlyBudgetUSD)"
        ].joined(separator: "|")
    }

    private func apiKeyFingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func shouldShowLocalStatistics(
        apiStatistics: TokenUsageStatistics,
        localStatistics: TokenUsageStatistics
    ) -> Bool {
        guard localStatistics.totalTokens > 0 || localStatistics.sessionTokens > 0 else {
            return false
        }

        if apiStatistics.totalTokens == 0 && apiStatistics.sessionTokens == 0 && apiStatistics.requestCount == 0 {
            return true
        }

        return !apiStatistics.issues.isEmpty
    }

    private func merge(
        localStatistics: TokenUsageStatistics,
        apiStatistics: TokenUsageStatistics
    ) -> TokenUsageStatistics {
        var merged = localStatistics
        merged.dailyCostUSD = apiStatistics.dailyCostUSD
        merged.monthlyCostUSD = apiStatistics.monthlyCostUSD
        merged.budgetUSD = apiStatistics.budgetUSD
        merged.budgetUsedRatio = apiStatistics.budgetUsedRatio
        merged.modelBreakdown = apiStatistics.modelBreakdown
        merged.projectBreakdown = apiStatistics.projectBreakdown
        merged.apiKeyBreakdown = apiStatistics.apiKeyBreakdown
        merged.dataSource = "Codex local session logs + OpenAI Usage API costs"
        merged.issues.append(contentsOf: apiStatistics.issues)
        if !apiStatistics.issues.isEmpty && merged.status == .ok {
            merged.status = .warning
        }
        return merged
    }

    func resetSession() throws -> TokenUsageStatistics {
        lastStatistics = try localEngine.resetSession()
        return lastStatistics
    }

    func resetAllWithCurrentSourcesAsBaseline() throws -> TokenUsageStatistics {
        lastStatistics = try localEngine.resetAllWithCurrentSourcesAsBaseline()
        return lastStatistics
    }

    func activeSourceURL() -> URL? {
        localEngine.activeSourceURL
    }

    func defaultReportURL() -> URL {
        localEngine.defaultReportURL()
    }

    func writeMarkdownReport(to url: URL) throws {
        let report = TokenUsageReport(
            generatedAt: Date(),
            sessionStartedAt: Date(),
            statistics: lastStatistics,
            numericSamples: []
        )
        let text = """
        # TODEX Usage Report

        Generated: \(Date())
        Source: \(lastStatistics.dataSource ?? "unknown")
        Mode: \(lastStatistics.mode.rawValue)
        Status: \(lastStatistics.status.rawValue)

        - Requests today: \(lastStatistics.primaryDisplayUsage.requests)
        - Tokens today: \(lastStatistics.primaryDisplayUsage.totalTokens)
        - Tokens month-to-date: \(lastStatistics.totalTokens)
        - Input tokens today: \(lastStatistics.primaryDisplayUsage.inputTokens)
        - Output tokens today: \(lastStatistics.primaryDisplayUsage.outputTokens)
        - Cached input tokens today: \(lastStatistics.cachedInputTokens)
        - Daily cost: \(lastStatistics.dailyCostUSD.map { String(format: "$%.4f", $0) } ?? "n/a")
        - Monthly cost: \(lastStatistics.monthlyCostUSD.map { String(format: "$%.4f", $0) } ?? "n/a")

        ## Usage Log

        - Today: \(lastStatistics.todayUsage.totalTokens) tokens, \(lastStatistics.todayUsage.requests) requests
        - Yesterday: \(lastStatistics.yesterdayUsage.totalTokens) tokens, \(lastStatistics.yesterdayUsage.requests) requests
        - This week: \(lastStatistics.currentWeekUsage.totalTokens) tokens, \(lastStatistics.currentWeekUsage.requests) requests
        - This month: \(lastStatistics.currentMonthUsage.totalTokens) tokens, \(lastStatistics.currentMonthUsage.requests) requests

        ## Daily History

        \(lastStatistics.recentDailyUsage.isEmpty ? "- No daily history yet" : lastStatistics.recentDailyUsage.map { "- \($0.label): \($0.totalTokens) tokens, \($0.requests) requests" }.joined(separator: "\n"))

        ## Codex Projects Today

        \(lastStatistics.todayProjectBreakdown.isEmpty ? "- No project metadata yet" : lastStatistics.todayProjectBreakdown.map { "- \($0.label): \($0.totalTokens) tokens, \($0.requests) requests" }.joined(separator: "\n"))

        This report contains numeric usage statistics and technical metadata only.
        """
        try PrivateFileIO.writePrivateString(text, to: url)
        _ = report
    }

    func writeReportJSON(to url: URL) throws {
        let report = TokenUsageReport(
            generatedAt: Date(),
            sessionStartedAt: Date(),
            statistics: lastStatistics,
            numericSamples: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try PrivateFileIO.writePrivateData(data, to: url)
    }
}
