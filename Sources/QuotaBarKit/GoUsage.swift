import Foundation

// MARK: - Go usage API model (GET https://opencode.ai/zen/go/v1/usage)
//
// Canonical shape:
//   {"usage":{"rolling":{"status":"ok","percent":12.5,"resetsAt":"..."},
//             "weekly":{...},"monthly":{...}}}
// percent is PERCENTAGE POINTS (0.5 means 0.5%, never divide by 100).
// "rate-limited" is a valid quota state, not an error.

public struct GoWindow: Equatable {
    public let status: String
    public let percent: Double
    public let resetsAt: Date?

    /// A window counts toward the headline only when its status is known-good.
    public var isUsable: Bool {
        let s = status.lowercased()
        return (s == "ok" || s == "rate-limited") && percent.isFinite && percent >= 0
    }

    public var isRateLimited: Bool { status.lowercased() == "rate-limited" }
}

public struct GoUsage: Equatable {
    public let rolling: GoWindow?
    public let weekly: GoWindow?
    public let monthly: GoWindow?

    public var available: [(label: String, window: GoWindow)] {
        var out: [(String, GoWindow)] = []
        if let w = rolling, w.isUsable { out.append(("5h", w)) }
        if let w = weekly, w.isUsable { out.append(("7d", w)) }
        if let w = monthly, w.isUsable { out.append(("30d", w)) }
        return out
    }

    /// The limiting window: most-consumed usable window, regardless of label.
    public var limiting: (label: String, window: GoWindow)? {
        available.max(by: { $0.window.percent < $1.window.percent })
    }
}

private struct RawWindow: Decodable {
    let status: String?
    let percent: FlexibleDouble?
    let resetsAt: String?
}

private struct FlexibleDouble: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; return }
        if let i = try? c.decode(Int.self) { value = Double(i); return }
        if let s = try? c.decode(String.self), let d = Double(s.trimmingCharacters(in: .whitespaces)) {
            value = d; return
        }
        throw DecodingError.typeMismatch(Double.self, .init(codingPath: decoder.codingPath, debugDescription: "not a number"))
    }
}

private let isoWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

public func parseGoDate(_ s: String) -> Date? {
    isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
}

public enum GoDecodeError: Error, Equatable {
    case malformed
}

/// Decodes the /usage payload. Unknown-status windows are dropped (unavailable),
/// valid windows are preserved. Throws only when nothing usable can be decoded.
public func decodeGoUsage(_ data: Data) throws -> GoUsage {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let usage = obj["usage"] as? [String: Any] else {
        throw GoDecodeError.malformed
    }
    func window(_ name: String) -> GoWindow? {
        guard let w = usage[name] as? [String: Any] else { return nil }
        let status = (w["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        var percent: Double?
        if let d = w["percent"] as? Double { percent = d }
        else if let i = w["percent"] as? Int { percent = Double(i) }
        else if let s = w["percent"] as? String { percent = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let p = percent, p.isFinite, p >= 0 else { return nil }
        var reset: Date?
        if let s = w["resetsAt"] as? String { reset = parseGoDate(s) }
        let win = GoWindow(status: status, percent: p, resetsAt: reset)
        return win.isUsable ? win : nil
    }
    let g = GoUsage(rolling: window("rolling"), weekly: window("weekly"), monthly: window("monthly"))
    guard !g.available.isEmpty else { throw GoDecodeError.malformed }
    return g
}

// MARK: - Fetch outcome taxonomy (HTTP status → user-facing state)

public enum GoFetchState: Equatable {
    case ready(GoUsage, source: String)
    case noKey
    case authFailed          // 401
    case subscriptionUnavailable // 403: key valid-ish but no Go entitlement for it
    case rateLimitedHTTP     // 429
    case providerDown        // 5xx
    case offline             // transport failure
    case unexpected(String)  // malformed 200 etc.
}

public func goStateForStatus(_ code: Int) -> GoFetchState? {
    switch code {
    case 200: return nil // decode body instead
    case 401: return .authFailed
    case 403: return .subscriptionUnavailable
    case 429: return .rateLimitedHTTP
    case 500...599: return .providerDown
    default: return .unexpected("HTTP \(code)")
    }
}

// MARK: - Display helpers

/// Compact companion for dense surfaces: "3h 29m left" / "2d left".
/// `resetText` stays the full sentence for alerts and History.
public func remainingText(until date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let secs = max(0, Int(date.timeIntervalSince(now)))
    if secs < 90 { return "\(secs)s left" }
    let mins = secs / 60
    if mins < 90 { return "\(mins)m left" }
    let hours = mins / 60
    if hours < 48 {
        let m = mins % 60
        return m == 0 ? "\(hours)h left" : "\(hours)h \(m)m left"
    }
    let days = hours / 24
    if days < 14 { return "\(days)d left" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

public func resetText(until date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let secs = max(0, Int(date.timeIntervalSince(now)))
    if secs < 90 { return "resets in \(secs)s" }
    let mins = secs / 60
    if mins < 90 { return "resets in \(mins)m" }
    let hours = mins / 60
    if hours < 48 {
        let m = mins % 60
        return m == 0 ? "resets in \(hours)h" : "resets in \(hours)h \(m)m"
    }
    let days = hours / 24
    if days < 14 { return "resets in \(days)d" }
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return "resets \(f.string(from: date))"
}

public func usageColorName(for percent: Double) -> String {
    switch percent {
    case ..<50: return "green"
    case ..<75: return "yellow"
    case ..<90: return "orange"
    default: return "red"
    }
}
