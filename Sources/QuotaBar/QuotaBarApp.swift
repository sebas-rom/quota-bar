import SwiftUI
import AppKit
import ServiceManagement
import QuotaBarKit

// QuotaBar v0.4 — remembers what it sees.
//
// Menu bar: two percentages (unchanged).
// Popover: current windows, 24h trend, provenance and freshness.
// History: a real window with range charts over the local observation store.

private let appVersion = "0.4.1"

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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some Scene {
        MenuBarExtra(model.barText, systemImage: "gauge") {
            PopoverView(model: model, launchAtLogin: $launchAtLogin)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppEnvironment.model
        if ProcessInfo.processInfo.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if model.isDemo {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        if model.isDemo {
            DemoHost.shared.present(model: model)
            return
        }
        // Start Sparkle with the app so automatic checks do not depend on the
        // popover ever being opened.
        _ = UpdateController.shared
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
    @ObservedObject private var updates = UpdateController.shared
    @Binding var launchAtLogin: Bool
    /// Evidence snapshots render the content without presentation modifiers,
    /// which ImageRenderer cannot lay out reliably.
    var showsPresentation = true

    @State private var showKeyEntry = false
    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var validating = false
    @State private var showAbout = false
    @State private var confirmRemoveKey = false
    @State private var confirmClearHistory = false

    private var goTrend: [SamplePoint] {
        guard let windowID = model.snapshots[.go]?.limiting?.id else { return [] }
        return model.trend(provider: .go, windowID: windowID)
    }

    private var codexTrend: [SamplePoint] {
        guard let windowID = model.snapshots[.codex]?.limiting?.id else { return [] }
        return model.trend(provider: .codex, windowID: windowID)
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
            ProviderCard(
                provider: .go,
                snapshot: model.snapshots[.go],
                health: model.health[.go],
                trend: goTrend,
                freshness: model.staleness(for: .go),
                onEnterKey: { showKeyEntry = true }
            )
            ProviderCard(
                provider: .codex,
                snapshot: model.snapshots[.codex],
                health: model.health[.codex],
                trend: codexTrend,
                freshness: model.staleness(for: .codex),
                onEnterKey: nil
            )
            if showKeyEntry { keyEntry }
            Divider()
            footer
        }
        .padding(Layout.outer)
        .frame(width: 320)
    }

    // MARK: footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            Button(model.refreshing ? "Refreshing…" : "Refresh") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r")
            .disabled(model.refreshing)

            Button("History…") {
                HistoryWindowController.shared.show(model: model)
            }
            .disabled(model.store == nil)

            Spacer()

            if showsPresentation {
            Menu {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Button("Show Credential Files") {
                    NSWorkspace.shared.open(homeDir().appendingPathComponent(".local/share/opencode"))
                    NSWorkspace.shared.open(homeDir().appendingPathComponent(".codex"))
                }
                if !model.isDemo, loadKeychainKey(account: quotaBarGoAccount) != nil {
                    Button("Remove Saved Go Key…") { confirmRemoveKey = true }
                }
                if model.store != nil {
                    Button("Clear History…") { confirmClearHistory = true }
                }
                Divider()
                Button("Check for Updates…") { updates.checkForUpdates() }
                Toggle("Check automatically", isOn: $updates.automaticChecks)
                Menu("Update channel") {
                    ForEach(UpdateChannel.allCases) { channel in
                        Button {
                            updates.setChannel(channel)
                        } label: {
                            if updates.channel == channel {
                                Label(channel.title, systemImage: "checkmark")
                            } else {
                                Text(channel.title)
                            }
                        }
                    }
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
            if let issue = model.storeIssue {
                Text(issue).font(.caption2).foregroundStyle(.orange).lineLimit(1)
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
            Text("Two stacks, one glance: current quota, 24h trend, local history.")
                .foregroundStyle(.secondary)
            Divider()
            Text("Go: opencode.ai/zen/go/v1/usage").font(.caption).monospaced()
            Text("Codex: chatgpt.com/backend-api/wham/usage").font(.caption).monospaced()
            Text("Codex fallback: ~/.codex/sessions").font(.caption).monospaced()
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
    let freshness: String?
    let onEnterKey: (() -> Void)?

    var body: some View {
        Card(
            title: provider.displayName,
            dot: dotColor(for: snapshot?.limiting?.percent),
            subtitle: subtitle
        ) {
            if let snapshot, !snapshot.windows.isEmpty {
                ForEach(snapshot.windows) { window in
                    MeterRow(
                        provider: provider.displayName,
                        label: window.label,
                        percent: window.percent,
                        reset: window.resetsAt,
                        flag: window.isLimited ? "limit reached" : nil,
                        isLimiting: window.id == snapshot.limiting?.id
                    )
                }
                if trend.count >= 2 {
                    HStack(spacing: 6) {
                        Sparkline(points: trend, color: dotColor(dotColor(for: snapshot.limiting?.percent)))
                        Text("24h").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(provider.displayName) 24 hour trend")
                }
                StatusLine(text: statusText, degraded: degraded)
            } else {
                emptyState
            }
        }
    }

    private var subtitle: String? {
        if let plan = snapshot?.plan { return plan.capitalized }
        if snapshot?.origin == .localLog { return "local log" }
        return nil
    }

    private var degraded: Bool {
        guard let health else { return false }
        return !health.state.isHealthy || freshness != nil
    }

    private var statusText: String {
        var bits: [String] = []
        if let health, !health.state.isHealthy, let message = health.message {
            bits.append(message)
        }
        if let facts = snapshot?.facts, !facts.isEmpty {
            bits.append(contentsOf: facts)
        }
        if let freshness {
            bits.append("last good \(freshness)")
        } else if let snapshot {
            switch snapshot.origin {
            case .network: bits.append("live")
            case .localLog: bits.append("local log")
            case .demo: break
            }
        }
        if let health, health.state.isHealthy, snapshot?.origin == .network {
            bits.append("via \(provenance)")
        }
        return bits.joined(separator: " · ")
    }

    private var provenance: String {
        guard let snapshot else { return "—" }
        return snapshot.source
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let health, !health.state.isHealthy {
                Text(health.message ?? "Unavailable.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if health.state == .noCredentials || health.state == .authFailed || health.state == .entitlementMissing,
                   let onEnterKey {
                    Button("Enter API key…", action: onEnterKey)
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

    func show(model: QuotaModel) {
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
            window.contentView = NSHostingView(rootView: HistoryView(model: model))
            window.center()
            window.setFrameAutosaveName("QuotaHistoryWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
