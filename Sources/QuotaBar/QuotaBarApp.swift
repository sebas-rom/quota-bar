import SwiftUI
import AppKit
import QuotaBarKit

// QuotaBar v0.4 — remembers what it sees.
//
// Menu bar: two percentages (unchanged).
// Popover: current windows, 24h trend, provenance and freshness.
// History: a real window with range charts over the local observation store.

private let appVersion = "0.12.0"

@MainActor
enum AppEnvironment {
    static let model: QuotaModel = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo") || args.contains("--render-evidence") {
            let store = try? TelemetryStore.inMemory()
            let model = QuotaModel(store: store, isDemo: true)
            DemoData.seed(model)
            return model
        }
        return QuotaModel.live()
    }()
}

@main
enum QuotaBarMain {
    static func main() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--status-json") {
            StatusCLI.run()
        }
        if args.contains("--advise-json") {
            AdviseCLI.run(arguments: args)
        }
        if args.contains("--codex-app-server-probe") {
            CodexProbeCLI.run()
        }
        if args.contains("--forecast-backtest") {
            ForecastBacktestCLI.run()
        }
        if args.contains("--render-evidence") {
            MainActor.assumeIsolated {
                _ = EvidenceRenderer.handleCommandLineIfRequested()
            }
            return
        }
        QuotaBarApp.main()
    }
}

struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppEnvironment.model
    @StateObject private var layout = ProviderLayoutStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, layout: layout)
        } label: {
            let caption = MenuBarComposition.text(
                style: layout.layout.menuBarStyle,
                layout: layout.layout,
                snapshots: model.snapshots,
                health: model.health
            )
            Label {
                Text(caption)
            } icon: {
                Image(nsImage: MenuBarIcon.image)
            }
            .accessibilityLabel(MenuBarComposition.accessibilityLabel(caption))
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--notification-diagnose") {
            Task { @MainActor in
                let report = await QuotaAlerter.shared.diagnose()
                print(report)
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 800_000_000)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        let model = AppEnvironment.model
        if ProcessInfo.processInfo.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if model.isDemo {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        if model.isDemo {
            DemoHost.shared.present(model: model, layout: ProviderLayoutStore())
            return
        }
        // Start Sparkle with the app so automatic checks do not depend on the
        // popover ever being opened.
        if let iconURL = Bundle.main.url(forResource: "QuotaBar", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }

        if ProcessInfo.processInfo.arguments.contains("--test-toast") {
            Task { @MainActor in
                AlertToast.shared.show("Test alert — Quota alerts are working.")
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        _ = UpdateController.shared
        model.onNetworkSnapshot = { snapshot in
            QuotaAlerter.shared.handle(snapshot)
        }
        model.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in await model.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.model.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var model: QuotaModel
    @ObservedObject var layout: ProviderLayoutStore
    @ObservedObject private var updates = UpdateController.shared
    @ObservedObject private var alerter = QuotaAlerter.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared
    @AppStorage("CompactCards") private var compactCards = true
    @AppStorage("AdvisorEnabled") private var advisorEnabled = false
    @AppStorage("AdvisorTaskMinutes") private var advisorTaskMinutes = 60
    /// Evidence snapshots render the content without presentation modifiers,
    /// which ImageRenderer cannot lay out reliably.
    var showsPresentation = true
    /// Evidence renders pin the card density so snapshots never inherit the
    /// developer's own preference.
    var compactOverride: Bool? = nil
    /// Evidence renders pin the advisor state too, so a screenshot never
    /// depends on the developer's own preferences.
    var advisorOverride: Bool? = nil
    var taskMinutesOverride: Int? = nil

    @State private var showKeyEntry = false
    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var validating = false
    @State private var showAbout = false
    @State private var confirmRemoveKey = false
    @State private var confirmClearHistory = false
    @State private var expandedProviders: Set<ProviderID> = []

    private var isCompact: Bool { compactOverride ?? compactCards }
    private var showAdvisor: Bool { advisorOverride ?? advisorEnabled }
    private var taskMinutes: Int { taskMinutesOverride ?? advisorTaskMinutes }

    private var visibleProviders: [ProviderID] {
        layout.layout.visible.filter {
            let presentation = model.presentation(for: $0)
            return presentation != .checking && presentation != .unconfigured
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openSetupInstructions() {
        if let url = URL(string: "https://github.com/sebas-rom/quota-bar/blob/main/INSTALL.md#setup") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSettings() {
        SettingsWindowController.shared.show(
            model: model,
            layout: layout,
            alerter: alerter,
            updates: updates,
            launchAtLogin: launchAtLogin
        )
    }

    private func recoveryAction(for provider: ProviderID) -> (() -> Void)? {
        let state = model.health[provider]?.state
        switch provider {
        case .go:
            return state == .authFailed || state == .entitlementMissing || state == .noCredentials
                ? { showKeyEntry = true } : nil
        case .codex:
            return state == .authFailed || state == .noCredentials
                ? { copyToPasteboard("codex login") } : nil
        case .commandCode:
            return state == .authFailed || state == .noCredentials
                ? { openSetupInstructions() } : nil
        }
    }

    private func recoveryTitle(for provider: ProviderID) -> String? {
        switch provider {
        case .go: return "Enter API key…"
        case .codex: return "Copy sign-in command"
        case .commandCode: return "Setup instructions"
        }
    }

    /// The heads-up row exists for information the cards cannot show: a hidden
    /// provider's warning, or a compact card whose meter is not the offending
    /// window. A warning already visible on a card is not repeated.
    private var headsUp: QuotaModel.HeadsUp? {
        guard let headsUp = model.headsUp else { return nil }
        let show = AttentionBanner.shouldShow(
            isHidden: layout.layout.hidden.contains(headsUp.provider),
            alertsEnabled: alerter.enabled && alerter.isEnabled(for: headsUp.provider),
            isCompact: isCompact,
            isExpanded: expandedProviders.contains(headsUp.provider),
            warnedWindowID: headsUp.window.id,
            limitingWindowID: model.snapshots[headsUp.provider]?.limiting?.id
        )
        return show ? headsUp : nil
    }

    private struct CardTrend {
        let points: [SamplePoint]
        let start: Date
        let end: Date
    }

    /// Trend for the window the card actually displays, never for a different
    /// window on the same provider.
    private func trend(for provider: ProviderID, window: QuotaWindow, now: Date = Date()) -> CardTrend? {
        if model.isRollingWindow(provider, window) {
            let start = now.addingTimeInterval(-5 * 3_600)
            let points = model.trailingSamples(for: provider, window: window, now: now)
            guard TrendCoverage.isMeaningful(points: points, frameStart: start, frameEnd: now) else { return nil }
            return CardTrend(points: points, start: start, end: now)
        }
        guard let cycle = model.cycleTrend(for: provider, window: window),
              TrendCoverage.isMeaningful(points: cycle.points, frameStart: cycle.cycle.start, frameEnd: cycle.cycle.end) else {
            return nil
        }
        return CardTrend(points: cycle.points, start: cycle.cycle.start, end: cycle.cycle.end)
    }

    private var needsScroll: Bool {
        visibleProviders.count + setupProviders.count > 3
    }

    private var maxStackHeight: CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 700) - 120
        return max(320, min(620, available))
    }

    var body: some View {
        if showsPresentation {
            content
                .sheet(isPresented: $showAbout) { aboutView }
                .confirmationDialog(
                    "Remove the saved Go API key?",
                    isPresented: $confirmRemoveKey,
                    titleVisibility: .visible
                ) {
                    Button("Remove Saved Go Key", role: .destructive) { model.forgetGoKey() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes only the key you entered in QuotaBar (stored in this Mac's Keychain). Your OpenCode and Codex credentials are untouched.")
                }
                .confirmationDialog(
                    "Delete local quota history?",
                    isPresented: $confirmClearHistory,
                    titleVisibility: .visible
                ) {
                    Button("Delete History", role: .destructive) { Task { await model.clearHistory() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes every stored observation on this Mac. Live percentages keep working; history restarts empty.")
                }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            if needsScroll {
                ScrollView { stack }
                    .frame(maxHeight: maxStackHeight)
            } else {
                stack
            }
            Divider()
            footer
        }
        .padding(Layout.outer)
        .frame(width: 320)
        // MenuBarExtra's vibrant material samples the wallpaper and can render
        // dark while the system is in light mode, leaving light-mode text on a
        // dark plate. An explicit system background follows the appearance.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var stack: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            if let headsUp {
                headsUpRow(headsUp)
            }
            // Advice is persisted evidence. Until every provider has answered
            // once in this launch (including a slow Go probe), a card can still
            // be "checking" or showing a local-log fallback while the row shows
            // last launch's decision. Wait for the whole pass.
            if showAdvisor, model.hasFullRefresh {
                AdvisorRow(
                    advice: model.advice(taskMinutes: taskMinutes),
                    taskMinutes: taskMinutes,
                    onSettings: openSettings
                )
            }
            ForEach(visibleProviders, id: \.self) { provider in
                let snapshot = model.snapshots[provider]
                let cardTrend = snapshot?.limiting.flatMap { trend(for: provider, window: $0) }
                ProviderCard(
                    provider: provider,
                    snapshot: snapshot,
                    health: model.health[provider],
                    trend: cardTrend?.points ?? [],
                    trendStart: cardTrend?.start,
                    trendEnd: cardTrend?.end,
                    freshness: model.staleness(for: provider),
                    onRecovery: recoveryAction(for: provider),
                    recoveryTitle: recoveryTitle(for: provider),
                    forecastFor: { window in
                        guard WindowSemantics.isForecastable(window: window) else { return nil }
                        let state = model.forecast(for: provider, window: window)
                        if showAdvisor,
                           let task = ForecastCopy.taskRiskLine(
                               for: state,
                               taskMinutes: taskMinutes,
                               rolling: model.isRollingWindow(provider, window)
                           ) {
                            return task
                        }
                        return ForecastCopy.riskLine(for: state)
                    },
                    compact: isCompact,
                    isExpanded: expandedProviders.contains(provider),
                    onToggleExpanded: { toggleExpanded(provider) }
                )
            }
            if !visibleProviders.isEmpty, layout.layout.hidden.isEmpty == false {
                HiddenNote(count: layout.layout.hidden.count, onSettings: openSettings)
            }
            if !setupProviders.isEmpty {
                SetupCard(
                    providers: setupProviders,
                    checking: Set(setupProviders.filter { model.presentation(for: $0) == .checking }),
                    hasConfigured: model.hasConfiguredProvider,
                    onEnterKey: { showKeyEntry = true }
                )
            }
            if showKeyEntry { keyEntry }
            if visibleProviders.isEmpty, setupProviders.isEmpty, !showKeyEntry {
                HiddenNote(count: layout.layout.hidden.count, isEmpty: true, onSettings: openSettings)
            }
        }
    }

    private func headsUpRow(_ headsUp: QuotaModel.HeadsUp) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: headsUp.isLimit ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(headsUp.text)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if layout.layout.hidden.contains(headsUp.provider) {
                    Button("Hidden in overview · Settings…") { openSettings() }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func toggleExpanded(_ provider: ProviderID) {
        if expandedProviders.contains(provider) {
            expandedProviders.remove(provider)
        } else {
            expandedProviders.insert(provider)
        }
    }

    private var setupProviders: [ProviderID] {
        layout.layout.visible.filter {
            let presentation = model.presentation(for: $0)
            return presentation == .checking || presentation == .unconfigured
        }
    }

    // MARK: footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label(model.refreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .disabled(model.refreshing)
            .help(model.refreshing ? "Refreshing…" : "Refresh now (⌘R)")
            .accessibilityLabel(model.refreshing ? "Refreshing" : "Refresh")

            Button("History…") {
                HistoryWindowController.shared.show(model: model, layout: layout)
            }
            .disabled(model.store == nil)

            Spacer()

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help("Settings…")
            .accessibilityLabel("Settings")

            if showsPresentation {
            Menu {
                Button("Settings…") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Show Credential Files") {
                    NSWorkspace.shared.open(homeDir().appendingPathComponent(".local/share/opencode"))
                    NSWorkspace.shared.open(homeDir().appendingPathComponent(".codex"))
                }
                if !model.isDemo, model.hasSavedGoKey {
                    Button("Remove Saved Go Key…") { confirmRemoveKey = true }
                }
                if model.store != nil {
                    Button("Clear History…") { confirmClearHistory = true }
                }
                Divider()
                Button("About QuotaBar") { showAbout = true }
                Button("Quit QuotaBar") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More actions")
            } else {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }

        HStack(spacing: 6) {
            if let last = model.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Last updated \(last.formatted(date: .omitted, time: .shortened))")
            } else if model.storeIssue == nil, !model.isDemo {
                Text("Starting…").font(.caption2).foregroundStyle(.secondary)
            }
            if model.isDemo {
                Text("Demo data")
                    .font(.caption2).fontWeight(.medium)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let issue = model.storeIssue ?? alerter.issue {
                Text(issue).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    // MARK: key entry

    @ViewBuilder
    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste your opencode Personal API key:").font(.caption).foregroundStyle(.secondary)
            SecureField("oc_sk_…", text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .disabled(validating)
            if let keyError {
                Text(keyError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(validating ? "Checking…" : "Save") {
                    validating = true
                    keyError = nil
                    Task {
                        let error = await model.validateAndSaveGoKey(keyInput)
                        validating = false
                        if let error {
                            keyError = error
                        } else {
                            keyInput = ""
                            showKeyEntry = false
                        }
                    }
                }
                .disabled(validating || keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                Button("Cancel") {
                    showKeyEntry = false
                    keyError = nil
                    keyInput = ""
                }
                .disabled(validating)
            }
        }
        .padding(Layout.card)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: about

    @ViewBuilder
    private var aboutView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QuotaBar \(appVersion)").font(.headline)
            Text("Every provider, one glance: current quota, cycle history, all local.")
                .foregroundStyle(.secondary)
            Divider()
            Text("Go: opencode.ai/zen/go/v1/usage").font(.caption).monospaced()
            Text("Codex: chatgpt.com/backend-api/wham/usage").font(.caption).monospaced()
            Text("Codex fallback: ~/.codex/sessions").font(.caption).monospaced()
            Text("Command Code: api.commandcode.ai/alpha/billing").font(.caption).monospaced()
            Text("Go key source: \(model.goKeySourceText)").font(.caption).foregroundStyle(.secondary)
            Text("History: 90 days of observations in ~/Library/Application Support/QuotaBar. No prompts, tokens or account identities are stored, and nothing leaves this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Updates: \(updates.channel.title.lowercased()) channel · Sparkle, EdDSA-signed")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { showAbout = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: - Provider card (provider-agnostic)

struct ProviderCard: View {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    let health: ProviderHealth?
    let trend: [SamplePoint]
    var trendStart: Date? = nil
    var trendEnd: Date? = nil
    let freshness: String?
    var onRecovery: (() -> Void)? = nil
    var recoveryTitle: String? = nil
    var forecastFor: (QuotaWindow) -> String? = { _ in nil }
    var compact = false
    var isExpanded = false
    var onToggleExpanded: () -> Void = {}

    var body: some View {
        Card(
            title: provider.displayName,
            dot: dotColor(for: snapshot?.limiting?.percent),
            subtitle: subtitle,
            isExpandable: compact && (snapshot?.windows.count ?? 0) > 1,
            isExpanded: isExpanded,
            onToggleExpanded: onToggleExpanded
        ) {
            if let snapshot, !snapshot.windows.isEmpty {
                ForEach(visibleWindows(snapshot)) { window in
                    MeterRow(
                        provider: provider.displayName,
                        label: window.label,
                        percent: window.percent,
                        reset: window.resetsAt,
                        flag: window.isLimited ? "limit reached" : nil,
                        isLimiting: window.id == snapshot.limiting?.id,
                        forecast: forecastFor(window)
                    )
                }
                // The chart belongs to the one window the compact card shows.
                // Expanded cards list every window, so a single unlabeled
                // chart would be ambiguous; History owns that view.
                if compact, !isExpanded, trend.count >= 2, let window = snapshot.limiting {
                    Sparkline(
                        points: trend,
                        color: dotColor(usageColorName(for: window.percent)),
                        start: trendStart,
                        end: trendEnd
                    )
                    .padding(.top, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(provider.displayName) \(window.label) trend")
                }
                if !statusBits.isEmpty {
                    StatusLine(text: statusBits.joined(separator: " · "), degraded: degraded)
                }
                if !snapshot.facts.isEmpty {
                    Text(snapshot.facts.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(snapshot.facts.joined(separator: " · "))
                }
                if let onRecovery, health?.state != .ok {
                    Button(recoveryTitle ?? "Fix…", action: onRecovery)
                        .font(.caption)
                }
            } else {
                emptyState
            }
        }
        .help(tooltip)
    }

    private func visibleWindows(_ snapshot: ProviderSnapshot) -> [QuotaWindow] {
        if compact, !isExpanded, let limiting = snapshot.limiting {
            return [limiting]
        }
        return snapshot.windows
    }

    private var subtitle: String? {
        if let plan = snapshot?.plan { return displayPlan(plan) }
        if snapshot?.origin == .localLog { return "local log" }
        return nil
    }

    private var degraded: Bool {
        guard let health else { return false }
        return !health.state.isHealthy || freshness != nil
    }

    /// Only non-routine facts earn a line: a problem, a stale reading, or a
    /// local-log fallback. "live · via <endpoint>" is provenance, not status.
    private var statusBits: [String] {
        var bits: [String] = []
        if let health, !health.state.isHealthy, let message = health.message {
            bits.append(message)
        }
        if let freshness {
            bits.append("last good \(freshness)")
        } else if let snapshot, snapshot.origin == .localLog {
            bits.append("local log")
        }
        return bits
    }

    private var tooltip: String {
        guard let snapshot else { return provider.displayName }
        var bits: [String] = [snapshot.source]
        switch snapshot.origin {
        case .network: bits.append("live reading")
        case .localLog: bits.append("local log fallback")
        case .demo: bits.append("demo data")
        }
        bits.append(freshnessText(for: snapshot.observedAt))
        return "\(provider.displayName) · \(bits.joined(separator: " · "))"
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let health, !health.state.isHealthy {
                Text(health.message ?? "Unavailable.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let onRecovery {
                    Button(recoveryTitle ?? "Fix…", action: onRecovery)
                        .font(.caption)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - History window

@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()
    private var window: NSWindow?
    private var isOpen = false

    func show(model: QuotaModel, layout: ProviderLayoutStore) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Quota History"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 520, height: 420)
            window.delegate = self
            window.contentView = NSHostingView(rootView: HistoryView(model: model, layout: layout))
            window.center()
            window.setFrameAutosaveName("QuotaHistoryWindow")
            self.window = window
        }
        if !isOpen {
            isOpen = true
            SecondaryWindowPolicy.didOpen()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard isOpen else { return }
        isOpen = false
        SecondaryWindowPolicy.didClose()
    }
}


// MARK: - Setup + hidden notes

struct HiddenNote: View {
    var count: Int
    var isEmpty = false
    var onSettings: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(isEmpty
                 ? "All providers are hidden."
                 : "\(count) hidden in overview.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings…", action: onSettings)
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Open provider settings")
        }
        .padding(.horizontal, 2)
    }
}

struct SetupCard: View {
    let providers: [ProviderID]
    var checking: Set<ProviderID> = []
    let hasConfigured: Bool
    let onEnterKey: () -> Void
    @State private var copied: ProviderID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasConfigured ? "Connect another provider" : "Get started with QuotaBar")
                .font(.subheadline.weight(.semibold))
            Text(hasConfigured
                 ? "Add another service whenever you need it."
                 : "QuotaBar reads usage locally and never sends it to another server.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(providers, id: \.self) { provider in
                HStack(spacing: 8) {
                    Text(provider.displayName).font(.callout)
                    if checking.contains(provider) {
                        ProgressView().controlSize(.mini)
                        Text("Checking…").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if !checking.contains(provider) {
                        action(provider)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func action(_ provider: ProviderID) -> some View {
        switch provider {
        case .go:
            Button("Enter key…", action: onEnterKey)
                .font(.caption)
                .accessibilityLabel("Enter OpenCode Go API key")
        case .codex:
            HStack(spacing: 6) {
                Button(copied == .codex ? "Copied" : "Copy login") {
                    copyToPasteboard("codex login", provider)
                }
                Button {
                    NSWorkspace.shared.open(homeDir().appendingPathComponent(".codex"))
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open ~/.codex")
                .accessibilityLabel("Open Codex credential folder")
            }
            .font(.caption)
        case .commandCode:
            HStack(spacing: 6) {
                Button(copied == .commandCode ? "Copied" : "Copy path") {
                    copyToPasteboard(homeDir().appendingPathComponent(".config/opencode/opencode.json").path, provider)
                }
                Button("Setup…") {
                    if let url = URL(string: "https://github.com/sebas-rom/quota-bar/blob/main/INSTALL.md#setup") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .font(.caption)
        }
    }

    private func copyToPasteboard(_ text: String, _ provider: ProviderID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = provider
    }
}
