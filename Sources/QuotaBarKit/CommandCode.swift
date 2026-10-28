import Foundation

// MARK: - Command Code (GOAT/Pro/Max plans)
//
// Two endpoints the official CLI itself uses:
//   GET https://api.commandcode.ai/alpha/billing/credits
//   GET https://api.commandcode.ai/alpha/billing/subscriptions
//
// Credits are the plan's usage-value units; window caps are in the same units.
// The subscription payload carries the real period end, so renewal copy is
// fact, not inference.

public enum CommandCodeError: Error, Equatable {
    case malformed
}

public struct CommandCodeCredits: Equatable, Sendable {
    public let monthlyRemaining: Double
    public let fiveHourUsed: Double
    public let fiveHourCap: Double
    public let fiveHourReset: Date?
    public let fiveHourExceeded: Bool
    public let weeklyUsed: Double
    public let weeklyCap: Double
    public let weeklyReset: Date?
    public let weeklyExceeded: Bool
}

public struct CommandCodeSubscription: Equatable, Sendable {
    public let planId: String?
    public let status: String?
    public let periodStart: Date?
    public let periodEnd: Date?
    public let cancelAtPeriodEnd: Bool
    public let userId: String?
}

public enum CommandCode {
    public static let baseURL = "https://api.commandcode.ai"
    public static let userAgent = "QuotaBar/0.4.2 (macOS)"

    // Plan totals from the official CLI (usage-value units).
    private static let planCredits: [String: Double] = [
        "individual-go": 10,
        "individual-go-v1": 10,
        "individual-goat": 70,
        "individual-pro": 30,
        "individual-pro-v1": 80,
        "individual-provider": 15,
        "individual-max": 150,
        "individual-ultra": 300,
        "teams-pro": 40,
    ]

    private static let planNames: [String: String] = [
        "individual-go": "Go",
        "individual-go-v1": "Go",
        "individual-goat": "GOAT",
        "individual-pro": "Pro",
        "individual-pro-v1": "Pro",
        "individual-provider": "Provider",
        "individual-max": "Max",
        "individual-ultra": "Ultra",
        "teams-pro": "Teams Pro",
    ]

    public static func planName(for planId: String?) -> String? {
        guard let planId else { return nil }
        return planNames[planId] ?? planId
    }

    public static func planTotalCredits(for planId: String?) -> Double? {
        guard let planId else { return nil }
        return planCredits[planId]
    }

