import Foundation
import SwiftUI
import AppKit
import ServiceManagement
import QuotaBarKit

// MARK: - Provider layout store
//
// One JSON value in UserDefaults. A missing or unreadable value falls back to
// the default layout, so an upgrade and a corrupted file look the same to the
// user: all providers, default order.

@MainActor
final class ProviderLayoutStore: ObservableObject {
    static let storageKey = "ProviderLayout.v1"

    @Published private(set) var layout: ProviderLayout

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(ProviderLayout.self, from: data) {
            layout = decoded.normalized()
        } else {
            layout = .standard
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        layout.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func move(_ provider: ProviderID, by offset: Int) {
        layout = layout.normalized()
        guard let index = layout.order.firstIndex(of: provider) else { return }
        let target = index + offset
        guard layout.order.indices.contains(target) else { return }
        layout.order.swapAt(index, target)
        persist()
    }

    func setHidden(_ provider: ProviderID, _ hidden: Bool) {
        layout = layout.normalized()
        guard layout.hidden.contains(provider) != hidden else { return }
        layout.setHidden(provider, hidden)
        persist()
    }

    func setMenuBarStyle(_ style: MenuBarStyle) {
        guard layout.menuBarStyle != style else { return }
        layout.menuBarStyle = style
        persist()
    }

    func reset() {
        layout = .standard
        persist()
    }

    private func persist() {
        layout = layout.normalized()
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

// MARK: - Launch at login

@MainActor
final class LaunchAtLoginController: ObservableObject {
    static let shared = LaunchAtLoginController()

    @Published private(set) var enabled: Bool

    private init() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Keep the switch truthful even when registration is refused.
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Secondary windows
//
// History and Settings share one activation policy. Closing either window no
// longer drops the app to .accessory while the other is still open.

@MainActor
enum SecondaryWindowPolicy {
    private static var open = 0

    static func didOpen() {
        open += 1
        if open == 1 { NSApp.setActivationPolicy(.regular) }
    }

    static func didClose() {
        open = max(0, open - 1)
        if open == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
