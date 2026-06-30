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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showControlWindow()
        return true
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
    private var contextFindings: [ContextExplosionFinding] = []
    private var firewallAlerts: [SpendFirewallAlert] = []
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
            button.image = StatusBarIconRenderer.image(for: .ok, permissionStatus: permissionSnapshot.status)
            button.imagePosition = .imageLeading
            button.toolTip = "TODEX"
            AppDebugLogger.log("status button created text=TODEX image=fractal-orb")
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
                let localStatistics = await worker.localRefresh(settings: currentSettings, force: force)
                let localRiskSignals = await worker.latestRiskSignals()
                await MainActor.run {
                    guard let self, self.refreshInFlight else { return }
                    self.statistics = localStatistics
                    self.contextFindings = localRiskSignals.contextFindings
                    self.firewallAlerts = localRiskSignals.firewallAlerts
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
            let nextRiskSignals = await worker.latestRiskSignals()
            await MainActor.run {
                guard let self else { return }
                self.statistics = nextStatistics
                self.contextFindings = nextRiskSignals.contextFindings
                self.firewallAlerts = nextRiskSignals.firewallAlerts
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
            let cachedRiskSignals = await worker.latestRiskSignals()
            await MainActor.run {
                guard let self, !self.refreshInFlight else { return }
                self.statistics = cachedStatistics
                self.contextFindings = cachedRiskSignals.contextFindings
                self.firewallAlerts = cachedRiskSignals.firewallAlerts
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
        button.image = StatusBarIconRenderer.image(
            for: display.primaryStatus,
            permissionStatus: permissionSnapshot.status
        )
        button.imagePosition = .imageLeading
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
        addSpendFirewallSubmenu(to: menu)
        addReportsSubmenu(to: menu)
        addPermissionsSubmenu(to: menu)
        addSettingsSecuritySubmenu(to: menu)

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
            "fractal-status-icon-v1",
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
            formatUSD(statistics.estimatedLocalDailyCostUSD),
            formatUSD(statistics.estimatedLocalMonthlyCostUSD),
            statistics.estimatedLocalPricingProfileName ?? "none",
            formatBudget(),
            periodSignature(statistics.todayUsage),
            periodSignature(statistics.yesterdayUsage),
            periodSignature(statistics.currentWeekUsage),
            periodSignature(statistics.currentMonthUsage),
            statistics.recentDailyUsage.map(periodSignature).joined(separator: ","),
            usageCalendarScope.rawValue,
            statistics.issues.map(\.message).joined(separator: "\u{1f}"),
            firewallAlerts.map { "\($0.kind.rawValue):\($0.severity.rawValue):\($0.projectID ?? ""):\($0.projectName ?? "")" }.joined(separator: ","),
            contextFindings.map { "\($0.severity.rawValue):\($0.confidence.rawValue):\($0.projectID ?? ""):\(Int($0.recentInputPerRequest))" }.joined(separator: ",")
        ].joined(separator: "|")
            + "|\(breakdownSignature(statistics.modelBreakdown))"
            + "|\(breakdownSignature(statistics.projectBreakdown))"
            + "|\(breakdownSignature(statistics.apiKeyBreakdown))"
            + "|\(breakdownSignature(statistics.todayProjectBreakdown))"
    }

    private func breakdownSignature(_ rows: [UsageBreakdown]) -> String {
        rows.prefix(5)
            .map { row in
                "\(row.label):\(row.inputTokens):\(row.outputTokens):\(row.cachedInputTokens):\(row.requests):\(row.costUSD ?? -1):\(row.estimatedLocalCostUSD ?? -1)"
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
            "\(settings.monthlyBudgetUSD)",
            settings.localPricingProfile.id,
            settings.localPricingProfile.name,
            "\(settings.localPricingProfile.inputPerMillionUSD)",
            "\(settings.localPricingProfile.cachedInputPerMillionUSD)",
            "\(settings.localPricingProfile.outputPerMillionUSD)",
            "\(settings.localPricingProfile.reasoningPerMillionUSD)",
            "\(settings.localPricingProfile.multiplier)",
            settings.localPricingProfile.notes ?? "",
            "\(settings.spendFirewall.enabled)",
            "\(settings.spendFirewall.dailyEstimatedBudgetUSD)",
            "\(settings.spendFirewall.hourlyBurnWarningUSD)",
            "\(settings.spendFirewall.hourlyBurnCriticalUSD)",
            "\(settings.spendFirewall.alertCooldownMinutes)",
            "\(settings.contextExplosion.recentWindowCount)",
            "\(settings.contextExplosion.minimumBaselineCount)",
            "\(settings.contextExplosion.minimumRequestCount)",
            "\(settings.contextExplosion.minimumRecentTotalTokens)",
            "\(settings.contextExplosion.relativeSpikeMultiplier)",
            "\(settings.contextExplosion.inputDominanceShare)"
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
            usageCalendarScope: usageCalendarScope
        ) { [weak self] scope in
            self?.usageCalendarScope = scope
            self?.lastMenuRenderSignature = nil
        }
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
            addDisabled("Actual API daily cost: \(formatUSD(statistics.dailyCostUSD))", to: submenu)
            addDisabled("Actual API monthly cost: \(formatUSD(statistics.monthlyCostUSD))", to: submenu)
            addDisabled("Budget: \(formatBudget())", to: submenu)
        }
    }

    private func addSpendFirewallSubmenu(to menu: NSMenu) {
        addSubmenu("AI Spend Firewall", to: menu) { submenu in
            addDisabled("Status: \(firewallAlerts.isEmpty ? "No active alerts" : "\(firewallAlerts.count) alert(s)")", to: submenu)
            addDisabled("Estimated local today: \(formatUSD(statistics.estimatedLocalDailyCostUSD))", to: submenu)
            addDisabled("Estimated local month: \(formatUSD(statistics.estimatedLocalMonthlyCostUSD))", to: submenu)
            addDisabled("Actual API month: \(formatUSD(statistics.monthlyCostUSD))", to: submenu)
            addDisabled("Pricing profile: \(settings.localPricingProfile.name)", to: submenu)
            addDisabled("OpenAI Costs API may not include Codex desktop usage.", to: submenu)

            if !firewallAlerts.isEmpty {
                submenu.addItem(.separator())
                addDisabled("Alerts", to: submenu)
                for alert in firewallAlerts.prefix(5) {
                    addDisabled("\(firewallSeverityLabel(alert.severity)): \(alert.title)", to: submenu)
                    addDisabled(compactMenuText(alert.detail, maxLength: 54), to: submenu)
                    for evidence in alert.evidence.prefix(2) {
                        addDisabled("  \(compactMenuText(evidence, maxLength: 54))", to: submenu)
                    }
                }

                submenu.addItem(.separator())
                addDisabled("Action Center", to: submenu)
                addFirewallActionItems(to: submenu)
            }

            submenu.addItem(.separator())
            addFirewallCooldownSubmenu(to: submenu)
            submenu.addItem(.separator())
            addDisabled("Context findings: \(contextFindings.count)", to: submenu)
            for finding in contextFindings.prefix(3) {
                let project = finding.projectName.map { " · \($0)" } ?? ""
                addDisabled(
                    "\(firewallSeverityLabel(finding.severity)): \(finding.confidence.rawValue) · \(TokenUsageUIDisplay.compact(Int(finding.recentInputPerRequest))) input/req\(project)",
                    to: submenu
                )
            }
        }
    }

    private func addFirewallActionItems(to menu: NSMenu) {
        var seen: Set<SpendFirewallActionKind> = []
        let actions = firewallAlerts.flatMap(\.recommendedActionItems).filter { action in
            if seen.contains(action.kind) {
                return false
            }
            seen.insert(action.kind)
            return true
        }

        for action in actions {
            let title = action.requiresConfirmation ? "\(action.title)..." : action.title
            let item = NSMenuItem(title: title, action: #selector(performFirewallAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.kind.rawValue
            item.toolTip = action.detail
            menu.addItem(item)
        }

        if actions.contains(where: \.modifiesCodexConfig) {
            addDisabled("Codex Desktop may need restart after config changes.", to: menu)
        }
    }

    private func addFirewallCooldownSubmenu(to menu: NSMenu) {
        addSubmenu("Alert Cooldown", to: menu) { submenu in
            let options: [(String, Int)] = [
                ("Off", 0),
                ("5 minutes", 5),
                ("15 minutes", 15),
                ("60 minutes", 60)
            ]
            for option in options {
                let item = NSMenuItem(title: option.0, action: #selector(setFirewallCooldown(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = option.1
                item.state = settings.spendFirewall.alertCooldownMinutes == option.1 ? .on : .off
                submenu.addItem(item)
            }
        }
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
        addSubmenu("Codex Permission Monitor", to: menu) { submenu in
            addDisabled("Monitoring: \(permissionSnapshot.monitoringEnabled ? "on" : "off")", to: submenu)
            addDisabled("Control: alert policy only", to: submenu)
            addDisabled("Does not change the running session.", to: submenu)
            addDisabled("Config apply affects new CLI sessions.", to: submenu)
            addDisabled("Preset: \(permissionPresetTitle())", to: submenu)
            addDisabled("Status: \(permissionStatusLabel(permissionSnapshot.status))", to: submenu)
            addDisabled("Reason: \(permissionSnapshot.statusReason)", to: submenu)
            if !permissionSnapshot.policyViolations.isEmpty {
                addDisabled("Violations: \(permissionSnapshot.policyViolations.count)", to: submenu)
            }
            submenu.addItem(.separator())
            addDisabled("Detected Current Session", to: submenu)
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
            addAction("Apply Preset to Codex CLI Config...", #selector(applyPermissionPresetToCodexConfig), to: submenu)
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
        addSubmenu("Alert Policy Preset", to: menu) { submenu in
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

    private func addSettingsSecuritySubmenu(to menu: NSMenu) {
        addSubmenu("Settings & Security", to: menu) { submenu in
            addDisabled("API Key", to: submenu)
            addAPIKeySecurityItems(to: submenu)

            submenu.addItem(.separator())
            addDisabled("Estimated local Codex cost", to: submenu)
            addPricingProfileItems(to: submenu)

            submenu.addItem(.separator())
            addDisabled("App", to: submenu)
            addAppSettingsItems(to: submenu)

            submenu.addItem(.separator())
            addDisabled("Advanced", to: submenu)
            addAdvancedItems(to: submenu)
        }
    }

    private func addAPIKeySecurityItems(to menu: NSMenu) {
        if unlockedAPIKey != nil {
            addDisabled("API key: unlocked in memory\(apiUnlockRemainingText())", to: menu)
        } else if keyStore.hasStoredKey() {
            addDisabled("API key: locked", to: menu)
        } else if settings.isEnabled(.apiUsageSource) {
            addDisabled("API key: missing", to: menu)
        } else {
            addDisabled("API source: disabled", to: menu)
        }
        menu.addItem(.separator())
        addAction("Unlock API Key...", #selector(unlockAPIKey), to: menu)
        addAction("Lock API Key", #selector(lockAPIKey), to: menu)
        addAction("Set OpenAI Admin API Key...", #selector(setAPIKey), to: menu)
        addAction("Use Clipboard Key for This Session", #selector(useClipboardKeyForSession), to: menu)
        addAction("Clear Stored API Key", #selector(clearAPIKey), to: menu)
    }

    private func addAppSettingsItems(to menu: NSMenu) {
        addToggle(
            "Launch at Login",
            isOn: launchAtLogin.isEnabled,
            action: #selector(toggleLaunchAtLogin),
            representedObject: "",
            to: menu
        )
    }

    private func addPricingProfileItems(to menu: NSMenu) {
        addDisabled("Profile: \(settings.localPricingProfile.name)", to: menu)
        addDisabled(
            "Input \(formatPrice(settings.localPricingProfile.inputPerMillionUSD)) · cached \(formatPrice(settings.localPricingProfile.cachedInputPerMillionUSD)) · output \(formatPrice(settings.localPricingProfile.outputPerMillionUSD))",
            to: menu
        )
        addDisabled("Multiplier: \(Self.decimal(settings.localPricingProfile.multiplier))x", to: menu)
        addAction("Edit Pricing Profile...", #selector(editPricingProfile), to: menu)
        addSubmenu("Reset to Default Profile", to: menu) { submenu in
            for profile in TokenPricingProfile.defaultProfiles {
                let item = NSMenuItem(title: profile.name, action: #selector(resetPricingProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                item.state = settings.localPricingProfile.id == profile.id ? .on : .off
                submenu.addItem(item)
            }
        }
    }

    private func addAdvancedItems(to menu: NSMenu) {
        addFeatureSwitches(to: menu)
        menu.addItem(.separator())
        addAction("Reset Session Statistics", #selector(resetSession), to: menu)
        addAction("Reset All Statistics...", #selector(resetAll), to: menu)
        if !statistics.issues.isEmpty {
            menu.addItem(.separator())
            addDisabled("Diagnostics", to: menu)
            for issue in statistics.issues {
                addDisabled(issue.message, to: menu)
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
            let estimated = row.estimatedLocalCostUSD.map { " · est \(formatUSD($0))" } ?? ""
            let label = compactMenuText(row.label, maxLength: 28)
            addDisabled("\(label): \(Self.compact(row.totalTokens)) tok · \(row.requests) req\(cost)\(estimated)", to: menu, toolTip: row.label)
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
        let folder = TokenReportPrivacy.redactedPath(sourceURL.deletingLastPathComponent().path)
        let redactedSourcePath = TokenReportPrivacy.redactedPath(activeSourcePath)
        addDisabled(
            "File: \(compactMenuText(fileName, maxLength: 40))",
            to: menu,
            toolTip: redactedSourcePath
        )
        addDisabled(
            "Folder: \(compactPath(folder, maxLength: 44))",
            to: menu,
            toolTip: redactedSourcePath
        )
    }

    private func addPermissionBundleSubmenus(to menu: NSMenu) {
        addDisabled("Alert Policy Bundles", to: menu)
        for bundle in CodexPermissionBundle.allCases {
            addSubmenu(bundle.title, to: menu) { submenu in
                let bundleAllowed = settings.isPermissionBundleAllowed(bundle)
                addToggle(
                    bundleAllowed ? "Allowed by Alert Policy" : "Disabled by Alert Policy",
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

    @objc private func applyPermissionPresetToCodexConfig() {
        guard let preset = settings.codexPermissionPreset else {
            showError("Choose a numbered alert policy preset before applying it to Codex config.")
            return
        }

        let configuration = CodexPermissionConfigWriter.cliConfiguration(for: preset)
        let alert = NSAlert()
        alert.messageText = "Apply Level \(preset.level): \(preset.title) to Codex CLI config?"
        alert.informativeText = """
        This updates ~/.codex/config.toml:

        approval_policy = "\(configuration.approvalPolicy)"
        sandbox_mode = "\(configuration.sandboxMode)"
        [sandbox_workspace_write].network_access = \(configuration.workspaceWriteNetworkAccess)

        This affects new Codex CLI sessions after restart. It does not change this already-running Codex Desktop session.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let result = try CodexPermissionConfigWriter().applyPreset(preset)
            showInfo(
                """
                Codex CLI config was updated.

                Config: \(TokenReportPrivacy.redactedPath(result.configURL.path))
                Backup: \(result.backupURL.map { TokenReportPrivacy.redactedPath($0.path) } ?? "none")

                Start a new Codex session or restart Codex for the config value to be picked up. The current session can still show the old permissions until then.
                """
            )
            refreshPermissionsAsync(logChanges: true, force: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func applyCodexCLISafeMode() {
        let preset = CodexPermissionPreset.lockedDown
        let configuration = CodexPermissionConfigWriter.cliConfiguration(for: preset)
        let alert = NSAlert()
        alert.messageText = "Apply Codex CLI Safe Mode?"
        alert.informativeText = """
        This will apply Level \(preset.level): \(preset.title) to Codex CLI config after your confirmation:

        approval_policy = "\(configuration.approvalPolicy)"
        sandbox_mode = "\(configuration.sandboxMode)"
        [sandbox_workspace_write].network_access = \(configuration.workspaceWriteNetworkAccess)

        This affects new Codex CLI sessions after restart. It does not stop, pause, or control the running Codex Desktop session. Codex Desktop may need restart before it reflects new CLI config.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apply Safe Mode")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            settings.applyPermissionPreset(preset)
            try settingsStore.save(settings)
            let result = try CodexPermissionConfigWriter().applyPreset(preset)
            showInfo(
                """
                Codex CLI Safe Mode config was updated.

                Config: \(TokenReportPrivacy.redactedPath(result.configURL.path))
                Backup: \(result.backupURL.map { TokenReportPrivacy.redactedPath($0.path) } ?? "none")

                Start a new Codex session or restart Codex for the config value to be picked up.
                """
            )
            refreshPermissionsAsync(logChanges: true, force: true)
            rebuildMenu()
        } catch {
            showError(error.localizedDescription)
        }
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

    @objc func showControlWindow() {
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

    @objc private func hideControlWindow() {
        startupWindow?.orderOut(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            rebuildMenu()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func editPricingProfile() {
        let profile = settings.localPricingProfile
        let alert = NSAlert()
        alert.messageText = "Edit local cost profile"
        alert.informativeText = "Used only for estimated local Codex cost. Actual OpenAI billing stays separate."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let formView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 254))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        formView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: formView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: formView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: formView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: formView.bottomAnchor)
        ])

        let nameField = NSTextField(string: profile.name)
        let inputField = NSTextField(string: Self.decimal(profile.inputPerMillionUSD))
        let cachedField = NSTextField(string: Self.decimal(profile.cachedInputPerMillionUSD))
        let outputField = NSTextField(string: Self.decimal(profile.outputPerMillionUSD))
        let reasoningField = NSTextField(string: profile.reasoningPerMillionUSD == 0 ? "" : Self.decimal(profile.reasoningPerMillionUSD))
        let multiplierField = NSTextField(string: Self.decimal(profile.multiplier))
        let notesField = NSTextField(string: profile.notes ?? "")
        reasoningField.placeholderString = "optional"
        notesField.placeholderString = "optional"

        addFormRow("Profile name", field: nameField, to: stack)
        addFormRow("Input $ / 1M", field: inputField, to: stack)
        addFormRow("Cached input $ / 1M", field: cachedField, to: stack)
        addFormRow("Output $ / 1M", field: outputField, to: stack)
        addFormRow("Reasoning $ / 1M", field: reasoningField, to: stack)
        addFormRow("Multiplier", field: multiplierField, to: stack)
        addFormRow("Notes", field: notesField, to: stack)

        alert.accessoryView = formView
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let updated = TokenPricingProfile(
                id: profile.id,
                name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                inputPerMillionUSD: try parsePrice(inputField.stringValue, fieldName: "Input price"),
                cachedInputPerMillionUSD: try parsePrice(cachedField.stringValue, fieldName: "Cached input price"),
                outputPerMillionUSD: try parsePrice(outputField.stringValue, fieldName: "Output price"),
                reasoningPerMillionUSD: try parseOptionalPrice(reasoningField.stringValue, fieldName: "Reasoning price"),
                multiplier: try parsePrice(multiplierField.stringValue, fieldName: "Multiplier"),
                notes: notesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : notesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try settings.applyPricingProfile(updated)
            try settingsStore.save(settings)
            lastMenuRenderSignature = nil
            rebuildMenu()
            refresh(force: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func resetPricingProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? String else { return }
        settings.resetPricingProfile(to: profileID)
        do {
            try settingsStore.save(settings)
            lastMenuRenderSignature = nil
            rebuildMenu()
            refresh(force: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func performFirewallAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let kind = SpendFirewallActionKind(rawValue: rawValue) else {
            return
        }

        switch kind {
        case .openProjectSessionBreakdown:
            openFullReport()
        case .copyReduceContextPrompt:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SpendFirewallActionCatalog.reduceContextPrompt, forType: .string)
            showInfo("A generic reduce-context prompt was copied. It contains no prompt history, logs, API keys, or private paths.")
        case .suggestRestartOrCompactContext:
            showInfo(
                """
                Suggested non-destructive next step:

                1. Ask Codex to summarize current state.
                2. Start a fresh session or compact context manually.
                3. Re-open only the files needed for the next task.

                TODEX will not stop, pause, or control Codex automatically.
                """
            )
        case .switchTodexPolicyGuarded:
            settings.applyPermissionPreset(.guarded)
            savePermissionPolicyAndRefresh()
        case .switchTodexPolicyLockedDown:
            settings.applyPermissionPreset(.lockedDown)
            savePermissionPolicyAndRefresh()
        case .applyCodexCLISafeMode:
            applyCodexCLISafeMode()
        }
    }

    @objc private func setFirewallCooldown(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        settings.spendFirewall.alertCooldownMinutes = max(0, minutes)
        do {
            try settingsStore.save(settings)
            lastMenuRenderSignature = nil
            rebuildMenu()
            refresh(force: true)
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

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "TODEX"
        alert.informativeText = message
        alert.alertStyle = .informational
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

    private func formatPrice(_ value: Double) -> String {
        "$\(Self.decimal(value))/1M"
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

    private func firewallSeverityLabel(_ severity: SpendFirewallSeverity) -> String {
        switch severity {
        case .info:
            return "INFO"
        case .warning:
            return "WARNING"
        case .critical:
            return "CRITICAL"
        }
    }

    private static func integer(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private static func decimal(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.4f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private func addFormRow(_ title: String, field: NSTextField, to stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 176),
            field.widthAnchor.constraint(equalToConstant: 360)
        ])
        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        stack.addArrangedSubview(row)
    }

    private func parsePrice(_ raw: String, fieldName: String) throws -> Double {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else {
            throw NSError(domain: "TODEX", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(fieldName) must be a number."])
        }
        if value < 0 {
            throw NSError(domain: "TODEX", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(fieldName) cannot be negative."])
        }
        return value
    }

    private func parseOptionalPrice(_ raw: String, fieldName: String) throws -> Double {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return 0
        }
        return try parsePrice(text, fieldName: fieldName)
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
            presentControlWindow(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 166),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "TODEX"
        window.titleVisibility = .hidden
        window.collectionBehavior = [.moveToActiveSpace]

        let content = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 520, height: 166))
        content.autoresizingMask = [.width, .height]

        let iconView = NSImageView(frame: NSRect(x: 22, y: 94, width: 42, height: 42))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(iconView)

        let title = NSTextField(labelWithString: "TODEX is running")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 78, y: 118, width: 420, height: 22)
        content.addSubview(title)

        let body = NSTextField(labelWithString: "Use the TODEX menu bar item for status and controls. If macOS hides it, use Open Menu here. Closing or hiding this window keeps monitoring active.")
        body.font = NSFont.systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 2
        body.frame = NSRect(x: 78, y: 76, width: 420, height: 40)
        content.addSubview(body)

        let openMenuButton = NSButton(title: "Open Menu", target: self, action: #selector(openMenuFromControlWindow(_:)))
        openMenuButton.keyEquivalent = "\r"
        openMenuButton.frame = NSRect(x: 22, y: 24, width: 108, height: 30)
        content.addSubview(openMenuButton)

        let keyButton = NSButton(title: "Set API Key", target: self, action: #selector(setAPIKey))
        keyButton.frame = NSRect(x: 140, y: 24, width: 108, height: 30)
        content.addSubview(keyButton)

        let helpButton = NSButton(title: "Help", target: self, action: #selector(openHelp))
        helpButton.frame = NSRect(x: 258, y: 24, width: 70, height: 30)
        content.addSubview(helpButton)

        let hideButton = NSButton(title: "Hide", target: self, action: #selector(hideControlWindow))
        hideButton.frame = NSRect(x: 338, y: 24, width: 70, height: 30)
        content.addSubview(hideButton)

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.frame = NSRect(x: 418, y: 24, width: 80, height: 30)
        content.addSubview(quitButton)

        window.contentView = content
        startupWindow = window
        presentControlWindow(window)
        AppDebugLogger.log("startup window shown")
    }

    private func presentControlWindow(_ window: NSWindow) {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppDebugLogger.log("control window shown")
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

fileprivate struct TokenRiskSignals: Sendable {
    var contextFindings: [ContextExplosionFinding]
    var firewallAlerts: [SpendFirewallAlert]

    static let empty = TokenRiskSignals(contextFindings: [], firewallAlerts: [])
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
    private var lastRiskSignals: TokenRiskSignals = .empty
    private var apiCache: APICacheEntry?

    func localRefresh(settings: MonitorSettings = MonitorSettings(), force: Bool = false) -> TokenUsageStatistics {
        let statistics = localEngine.refresh(force: force, pricingProfile: settings.localPricingProfile)
        lastStatistics = statistics
        updateRiskSignals(statistics: statistics, settings: settings)
        return statistics
    }

    func cachedLocalStatistics() -> TokenUsageStatistics {
        let statistics = localEngine.cachedStatistics()
        lastStatistics = statistics
        return statistics
    }

    fileprivate func latestRiskSignals() -> TokenRiskSignals {
        lastRiskSignals
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
                    let localStatistics = localEngine.refresh(force: force, pricingProfile: settings.localPricingProfile)
                    if shouldShowLocalStatistics(apiStatistics: apiStatistics, localStatistics: localStatistics) {
                        lastStatistics = merge(localStatistics: localStatistics, apiStatistics: apiStatistics)
                        updateRiskSignals(statistics: lastStatistics, settings: settings)
                        return lastStatistics
                    }
                }

                lastStatistics = apiStatistics
                lastRiskSignals = .empty
                return lastStatistics
            }
            if !settings.isEnabled(.localFallback) {
                var stats = TokenUsageStatistics.empty
                stats.mode = .api
                stats.dataSource = "OpenAI Usage API"
                stats.activeSourcePath = "https://api.openai.com/v1/organization/usage/completions"
                stats.issues = [.apiKeyMissing]
                lastStatistics = stats
                lastRiskSignals = .empty
                return stats
            }
        }

        lastStatistics = localEngine.refresh(force: force, pricingProfile: settings.localPricingProfile)
        updateRiskSignals(statistics: lastStatistics, settings: settings)
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
            .apiKeyBreakdown,
            .estimatedLocalCost,
            .contextExplosionDetector,
            .spendFirewall
        ]
        let featureText = relevantFeatures
            .map { "\($0.rawValue)=\(settings.isEnabled($0))" }
            .joined(separator: ",")
        return [
            apiKeyFingerprint(apiKey),
            featureText,
            "budget=\(settings.monthlyBudgetUSD)",
            "pricing=\(settings.localPricingProfile.id):\(settings.localPricingProfile.name):\(settings.localPricingProfile.inputPerMillionUSD):\(settings.localPricingProfile.cachedInputPerMillionUSD):\(settings.localPricingProfile.outputPerMillionUSD):\(settings.localPricingProfile.reasoningPerMillionUSD):\(settings.localPricingProfile.multiplier)",
            "firewall=\(settings.spendFirewall.enabled):\(settings.spendFirewall.hourlyBurnWarningUSD):\(settings.spendFirewall.hourlyBurnCriticalUSD)"
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

    private func updateRiskSignals(statistics: TokenUsageStatistics, settings: MonitorSettings) {
        let samples = localEngine.numericSamples()
        let contextFindings = settings.isEnabled(.contextExplosionDetector)
            ? ContextExplosionDetector().detect(samples: samples, settings: settings)
            : []
        let firewallAlerts = SpendFirewallEvaluator().evaluate(
            snapshot: statistics,
            samples: samples,
            settings: settings,
            contextFindings: contextFindings,
            previousAlerts: lastRiskSignals.firewallAlerts
        )
        lastRiskSignals = TokenRiskSignals(
            contextFindings: contextFindings,
            firewallAlerts: firewallAlerts
        )
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
        let stats = lastStatistics.privacyRedactedForReport()
        let alerts = lastRiskSignals.firewallAlerts
        let firewallSection: String
        if alerts.isEmpty {
            firewallSection = "- No active firewall alerts"
        } else {
            firewallSection = alerts.prefix(5).map { alert in
                let evidence = alert.evidence.prefix(3).map { "  - Evidence: \($0)" }.joined(separator: "\n")
                let actions = alert.recommendedActionItems.prefix(5).map { "  - Action: \($0.title)\($0.requiresConfirmation ? " (requires confirmation)" : "")" }.joined(separator: "\n")
                return """
                - \(alert.severity.rawValue.uppercased()): \(alert.title)
                  - Detail: \(alert.detail)
                \(evidence.isEmpty ? "" : evidence)
                \(actions.isEmpty ? "" : actions)
                """
            }.joined(separator: "\n")
        }
        let text = """
        # TODEX Usage Report

        Generated: \(Date())
        Source: \(stats.dataSource ?? "unknown")
        Mode: \(stats.mode.rawValue)
        Status: \(stats.status.rawValue)

        - Requests today: \(stats.primaryDisplayUsage.requests)
        - Tokens today: \(stats.primaryDisplayUsage.totalTokens)
        - Tokens month-to-date: \(stats.totalTokens)
        - Average tokens per request today: \(TokenUsageUIDisplay.integer(TokenUsageUIDisplay.averageTokensPerRequest(stats.primaryDisplayUsage)))
        - Average tokens per request in current session: \(TokenUsageUIDisplay.integer(stats.averageTokensPerPrompt))
        - Input tokens today: \(stats.primaryDisplayUsage.inputTokens)
        - Output tokens today: \(stats.primaryDisplayUsage.outputTokens)
        - Cached input tokens today: \(stats.cachedInputTokens)
        - Actual OpenAI API daily cost: \(stats.dailyCostUSD.map { String(format: "$%.4f", $0) } ?? "n/a")
        - Actual OpenAI API monthly cost: \(stats.monthlyCostUSD.map { String(format: "$%.4f", $0) } ?? "n/a")
        - Estimated local Codex daily cost: \(stats.estimatedLocalDailyCostUSD.map { String(format: "$%.4f", $0) } ?? "n/a")
        - Estimated local Codex monthly cost: \(stats.estimatedLocalMonthlyCostUSD.map { String(format: "$%.4f", $0) } ?? "n/a")
        - Estimated local Codex pricing profile: \(stats.estimatedLocalPricingProfileName ?? "n/a")
        - Note: OpenAI Costs API may not include Codex desktop usage.

        ## Firewall Alerts

        \(firewallSection)

        ## Usage Log

        - Today: \(stats.todayUsage.totalTokens) tokens, \(stats.todayUsage.requests) requests
        - Yesterday: \(stats.yesterdayUsage.totalTokens) tokens, \(stats.yesterdayUsage.requests) requests
        - This week: \(stats.currentWeekUsage.totalTokens) tokens, \(stats.currentWeekUsage.requests) requests
        - This month: \(stats.currentMonthUsage.totalTokens) tokens, \(stats.currentMonthUsage.requests) requests

        ## Daily History

        \(stats.recentDailyUsage.isEmpty ? "- No daily history yet" : stats.recentDailyUsage.map { "- \($0.label): \($0.totalTokens) tokens, \($0.requests) requests" }.joined(separator: "\n"))

        ## Codex Projects Today

        \(stats.todayProjectBreakdown.isEmpty ? "- No project metadata yet" : stats.todayProjectBreakdown.map { "- \($0.label): \($0.totalTokens) tokens, \($0.requests) requests" }.joined(separator: "\n"))

        This report contains numeric usage statistics and technical metadata only.
        """
        try PrivateFileIO.writePrivateString(text, to: url)
    }

    func writeReportJSON(to url: URL) throws {
        let report = TokenUsageReport(
            generatedAt: Date(),
            sessionStartedAt: Date(),
            statistics: lastStatistics.privacyRedactedForReport(),
            numericSamples: []
        ).privacyRedactedForReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try PrivateFileIO.writePrivateData(data, to: url)
    }
}
