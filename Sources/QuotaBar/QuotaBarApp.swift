import SwiftUI
import ServiceManagement
import QuotaBarKit

// QuotaBar v0.3 — two provider cards, in-app key entry (Keychain), compact
// footer with overflow menu, VoiceOver semantics, system-only styling.

private let appVersion = "0.3.0"

private enum Layout {
    static let outer: CGFloat = 12
    static let card: CGFloat = 12
    static let cardSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 10
}

private func dotColor(_ name: String) -> Color {
    switch name {
    case "green": return .green
    case "yellow": return .yellow
    case "orange": return .orange
    case "red": return .red
    default: return .gray
    }
}

private struct MeterRow: View {
    let provider: String
    let label: String
    let percent: Double
    let reset: Date?
    let flag: String?
    let isLimiting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                if let flag {
                    Text(flag).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.subheadline).fontWeight(.semibold).monospacedDigit()
            }
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .tint(dotColor(usageColorName(for: percent)))
            if let r = resetText(until: reset) {
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider), \(label) quota")
        .accessibilityValue("\(Int(percent.rounded())) percent used")
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        var bits: [String] = []
        if isLimiting { bits.append("Limiting window.") }
        if flag != nil { bits.append("Limit reached.") }
        if let r = resetText(until: reset) { bits.append(r.capitalized + ".") }
        return bits.joined(separator: " ")
    }
}

private struct Card<Content: View>: View {
    let title: String
    let dot: String
    let subtitle: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack(spacing: 6) {
                Circle().fill(dotColor(dot)).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(title).font(.headline)
                Spacer()
                if let s = subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            content
        }
        .padding(Layout.card)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

@main
struct QuotaBarApp: App {
    @StateObject private var model = QuotaModel()
    @State private var showKeyEntry = false
    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var validating = false
    @State private var showAbout = false
    @State private var confirmRemoveKey = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some Scene {
        MenuBarExtra(model.barText, systemImage: "gauge") {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                goCard
                codexCard
                if showKeyEntry { keyEntry }
                Divider()
                footer
            }
            .padding(Layout.outer)
            .frame(minWidth: 300)
            .task { await model.refresh() }
            .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
                Task { await model.refresh() }
            }
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
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: Go card

    @ViewBuilder
    private var goCard: some View {
        switch model.goState {
        case let .ready(usage, _):
            let lim = usage.limiting
            Card(title: "OpenCode Go",
                 dot: lim.map { usageColorName(for: $0.window.percent) } ?? "gray",
                 subtitle: lim.map { "\($0.label) · \(Int($0.window.percent.rounded()))%" }) {
                if let r = usage.rolling {
                    MeterRow(provider: "OpenCode Go", label: "5-hour", percent: r.percent,
                             reset: r.resetsAt, flag: r.isRateLimited ? "limit reached" : nil,
                             isLimiting: lim?.label == "5h")
                }
                if let w = usage.weekly {
                    MeterRow(provider: "OpenCode Go", label: "Weekly", percent: w.percent,
                             reset: w.resetsAt, flag: w.isRateLimited ? "limit reached" : nil,
                             isLimiting: lim?.label == "7d")
                }
                if let m = usage.monthly {
                    MeterRow(provider: "OpenCode Go", label: "Monthly", percent: m.percent,
                             reset: m.resetsAt, flag: m.isRateLimited ? "limit reached" : nil,
                             isLimiting: lim?.label == "30d")
                }
            }
        case .noKey:
            Card(title: "OpenCode Go", dot: "gray", subtitle: nil) {
                Text("No API key found on disk.").foregroundStyle(.secondary)
                Button("Enter API key…") { showKeyEntry = true }
            }
        case .authFailed:
            Card(title: "OpenCode Go", dot: "gray", subtitle: nil) {
                Text("Key rejected (401).").foregroundStyle(.secondary)
                Button("Enter a different key…") { showKeyEntry = true }
            }
        case .subscriptionUnavailable:
            Card(title: "OpenCode Go", dot: "gray", subtitle: nil) {
                Text("No Go subscription for this key (403). Use the console Personal API key.").foregroundStyle(.secondary)
                Button("Enter API key…") { showKeyEntry = true }
            }
        case .rateLimitedHTTP:
            Card(title: "OpenCode Go", dot: "gray", subtitle: "stale") {
                Text("Rate limited (429). Retrying automatically.").foregroundStyle(.secondary)
            }
        case .providerDown:
            Card(title: "OpenCode Go", dot: "gray", subtitle: "stale") {
                Text("opencode.ai is having issues (5xx).").foregroundStyle(.secondary)
            }
        case .offline:
            Card(title: "OpenCode Go", dot: "gray", subtitle: "stale") {
                Text("No connection. Retrying automatically.").foregroundStyle(.secondary)
            }
        case let .unexpected(m):
            Card(title: "OpenCode Go", dot: "gray", subtitle: "stale") {
                Text("Unexpected response (\(m)).").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Codex card

    @ViewBuilder
    private var codexCard: some View {
        let c = model.codex
        if !c.tokenPresent {
            Card(title: "Codex", dot: "gray", subtitle: nil) {
                Text("No token in ~/.codex/auth.json.").foregroundStyle(.secondary)
            }
        } else if let p = c.primary {
            Card(title: "Codex", dot: usageColorName(for: p), subtitle: c.plan) {
                MeterRow(provider: "Codex", label: "Primary", percent: p,
                         reset: c.primaryReset, flag: nil, isLimiting: true)
                if let s = c.secondary {
                    MeterRow(provider: "Codex", label: "Secondary", percent: s,
                             reset: c.secondaryReset, flag: nil, isLimiting: false)
                }
            }
        } else {
            Card(title: "Codex", dot: "gray", subtitle: c.plan) {
                Text(c.note).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Key entry (Keychain, validated before save)

    @ViewBuilder
    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste your opencode Personal API key:").font(.caption).foregroundStyle(.secondary)
            SecureField("oc_sk_…", text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .disabled(validating)
            if let e = keyError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(validating ? "Checking…" : "Save") {
                    validating = true
                    keyError = nil
                    Task {
                        let err = await model.validateAndSaveGoKey(keyInput)
                        validating = false
                        if let err {
                            keyError = err
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

    // MARK: Footer — Refresh + overflow menu

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button(model.busy ? "Refreshing…" : "Refresh") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r").disabled(model.busy)
            Spacer()
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
                if loadKeychainKey(account: quotaBarGoAccount) != nil {
                    Button("Remove Saved Go Key…") { confirmRemoveKey = true }
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
        }
        if let t = model.lastUpdate {
            Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityLabel("Last updated \(t.formatted(date: .omitted, time: .shortened))")
        }
    }

    // MARK: About

    @ViewBuilder
    private var aboutView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QuotaBar \(appVersion)").font(.headline)
            Text("Minimal menu-bar for opencode-go + Codex quotas.")
                .foregroundStyle(.secondary)
            Divider()
            Text("Go: opencode.ai/zen/go/v1/usage").font(.caption).monospaced()
            Text("Codex: chatgpt.com/backend-api/wham/usage").font(.caption).monospaced()
            Text("Go key source: \(goSourceText)").font(.caption).foregroundStyle(.secondary)
            Text("Local-only. Quota reads use your existing tokens; a key you enter is kept in this Mac's Keychain and never logged.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { showAbout = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var goSourceText: String {
        if case let .ready(_, source) = model.goState { return source }
        if loadKeychainKey(account: quotaBarGoAccount) != nil { return "Keychain (saved, not yet validated)" }
        return "opencode auth.json"
    }
}
