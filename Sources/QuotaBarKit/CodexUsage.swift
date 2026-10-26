import Foundation

// MARK: - Codex decoding
//
// Two sources, one shape:
//   • GET https://chatgpt.com/backend-api/wham/usage  (live, authoritative)
//   • ~/.codex/sessions/**/*.jsonl token_count events (local, timestamped)
//
// The live payload carries more than primary/secondary windows: reset credits,
// credits balance, a separate code-review bucket and optional additional
// limits. All of it is decoded here, defensively, because the backend evolves.

public enum CodexDecodeError: Error, Equatable {
    case malformed
}

public struct CodexUsageReport: Equatable, Sendable {
    public let plan: String?
    public let windows: [QuotaWindow]
    public let hasCredits: Bool?
    public let creditBalance: String?
    public let resetCreditsAvailable: Int?
    public let limitReached: Bool
    public let accountRef: String?

    public init(plan: String?, windows: [QuotaWindow], hasCredits: Bool?,
                creditBalance: String?, resetCreditsAvailable: Int?,
                limitReached: Bool, accountRef: String?) {
        self.plan = plan
        self.windows = windows
        self.hasCredits = hasCredits
        self.creditBalance = creditBalance
        self.resetCreditsAvailable = resetCreditsAvailable
        self.limitReached = limitReached
        self.accountRef = accountRef
    }
}

private func number(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let i = any as? Int { return Double(i) }
    if let n = any as? NSNumber { return n.doubleValue }
    if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
    return nil
}

private func integer(_ any: Any?) -> Int? {
    if let i = any as? Int { return i }
    if let d = any as? Double { return Int(d) }
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
    return nil
}

