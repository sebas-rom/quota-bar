import Foundation
import UserNotifications
import QuotaBarKit

// Thin delivery layer around AlertRules: opt-in, one permission prompt, and a
// persisted dedupe state so relaunches never repeat a warning.

@MainActor
final class QuotaAlerter: ObservableObject {
    static let shared = QuotaAlerter()

    @Published private(set) var enabled: Bool
    @Published private(set) var issue: String?

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let enabledKey = "QuotaAlertsEnabled"
    private let stateKey = "QuotaAlertState"

    private init() {
        enabled = defaults.bool(forKey: enabledKey)
    }

    func setEnabled(_ on: Bool) async {
        guard on else {
            enabled = false
            issue = nil
            defaults.set(false, forKey: enabledKey)
            return
        }

        let settings = await center.notificationSettings()
        var granted = false
        var message: String?

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            granted = true
        case .notDetermined:
            do {
                granted = try await center.requestAuthorization(options: [.alert, .sound])
                if !granted {
                    message = "Notifications were not allowed. You can enable QuotaBar in System Settings → Notifications."
                }
            } catch {
                message = "Could not request notification permission."
            }
        case .denied:
            message = "Notifications are off. Enable QuotaBar in System Settings → Notifications."
        @unknown default:
            message = "Notifications are unavailable on this Mac."
        }

        enabled = granted
        issue = message
        defaults.set(granted, forKey: enabledKey)
    }

    /// Called only for fresh, successful network snapshots.
    func handle(_ snapshot: ProviderSnapshot, now: Date = Date()) {
        guard enabled, snapshot.origin == .network else { return }
        var state = loadState()
        let decisions = AlertRules.evaluate(snapshot, state: &state, now: now)
        guard !decisions.isEmpty else { return }
        save(state)
        for decision in decisions {
            post(decision.message, identifier: decision.identifier)
        }
    }

    func sendTest() async {
        post("Test notification — Quota alerts are working.", identifier: "quotabar.test.\(UUID().uuidString)")
    }

    private func post(_ body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = "QuotaBar"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task { try? await center.add(request) }
    }

    private func loadState() -> AlertState {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(AlertState.self, from: data) else {
            return AlertState()
        }
        return state
    }

    private func save(_ state: AlertState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }
}
