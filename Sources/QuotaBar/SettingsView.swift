import SwiftUI
import AppKit
import QuotaBarKit

// MARK: - Settings
//
// One home for preferences that used to be scattered through the popover's ⋯
// menu. Operational actions (credentials, history deletion, updates install)
// stay in the popover; this window is for configuration.

struct SettingsView: View {
    @ObservedObject var model: QuotaModel
    @ObservedObject var layout: ProviderLayoutStore
    @ObservedObject var alerter: QuotaAlerter
    @ObservedObject var updates: UpdateController
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @AppStorage("CompactCards") private var compactCards = true

    @State private var selection: ProviderID?

    var body: some View {
        TabView {
            providersTab
                .tabItem { Label("Providers", systemImage: "list.bullet") }
            alertsTab
                .tabItem { Label("Alerts", systemImage: "bell") }
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 460)
    }

    // MARK: providers

    private var providersTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag to reorder, or select a provider and move it. This order is used in the popover, the menu bar and History.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(layout.layout.order, id: \.self) { provider in
                    row(provider)
                }
                .onMove { source, destination in
                    layout.move(fromOffsets: source, toOffset: destination)
                }
            }
            .frame(minHeight: 150)
            .accessibilityLabel("Providers in display order")

            HStack(spacing: 8) {
                Button("Move Up") {
                    guard let selection else { return }
                    layout.move(selection, by: -1)
                }
                .disabled(!canMove(by: -1))
                .accessibilityLabel("Move selected provider up")

                Button("Move Down") {
                    guard let selection else { return }
                    layout.move(selection, by: 1)
                }
                .disabled(!canMove(by: 1))
                .accessibilityLabel("Move selected provider down")

                Spacer()

                Button("Reset to Default") { layout.reset() }
                    .accessibilityLabel("Reset provider order and visibility")
            }

            Divider()

            Picker("Menu bar shows", selection: Binding(
                get: { layout.layout.menuBarStyle },
                set: { layout.setMenuBarStyle($0) }
            )) {
                ForEach(MenuBarStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Menu bar display")

            Text("Hidden providers keep tracking in the background and still appear in History. They can still alert if their alert switch is on.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func row(_ provider: ProviderID) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(layout.layout.isVisible(provider) ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                if let plan = model.snapshots[provider]?.plan {
                    Text(displayPlan(plan))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            Spacer()
            if !layout.layout.isVisible(provider) {
                Text("Hidden")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Toggle("Show \(provider.displayName) in overview", isOn: Binding(
                get: { layout.layout.isVisible(provider) },
                set: { layout.setHidden(provider, !$0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { selection = provider })
        .tag(provider)
    }

    private func canMove(by offset: Int) -> Bool {
        guard let selection,
              let index = layout.layout.order.firstIndex(of: selection) else { return false }
        return layout.layout.order.indices.contains(index + offset)
    }

    // MARK: alerts

    private var alertsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Quota alerts", isOn: Binding(
                get: { alerter.enabled },
                set: { on in Task { await alerter.setEnabled(on) } }
            ))
            .font(.headline)

            Text("One warning at 90% used per quota cycle, plus one limit-reached alert. Only fresh network readings alert.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if alerter.enabled {
                Divider()
                Text("Alert for").font(.caption).foregroundStyle(.secondary)
                ForEach(layout.layout.order, id: \.self) { provider in
                    Toggle(provider.displayName, isOn: Binding(
                        get: { alerter.isEnabled(for: provider) },
                        set: { alerter.setProvider(provider, enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                if layout.layout.hidden.isEmpty == false {
                    Text("Hidden providers are included here. Turn a switch off to silence one completely.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Send Test Alert") {
                        Task { await alerter.sendTest() }
                    }
                    if let issue = alerter.issue {
                        Text(issue).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: general

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin.enabled },
                set: { launchAtLogin.set($0) }
            ))

            Toggle("Compact cards", isOn: $compactCards)
            Text("Compact cards show the most-used window; turn this off to show every window at once.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Check for updates automatically", isOn: $updates.automaticChecks)
            HStack {
                Picker("Channel", selection: Binding(
                    get: { updates.channel },
                    set: { updates.setChannel($0) }
                )) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .frame(maxWidth: 220)
                Spacer()
                Button("Check Now") { updates.checkForUpdates() }
            }
            Text("Nightly builds come straight from main. Stable builds are tagged releases.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Refresh every 5 minutes and on wake.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let issue = model.storeIssue {
                    Text(issue).font(.caption2).foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// MARK: - Settings window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var isOpen = false

    func show(
        model: QuotaModel,
        layout: ProviderLayoutStore,
        alerter: QuotaAlerter,
        updates: UpdateController,
        launchAtLogin: LaunchAtLoginController
    ) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "QuotaBar Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(
                model: model,
                layout: layout,
                alerter: alerter,
                updates: updates,
                launchAtLogin: launchAtLogin
            ))
            window.center()
            window.setFrameAutosaveName("QuotaBarSettingsWindow")
            window.delegate = self
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
