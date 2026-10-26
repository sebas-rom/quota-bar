import SwiftUI
import ServiceManagement
import QuotaBarKit

// QuotaBar v0.2 — two provider cards, in-app key entry (Keychain), no scraping.

private func dotColor(_ name: String) -> Color {
    switch name {
    case "green": return .green
    case "yellow": return .yellow
    case "orange": return .orange
    case "red": return .red
    default: return .gray
    }
}

private struct WindowRow: View {
    let label: String
    let window: GoWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                if window.isRateLimited {
                    Text("limit reached").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("\(Int(window.percent.rounded()))%").font(.subheadline).monospacedDigit()
            }
            ProgressView(value: min(max(window.percent, 0), 100), total: 100)
                .tint(dotColor(usageColorName(for: window.percent)))
            if let r = resetText(until: window.resetsAt) {
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let dot: String
    let subtitle: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(dotColor(dot)).frame(width: 8, height: 8)
                Text(title).font(.headline)
                Spacer()
                if let s = subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(10)
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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some Scene {
        MenuBarExtra(model.barText, systemImage: "gauge") {
            VStack(alignment: .leading, spacing: 10) {
                goCard
                codexCard
                if showKeyEntry { keyEntry }
                Divider()
                footer
            }
            .padding(10)
            .frame(minWidth: 300)
            .task { await model.refresh() }
            .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
                Task { await model.refresh() }
            }
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: Go card

    @ViewBuilder
    private var goCard: some View {
        switch model.goState {
        case let .ready(usage, source):
            let lim = usage.limiting
            Card(title: "OpenCode Go", dot: lim.map { usageColorName(for: $0.window.percent) } ?? "gray",
                 subtitle: [lim.map { "\($0.label) limiting" }, source].compactMap { $0 }.joined(separator: " · ")) {
                if let r = usage.rolling { WindowRow(label: "5-hour", window: r) }
                if let w = usage.weekly { WindowRow(label: "Weekly", window: w) }
                if let m = usage.monthly { WindowRow(label: "Monthly", window: m) }
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
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Primary").font(.subheadline)
                        Spacer()
                        Text("\(Int(p.rounded()))%").font(.subheadline).monospacedDigit()
                    }
                    ProgressView(value: min(max(p, 0), 100), total: 100)
                        .tint(dotColor(usageColorName(for: p)))
                    if let r = resetText(until: c.primaryReset) {
                        Text(r).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let s = c.secondary {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Secondary").font(.subheadline)
                            Spacer()
                            Text("\(Int(s.rounded()))%").font(.subheadline).monospacedDigit()
                        }
                        ProgressView(value: min(max(s, 0), 100), total: 100)
                            .tint(dotColor(usageColorName(for: s)))
                        if let r = resetText(until: c.secondaryReset) {
                            Text(r).font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let t = model.lastUpdate {
            Text("Updated \(t.formatted(date: .omitted, time: .shortened)) · v0.2.0")
                .font(.caption).foregroundStyle(.secondary)
        }
        Button(model.busy ? "Refreshing…" : "Refresh now") {
            Task { await model.refresh() }
        }
        .keyboardShortcut("r").disabled(model.busy)
        Toggle("Launch at login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { on in
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        Button("Reveal auth files") {
            NSWorkspace.shared.open(homeDir().appendingPathComponent(".local/share/opencode"))
            NSWorkspace.shared.open(homeDir().appendingPathComponent(".codex"))
        }
        if loadKeychainKey(account: quotaBarGoAccount) != nil {
            Button("Forget saved API key") { model.forgetGoKey() }
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
