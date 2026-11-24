import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let geminiService = QuotaService()
    private let chatGPTService = ChatGPTQuotaService()
    private var refreshTimer: Timer?

    private var selectedProvider: AIProvider {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: Self.selectedProviderKey)
            updateStatusBarFromState()
            rebuildMenu()
        }
    }

    private var snapshots: [AIProvider: QuotaSnapshot] = [:]
    private var errors: [AIProvider: String] = [:]
    private var isRefreshing = false

    private let isDemoMode: Bool
    private let isDebugMode: Bool

    private static let selectedProviderKey = "GeminiQuotaBar.selectedProvider"

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    override init() {
        self.isDemoMode = CommandLine.arguments.contains("--demo")
        self.isDebugMode = CommandLine.arguments.contains("--debug")
        if let saved = UserDefaults.standard.string(forKey: Self.selectedProviderKey),
           let provider = AIProvider(rawValue: saved) {
            self.selectedProvider = provider
        } else {
            self.selectedProvider = .gemini
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusBarFromState()
        rebuildMenu()

        if isDemoMode {
            snapshots[.gemini] = QuotaSnapshot(
                provider: .gemini,
                fiveHourRemaining: 0.82,
                weeklyRemaining: 0.64,
                fiveHourResetTime: Date().addingTimeInterval(3 * 3600 + 25 * 60),
                weeklyResetTime: Date().addingTimeInterval(4 * 86400 + 6 * 3600),
                groupName: "Gemini Models (Demo)",
                accountEmail: "gemini@example.com",
                accountPlan: "AI Pro",
                fetchedAt: Date()
            )
            snapshots[.chatgpt] = QuotaSnapshot(
                provider: .chatgpt,
                fiveHourRemaining: 0.45,
                weeklyRemaining: 0.78,
                fiveHourResetTime: Date().addingTimeInterval(2 * 3600 + 10 * 60),
                weeklyResetTime: Date().addingTimeInterval(5 * 86400 + 2 * 3600),
                groupName: "ChatGPT (Demo)",
                accountEmail: "chatgpt@example.com",
                accountPlan: "Plus",
                fetchedAt: Date()
            )
            updateStatusBarFromState()
            rebuildMenu()
        } else {
            refreshAllProviders()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAllProviders()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    @objc private func selectProviderClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = AIProvider(rawValue: raw) else {
            return
        }
        selectedProvider = provider
    }

    @objc private func refreshClicked() {
        refreshAllProviders()
    }

    @objc private func copyDebugLogClicked() {
        let combined = [
            "=== Active Provider: \(selectedProvider.displayName) ===",
            "--- Gemini ---",
            geminiService.lastDebugReport.text,
            "--- ChatGPT ---",
            chatGPTService.lastDebugReport.text
        ].joined(separator: "\n")

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(combined, forType: .string)
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshAllProviders() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task {
            defer { self.isRefreshing = false }
            await withTaskGroup(of: (AIProvider, Result<QuotaSnapshot, Error>).self) { group in
                group.addTask {
                    do {
                        return (.gemini, .success(try await self.geminiService.fetchQuota()))
                    } catch {
                        return (.gemini, .failure(error))
                    }
                }
                group.addTask {
                    do {
                        return (.chatgpt, .success(try await self.chatGPTService.fetchQuota()))
                    } catch {
                        return (.chatgpt, .failure(error))
                    }
                }

                for await (provider, result) in group {
                    switch result {
                    case .success(let snapshot):
                        self.snapshots[provider] = snapshot
                        self.errors[provider] = nil
                    case .failure(let error):
                        self.errors[provider] = error.localizedDescription
                    }
                }
            }

            self.updateStatusBarFromState()
            self.rebuildMenu()

            if self.isDebugMode {
                print(self.geminiService.lastDebugReport.text)
                print(self.chatGPTService.lastDebugReport.text)
            }
        }
    }

    private func updateStatusBarFromState() {
        guard let button = statusItem.button else { return }

        let snapshot = snapshots[selectedProvider]
        let fiveHour = snapshot?.fiveHourRemaining
        let weekly = snapshot?.weeklyRemaining

        button.image = MenuBarRenderer.renderBarsImage(
            provider: selectedProvider,
            fiveHour: fiveHour,
            weekly: weekly
        )
        button.imagePosition = .imageLeft

        let fiveStr = fiveHour.map { "\(Int((min(max($0, 0.0), 1.0) * 100.0).rounded()))%" } ?? "--%"
        let weekStr = weekly.map { "\(Int((min(max($0, 0.0), 1.0) * 100.0).rounded()))%" } ?? "--%"

        // Show % ONLY for 5h right next to the 2 stacked progress bars
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .baselineOffset: 0.5
        ]
        button.attributedTitle = NSAttributedString(string: " \(fiveStr)", attributes: attrs)
        button.toolTip = "\(selectedProvider.displayName) Quota\nFive Hour Remaining: \(fiveStr)\nWeekly Remaining: \(weekStr)"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Provider Switcher Section
        let switchHeader = NSMenuItem(title: "เลือกค่ายที่แสดงบน Menu Bar", action: nil, keyEquivalent: "")
        switchHeader.isEnabled = false
        menu.addItem(switchHeader)

        for provider in AIProvider.allCases {
            let pctSummary = snapshots[provider]?.fiveHourPercent.map { " (\($0)%)" } ?? ""
            let item = NSMenuItem(
                title: "\(provider.displayName)\(pctSummary)",
                action: #selector(selectProviderClicked(_:)),
                keyEquivalent: provider.keyEquivalent
            )
            item.target = self
            item.representedObject = provider.rawValue
            item.state = (provider == selectedProvider) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Active Provider Details
        let activeSnapshot = snapshots[selectedProvider]
        let activeError = errors[selectedProvider]

        var headerTitle = "\(selectedProvider.displayName) Quota"
        if let plan = activeSnapshot?.accountPlan, !plan.isEmpty {
            headerTitle += " (\(plan))"
        }
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if let email = activeSnapshot?.accountEmail, !email.isEmpty {
            let emailItem = NSMenuItem(title: email, action: nil, keyEquivalent: "")
            emailItem.isEnabled = false
            menu.addItem(emailItem)
        }

        // 5-Hour Limit Remaining
        let fivePct = activeSnapshot?.fiveHourPercent.map { "\($0)%" } ?? "--%"
        let fiveReset = formatResetSuffix(activeSnapshot?.fiveHourResetTime)
        let fiveItem = NSMenuItem(
            title: "5-Hour Remaining (แถบบน): \(fivePct)\(fiveReset)",
            action: nil,
            keyEquivalent: ""
        )
        fiveItem.isEnabled = false
        menu.addItem(fiveItem)

        // Weekly Limit Remaining
        let weeklyPct = activeSnapshot?.weeklyPercent.map { "\($0)%" } ?? "--%"
        let weeklyReset = formatResetSuffix(activeSnapshot?.weeklyResetTime)
        let weeklyItem = NSMenuItem(
            title: "Weekly Remaining (แถบล่าง): \(weeklyPct)\(weeklyReset)",
            action: nil,
            keyEquivalent: ""
        )
        weeklyItem.isEnabled = false
        menu.addItem(weeklyItem)

        menu.addItem(.separator())

        // Status / Last Updated
        if let error = activeError {
            let errItem = NSMenuItem(title: "⚠ \(error)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
        } else if let fetchedAt = activeSnapshot?.fetchedAt {
            let timeStr = Self.timeFormatter.string(from: fetchedAt)
            let updatedItem = NSMenuItem(title: "Updated at \(timeStr)", action: nil, keyEquivalent: "")
            updatedItem.isEnabled = false
            menu.addItem(updatedItem)
        } else {
            let loadingItem = NSMenuItem(title: "กำลังโหลดข้อมูล...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
        }

        menu.addItem(.separator())

        // Actions
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let debugItem = NSMenuItem(title: "Copy Debug Log", action: #selector(copyDebugLogClicked), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        let quitItem = NSMenuItem(title: "Quit GeminiQuotaBar", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func formatResetSuffix(_ date: Date?) -> String {
        guard let date else { return "" }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return " · Resetting" }

        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return " · \(days)d \(hours)h"
        } else if hours > 0 {
            return " · \(hours)h \(minutes)m"
        } else {
            return " · \(minutes)m"
        }
    }
}