    /// API key discovery for Command Code, in the order the product actually
    /// documents it:
    ///   1. `COMMANDCODE_API_KEY` (QuotaBar's original variable) and
    ///      `COMMAND_CODE_API_KEY` (the official CLI's variable).
    ///   2. `~/.commandcode/auth.json`, the file the official CLI writes when
    ///      you run `commandcode login`. Its shape is not a public schema, so
    ///      parsing is deliberately narrow: only string values under a short
    ///      allowlist of key names, at the top level or one known container
    ///      deep. Unknown shapes yield no key, never a guess.
    ///   3. The opencode provider config the official OpenCode integration uses
    ///      (`providers.commandcode.settings.apiKey`).
    ///
    /// The key is never logged, and a Finder-launched app does not inherit
    /// shell exports: the file paths matter as much as the environment.
    public static func discoverKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configURLs: [URL]? = nil,
        authURLs: [URL]? = nil
    ) -> String? {
        for name in ["COMMANDCODE_API_KEY", "COMMAND_CODE_API_KEY"] {
            if let env = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !env.isEmpty, !env.hasPrefix("{env:") {
                return env
            }
        }
        for url in authURLs ?? defaultAuthURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let key = keyFromAuthFile(data) { return key }
        }
        let urls = configURLs ?? defaultConfigURLs()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let providers = obj["providers"] as? [String: Any] ?? obj["provider"] as? [String: Any]
            if let entry = providers?["commandcode"] as? [String: Any],
               let settings = entry["settings"] as? [String: Any],
               let key = settings["apiKey"] as? String {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !trimmed.hasPrefix("{env:") { return trimmed }
            }
        }
        return nil
    }

    /// Field names the CLI's auth file has used or may plausibly use. A value
    /// that is not a non-empty string, or that is a `{env:…}` placeholder, is
    /// ignored rather than coerced.
    private static let authKeyNames = [
        "apiKey", "api_key", "key", "token", "accessToken", "access_token",
    ]
    private static let authContainers = ["auth", "credentials", "data", "session", "account"]

    /// Narrow, defensive parse of `~/.commandcode/auth.json`. Exposed for tests.
    public static func keyFromAuthFile(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func usable(_ value: Any?) -> String? {
            guard let s = value as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("{env:"), trimmed.count >= 8 else { return nil }
            return trimmed
        }
        for name in authKeyNames {
            if let key = usable(obj[name]) { return key }
        }
        for container in authContainers {
            guard let nested = obj[container] as? [String: Any] else { continue }
            for name in authKeyNames {
                if let key = usable(nested[name]) { return key }
            }
        }
        return nil
    }

    public static func defaultAuthURLs() -> [URL] {
        var urls: [URL] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            urls.append(URL(fileURLWithPath: xdg).appendingPathComponent("commandcode/auth.json"))
        }
        urls.append(homeDir().appendingPathComponent(".commandcode/auth.json"))
        urls.append(homeDir().appendingPathComponent(".config/commandcode/auth.json"))
        return urls
    }


    static func defaultConfigURLs() -> [URL] {
        var urls: [URL] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            urls.append(URL(fileURLWithPath: xdg).appendingPathComponent("opencode/opencode.json"))
        }
        urls.append(homeDir().appendingPathComponent(".config/opencode/opencode.json"))
        urls.append(homeDir().appendingPathComponent(".config/opencode/opencode.jsonc"))
        return urls
    }

    // MARK: decoding

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func date(millis any: Any?) -> Date? {
        guard let ms = number(any), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    public static func decodeCredits(_ data: Data) throws -> CommandCodeCredits {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let credits = root["credits"] as? [String: Any],
              let windows = root["windowLimits"] as? [String: Any] else {
            throw CommandCodeError.malformed
        }
        guard let five = windows["fiveHour"] as? [String: Any],
              let weekly = windows["weekly"] as? [String: Any] else {
            throw CommandCodeError.malformed
        }
        func used(_ w: [String: Any]) -> Double? { number(w["used"]) }
        func cap(_ w: [String: Any]) -> Double? { number(w["cap"]) }
        guard let fiveUsed = used(five), let fiveCap = cap(five),
              let weekUsed = used(weekly), let weekCap = cap(weekly),
              fiveCap > 0, weekCap > 0 else {
            throw CommandCodeError.malformed
        }
        guard let remaining = number(credits["monthlyCredits"]) else {
            throw CommandCodeError.malformed
        }
        return CommandCodeCredits(
            monthlyRemaining: remaining,
            fiveHourUsed: fiveUsed,
            fiveHourCap: fiveCap,
            fiveHourReset: date(millis: five["resetAt"]),
            fiveHourExceeded: (five["exceeded"] as? Bool) ?? (fiveUsed >= fiveCap),
            weeklyUsed: weekUsed,
            weeklyCap: weekCap,
            weeklyReset: date(millis: weekly["resetAt"]),
            weeklyExceeded: (weekly["exceeded"] as? Bool) ?? (weekUsed >= weekCap)
        )
    }

    public static func decodeSubscription(_ data: Data) throws -> CommandCodeSubscription {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = root["data"] as? [String: Any] else {
            throw CommandCodeError.malformed
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func parse(_ any: Any?) -> Date? {
            guard let s = any as? String else { return nil }
            return iso.date(from: s) ?? plain.date(from: s)
        }
        return CommandCodeSubscription(
            planId: payload["planId"] as? String,
            status: payload["status"] as? String,
            periodStart: parse(payload["currentPeriodStart"]),
            periodEnd: parse(payload["currentPeriodEnd"]),
            cancelAtPeriodEnd: (payload["cancelAtPeriodEnd"] as? Bool) ?? false,
            userId: payload["userId"] as? String
        )
    }

    // MARK: windows + facts

    public static func windows(_ credits: CommandCodeCredits,
                               subscription: CommandCodeSubscription?) -> [QuotaWindow] {
        var windows: [QuotaWindow] = [
            QuotaWindow(
                // `.primary`, not `.rolling`: Command Code's window opens on the
                // first request and then runs a fixed 5 hours. WindowSemantics
                // decides rolling-ness; the kind only marks the role.
                id: "commandcode.5h", kind: .primary, label: "5-hour",
                percent: credits.fiveHourUsed / credits.fiveHourCap * 100,
                resetsAt: credits.fiveHourReset, windowMinutes: 300,
                isLimited: credits.fiveHourExceeded
            ),
            QuotaWindow(
                id: "commandcode.weekly", kind: .weekly, label: "Weekly",
                percent: credits.weeklyUsed / credits.weeklyCap * 100,
                resetsAt: credits.weeklyReset, windowMinutes: 10_080,
                isLimited: credits.weeklyExceeded
            ),
        ]
        if let total = planTotalCredits(for: subscription?.planId), total > 0 {
            let used = max(0, total - credits.monthlyRemaining)
            windows.append(QuotaWindow(
                id: "commandcode.monthly", kind: .monthly, label: "Monthly",
                percent: min(100, used / total * 100),
                resetsAt: subscription?.periodEnd, windowMinutes: 43_200,
                isLimited: credits.monthlyRemaining <= 0,
                cycleStart: subscription?.periodStart
            ))
        }
        return windows
    }

    public static func facts(_ credits: CommandCodeCredits,
                             subscription: CommandCodeSubscription?,
                             now: Date = Date()) -> [String] {
        var facts = [creditsFact(credits, planId: subscription?.planId)]
        if let subscription, let renewal = renewalFact(subscription, now: now) {
            facts.append(renewal)
        }
        return facts
    }

    // MARK: presentation

    /// "68.7 of 70 credits left" (or without total when the plan is unknown).
    public static func creditsFact(_ credits: CommandCodeCredits, planId: String?) -> String {
        let remaining = formatCredits(credits.monthlyRemaining)
        if let total = planTotalCredits(for: planId) {
            return "\(remaining) of \(formatCredits(total)) credits left"
        }
        return "\(remaining) credits left"
    }

    public static func renewalFact(_ sub: CommandCodeSubscription, now: Date = Date()) -> String? {
        guard let status = sub.status?.lowercased() else { return nil }
        guard let end = sub.periodEnd else { return nil }
        let date = formatDate(end, now: now)
        switch status {
        case "active":
            return sub.cancelAtPeriodEnd ? "Ends \(date)" : "Renews \(date)"
        case "canceled", "ended", "incomplete_expired":
            return "Ended \(date)"
        default:
            return "Status \(status)"
        }
    }

    public static func formatCredits(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 { return String(Int(value.rounded())) }
        return String(format: "%.1f", value)
    }

    public static func formatDate(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
        return f.string(from: date)
    }
}
