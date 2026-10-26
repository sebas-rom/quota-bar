import Foundation
import Combine

// MARK: - Provider snapshots (what the UI renders; never contains secrets)

public struct CodexSnapshot: Equatable {
    public var tokenPresent = false
    public var primary: Double?
    public var primaryReset: Date?
    public var secondary: Double?
    public var secondaryReset: Date?
    public var plan: String?
    public var note = "—"
    public init() {}
}

@MainActor
public final class QuotaModel: ObservableObject {
    @Published public var goState: GoFetchState = .noKey
    @Published public var codex = CodexSnapshot()
    @Published public var lastUpdate: Date?
    @Published public var busy = false

    private var generation = 0
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public var barText: String {
        var parts: [String] = []
        if case let .ready(usage, _) = goState, let lim = usage.limiting {
            parts.append("Go \(Int(lim.window.percent.rounded()))%")
        } else if !goKeyKnown {
            parts.append("Go …")
        }
        if let p = codex.primary {
            parts.append("Cx \(Int(p.rounded()))%")
        } else if codex.tokenPresent {
            parts.append("Cx …")
        }
        return parts.isEmpty ? "○" : parts.joined(separator: " · ")
    }

    public var goKeyKnown: Bool { !goKeyCandidates().isEmpty }

    public func refresh() async {
        if busy { return }
        busy = true
        defer { busy = false }
        generation += 1
        let gen = generation
        async let g: Void = loadGo(gen: gen)
        async let c: Void = loadCodex(gen: gen)
        _ = await (g, c)
        if gen == generation { lastUpdate = Date() }
    }

    // MARK: Go

    func loadGo(gen: Int) async {
        let candidates = goKeyCandidates()
        guard !candidates.isEmpty else {
            if gen == generation { goState = .noKey }
            return
        }
        var lastState: GoFetchState = .noKey
        for cand in candidates {
            let st = await fetchGo(key: cand.key, source: cand.source)
            // First success wins; keep probing other keys only on auth failure.
            if case .ready = st {
                if gen == generation { goState = st }
                return
            }
            lastState = st
            switch st {
            case .authFailed, .subscriptionUnavailable: continue
            default: break
            }
            break
        }
        if gen == generation { goState = lastState }
    }

    func fetchGo(key: String, source: String) async -> GoFetchState {
        var req = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let data: Data
        let status: Int
        do {
            let (d, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .unexpected("bad response") }
            data = d
            status = http.statusCode
        } catch {
            if (error as NSError).domain == NSURLErrorDomain { return .offline }
            return .offline
        }
        if status != 200 {
            return goStateForStatus(status) ?? .unexpected("HTTP \(status)")
        }
        do {
            let usage = try decodeGoUsage(data)
            return .ready(usage, source: source)
        } catch {
            return .unexpected("unreadable response")
        }
    }

    /// Validates a user-entered key against /usage; stores in Keychain on success.
    public func validateAndSaveGoKey(_ raw: String) async -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Enter a key first." }
        let st = await fetchGo(key: key, source: "entered key")
        switch st {
        case let .ready(usage, _):
            guard saveKeychainKey(account: quotaBarGoAccount, value: key) else {
                return "Key is valid but Keychain save failed."
            }
            goState = st
            _ = usage
            await refresh()
            return nil
        case .authFailed:
            return "That key was rejected (401). Check for typos or generate a fresh Personal API key."
        case .subscriptionUnavailable:
            return "Key accepted but no Go subscription for it (403). Use the console Personal API key for the right workspace."
        case .rateLimitedHTTP:
            return "Rate limited (429). Wait a minute and try again."
        case .providerDown:
            return "opencode.ai is having issues (5xx). Try again later."
        case .offline:
            return "No connection. Check network and retry."
        case let .unexpected(m):
            return "Unexpected response (\(m)). The API may have changed — try again later."
        case .noKey:
            return "Enter a key first."
        }
    }

    public func forgetGoKey() {
        deleteKeychainKey(account: quotaBarGoAccount)
        Task { await refresh() }
    }

    // MARK: Codex (unchanged endpoint, plus reset capture)

    func loadCodex(gen: Int) async {
        guard let creds = readCodexCreds() else {
            if gen == generation { codex = CodexSnapshot() }
            return
        }
        var st = CodexSnapshot()
        st.tokenPresent = true
        st.note = "checking…"
        if gen == generation { codex = st }
        do {
            var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
            if let aid = creds.accountId { req.setValue(aid, forHTTPHeaderField: "ChatGPT-Account-Id") }
            req.timeoutInterval = 15
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                st.note = "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                if gen == generation { codex = st }
                return
            }
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            st.plan = obj["plan_type"] as? String
            if let rl = obj["rate_limit"] as? [String: Any] {
                var best: (Double, Int)?
                for (k, v) in rl {
                    guard let w = v as? [String: Any],
                          let pct: Double = (w["used_percent"] as? Double) ?? (w["used_percent"] as? Int).map(Double.init)
                    else { continue }
                    let secs = (w["limit_window_seconds"] as? Int) ?? Int.max
                    if best == nil || secs < best!.1 { best = (pct, secs) }
                    let reset = (w["reset_after_seconds"] as? Int).map { Date().addingTimeInterval(TimeInterval($0)) }
                    if k == "primary_window" { st.primary = pct; st.primaryReset = reset }
                    if k == "secondary_window" { st.secondary = pct; st.secondaryReset = reset }
                }
                if st.primary == nil { st.primary = best?.0 }
            }
            st.note = st.primary != nil ? "ok" : "no window"
        } catch {
            st.note = "fetch failed"
        }
        if gen == generation { codex = st }
    }
}