private func string(_ any: Any?) -> String? {
    guard let s = any as? String else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

/// Non-reversible account reference: the raw id never reaches UI, disk or logs.
public func accountRef(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return String(stableHash(raw).prefix(10))
}

/// FNV-1a. Deterministic across launches, unlike Swift's Hasher.
func stableHash(_ s: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 {
        hash ^= UInt64(b)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return String(hash, radix: 16)
}

public func decodeCodexUsage(_ data: Data, now: Date = Date()) throws -> CodexUsageReport {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw CodexDecodeError.malformed
    }
    guard let rateLimit = root["rate_limit"] as? [String: Any] ?? root["rate_limits"] as? [String: Any] else {
        throw CodexDecodeError.malformed
    }

    let limitReached = (rateLimit["limit_reached"] as? Bool) ?? false
    var windows: [QuotaWindow] = []

    func appendWindow(_ raw: Any?, id: String, kind: WindowKind, fallbackLabel: String) {
        guard let w = raw as? [String: Any], let pct = number(w["used_percent"]), pct.isFinite else { return }
        let secs = integer(w["limit_window_seconds"])
        let reset: Date? = integer(w["reset_at"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? integer(w["reset_after_seconds"]).map { now.addingTimeInterval(TimeInterval($0)) }
        windows.append(QuotaWindow(
            id: id,
            kind: kind,
            label: secs == nil ? fallbackLabel : windowLabel(forSeconds: secs),
            percent: pct,
            resetsAt: reset,
            windowMinutes: secs.map { $0 / 60 },
            isLimited: limitReached && pct >= 99
        ))
    }

    appendWindow(rateLimit["primary_window"], id: "codex.primary", kind: .primary, fallbackLabel: "Primary")
    appendWindow(rateLimit["secondary_window"], id: "codex.secondary", kind: .secondary, fallbackLabel: "Secondary")

    if let review = root["code_review_rate_limit"] as? [String: Any] {
        appendWindow(review["primary_window"], id: "codex.review.primary", kind: .review, fallbackLabel: "Review")
        appendWindow(review["secondary_window"], id: "codex.review.secondary", kind: .review, fallbackLabel: "Review")
    }

    if let additional = root["additional_rate_limits"] as? [[String: Any]] {
        for (idx, extra) in additional.enumerated() {
            let key = string(extra["limit_id"]) ?? string(extra["limit_name"]) ?? "\(idx)"
            let name = string(extra["limit_name"]) ?? string(extra["limit_id"]) ?? "Additional"
            appendWindow(extra["primary_window"], id: "codex.extra.\(key).primary", kind: .additional, fallbackLabel: name)
            appendWindow(extra["secondary_window"], id: "codex.extra.\(key).secondary", kind: .additional, fallbackLabel: name)
        }
    }

    guard !windows.isEmpty else { throw CodexDecodeError.malformed }

    let credits = root["credits"] as? [String: Any]
    let resetCredits = root["rate_limit_reset_credits"] as? [String: Any]

    return CodexUsageReport(
        plan: string(root["plan_type"]),
        windows: windows,
        hasCredits: credits?["has_credits"] as? Bool,
        creditBalance: string(credits?["balance"]),
        resetCreditsAvailable: integer(resetCredits?["available_count"]),
        limitReached: limitReached,
        accountRef: accountRef(string(root["account_id"]))
    )
}

// MARK: - Local Codex session log (timestamped observations)

public struct CodexLogObservation: Equatable, Sendable {
    public let observedAt: Date
    public let plan: String?
    public let windows: [QuotaWindow]

    public init(observedAt: Date, plan: String?, windows: [QuotaWindow]) {
        self.observedAt = observedAt
        self.plan = plan
        self.windows = windows
    }
}

public enum CodexLocalLog {
    public static func sessionsRoot() -> URL {
        homeDir().appendingPathComponent(".codex/sessions")
    }

    /// Most recent rate-limit snapshot written by Codex itself.
    /// Cheap: only the tail of the newest session files is read.
    public static func latest(root: URL = sessionsRoot()) -> CodexLogObservation? {
        for url in newestSessionFiles(limit: 3, root: root) {
            guard let text = tail(of: url, bytes: 262_144) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("\"token_count\"") else { continue }
                if let obs = observation(fromLine: String(line)) { return obs }
            }
        }
        return nil
    }

    /// Every rate-limit snapshot in sessions modified since `date`, oldest first.
    /// Deduplicated by (window id, timestamp).
    public static func observations(since: Date, root: URL = sessionsRoot(), limit: Int = 5_000) -> [CodexLogObservation] {
        var out: [CodexLogObservation] = []
        var seen = Set<String>()
        let files = sessionFiles(root: root).filter { file in
            let m = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return m >= since
        }.sorted { a, b in
            let am = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bm = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return am < bm
        }

        for file in files {
            guard out.count < limit else { break }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard out.count < limit else { break }
                guard line.contains("\"token_count\"") else { continue }
                guard let obs = observation(fromLine: String(line)) else { continue }
                let key = "\(obs.observedAt.timeIntervalSince1970)|\(obs.windows.map(\.id).joined(separator: ","))"
                if seen.insert(key).inserted { out.append(obs) }
            }
        }
        return out.sorted { $0.observedAt < $1.observedAt }
    }

    // MARK: internals

    private static func observation(fromLine line: String) -> CodexLogObservation? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let rl = payload["rate_limits"] as? [String: Any] else { return nil }

        let stamp = (obj["timestamp"] as? String).flatMap(parseGoDate) ?? Date()
        var windows: [QuotaWindow] = []

        func append(_ raw: Any?, id: String, kind: WindowKind, fallback: String) {
            guard let w = raw as? [String: Any], let pct = number(w["used_percent"]), pct.isFinite else { return }
            let mins = integer(w["window_minutes"]) ?? integer(w["limit_window_seconds"]).map { $0 / 60 }
            let reset = integer(w["resets_at"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            windows.append(QuotaWindow(
                id: id,
                kind: kind,
                label: mins == nil ? fallback : windowLabel(forSeconds: mins.map { $0 * 60 }),
                percent: pct,
                resetsAt: reset,
                windowMinutes: mins,
                isLimited: (rl["rate_limit_reached_type"] as? String) != nil && pct >= 99
            ))
        }

        append(rl["primary"], id: "codex.primary", kind: .primary, fallback: "Primary")
        append(rl["secondary"], id: "codex.secondary", kind: .secondary, fallback: "Secondary")
        guard !windows.isEmpty else { return nil }

        return CodexLogObservation(
            observedAt: stamp,
            plan: string(rl["plan_type"]),
            windows: windows
        )
    }

    private static func sessionFiles(root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            out.append(url)
        }
        return out
    }

    private static func newestSessionFiles(limit: Int, root: URL) -> [URL] {
        sessionFiles(root: root)
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, d)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private static func tail(of url: URL, bytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > bytes ? size - bytes : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }
}
