import Foundation
import UserNotifications
import QuotaBarKit

// Thin delivery layer around AlertRules: opt-in, one permission prompt, and a
// persisted dedupe state so relaunches never repeat a warning.

@MainActor
final class QuotaAlerter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = QuotaAlerter()

    @Published private(set) var enabled: Bool
    @Published private(set) var issue: String?

    private let center = UNUserNotificationCenter.current()
    private let adHoc = SignatureInfo.isAdHoc
    private let defaults = UserDefaults.standard
    private let enabledKey = "QuotaAlertsEnabled"
    private let stateKey = "QuotaAlertState"

    private override init() {
        enabled = defaults.bool(forKey: enabledKey)
        super.init()
        // Without a delegate, macOS silences notifications while the app is
        // active — which is exactly when the test button is clicked.
        center.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func setEnabled(_ on: Bool) async {
        guard on else {
            enabled = false
            issue = nil
            defaults.set(false, forKey: enabledKey)
            return
        }

        // Unsigned/ad-hoc builds cannot register with Notification Center. Use
        // the local panel instead of prompting for a permission that would
        // silently never deliver.
        if adHoc {
            enabled = true
            issue = nil
            defaults.set(true, forKey: enabledKey)
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
        if adHoc {
            let worst = decisions.first(where: { $0.kind == .limit }) ?? decisions[0]
            AlertToast.shared.show(worst.message)
        } else {
            for decision in decisions {
                post(decision.message, identifier: decision.identifier)
            }
        }
    }

    func sendTest() async {
        if adHoc {
            AlertToast.shared.show("Test alert — Quota alerts are working.")
            return
        }
        post("Test notification — Quota alerts are working.", identifier: "quotabar.test.\(UUID().uuidString)")
    }

    private func post(_ body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = "QuotaBar"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task { @MainActor in
            do {
                try await center.add(request)
                issue = nil
            } catch {
                issue = "Notification failed: \(error.localizedDescription)"
            }
        }
    }

    /// Machine-readable authorization/delivery report for `--notification-diagnose`.
    func diagnose() async -> String {
        let settings = await center.notificationSettings()
        var lines: [String] = []
        lines.append("bundle=\(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("path=\(Bundle.main.bundlePath)")
        lines.append("authorization=\(settings.authorizationStatus.rawValue)")
        lines.append("alertSetting=\(settings.alertSetting.rawValue)")
        lines.append("notificationCenter=\(settings.notificationCenterSetting.rawValue)")
        lines.append("lockScreen=\(settings.lockScreenSetting.rawValue)")
        lines.append("sound=\(settings.soundSetting.rawValue)")
        lines.append("preferenceEnabled=\(enabled)")
        lines.append("adHoc=\(adHoc)")
        lines.append("delivery=\(adHoc ? "panel" : "notification-center")")

        let content = UNMutableNotificationContent()
        content.title = "QuotaBar"
        content.body = "Diagnostic notification."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "quotabar.diagnose.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            lines.append("add=ok")
        } catch {
            lines.append("add=error \(error)")
        }
        return lines.joined(separator: "\n")
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
