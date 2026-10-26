import Foundation

// MARK: - Probes
//
// Each provider answers one question: "what is the current observation?".
// The model owns last-known-good state and history; probes stay stateless.

public enum ProbeResult: Equatable {
    case ok(ProviderSnapshot)
    /// Live probe failed but a timestamped local observation exists.
    case stale(ProviderSnapshot, HealthState, String)
    case failed(HealthState, String)
}

public struct QuotaProbes {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Go

    public func go(now: Date = Date()) async -> ProbeResult {
        let candidates = goKeyCandidates()
        guard !candidates.isEmpty else {
            return .failed(.noCredentials, "No API key found on disk.")
        }
        var lastState: GoFetchState = .noKey
        for cand in candidates {
            let state = await fetchGo(key: cand.key, source: cand.source)
            switch state {
            case let .ready(usage, source):
                return .ok(Self.snapshot(usage: usage, source: source, now: now))
            case .authFailed, .subscriptionUnavailable:
                lastState = state
                continue
            default:
                return .failed(Self.health(for: state), Self.message(for: state))
            }
        }
        return .failed(Self.health(for: lastState), Self.message(for: lastState))
    }

    public static func goRequest(key: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        return req
    }

    /// Used by key-entry validation; returns the raw Go state so copy stays specific.
    public func fetchGo(key: String, source: String) async -> GoFetchState {
        let req = Self.goRequest(key: key)
        let data: Data
        let status: Int
        do {
            let (d, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .unexpected("bad response") }
            data = d
            status = http.statusCode
        } catch {
            return .offline
        }
        if status != 200 {
            return goStateForStatus(status) ?? .unexpected("HTTP \(status)")
        }
        do {
            return .ready(try decodeGoUsage(data), source: source)
        } catch {
            return .unexpected("unreadable response")
        }
    }

    static func snapshot(usage: GoUsage, source: String, now: Date) -> ProviderSnapshot {
        var windows: [QuotaWindow] = []
        func add(_ w: GoWindow?, id: String, label: String, minutes: Int, kind: WindowKind) {
            guard let w else { return }
            windows.append(QuotaWindow(
                id: id, kind: kind, label: label,
                percent: w.percent, resetsAt: w.resetsAt,
                windowMinutes: minutes, isLimited: w.isRateLimited
            ))
        }
        add(usage.rolling, id: "go.rolling", label: "5-hour", minutes: 300, kind: .rolling)
        add(usage.weekly, id: "go.weekly", label: "Weekly", minutes: 10_080, kind: .weekly)
        add(usage.monthly, id: "go.monthly", label: "Monthly", minutes: 43_200, kind: .monthly)
        return ProviderSnapshot(
            provider: .go,
            windows: windows,
            plan: nil,
            accountRef: nil,
            origin: .network,
            source: source == "Keychain" ? "saved key" : source,
            observedAt: now
        )
    }

    static func health(for state: GoFetchState) -> HealthState {
        switch state {
        case .ready: return .ok
        case .noKey: return .noCredentials
        case .authFailed: return .authFailed
        case .subscriptionUnavailable: return .entitlementMissing
        case .rateLimitedHTTP: return .rateLimited
        case .providerDown: return .providerDown
        case .offline: return .offline
        case .unexpected: return .badResponse
        }
    }

    static func message(for state: GoFetchState) -> String {
        switch state {
        case .ready: return ""
        case .noKey: return "No API key found on disk."
        case .authFailed: return "Key rejected (401)."
        case .subscriptionUnavailable: return "No Go subscription for this key (403)."
        case .rateLimitedHTTP: return "Rate limited (429). Retrying automatically."
        case .providerDown: return "opencode.ai is having issues (5xx)."
        case .offline: return "No connection. Retrying automatically."
        case let .unexpected(m): return "Unexpected response (\(m))."
        }
    }

    // MARK: Codex

    public static func codexRequest(token: String, accountId: String?) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.timeoutInterval = 15
        return req
    }

    public func codex(now: Date = Date(), credentials: CodexCreds? = nil) async -> ProbeResult {
        guard let creds = credentials ?? readCodexCreds() else {
            return .failed(.noCredentials, "No token in ~/.codex/auth.json.")
        }
        let ref = accountRef(creds.accountId)
        let req = Self.codexRequest(token: creds.token, accountId: creds.accountId)

        let data: Data
        let status: Int
        do {
            let (d, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return Self.codexFallback(state: .badResponse, message: "Unexpected response.", accountRef: ref)
            }
            data = d
            status = http.statusCode
        } catch {
            return Self.codexFallback(state: .offline, message: "Can't reach chatgpt.com.", accountRef: ref)
        }

        guard status == 200 else {
            switch status {
            case 401: return Self.codexFallback(state: .authFailed, message: "Codex token rejected (401). Sign in again with the Codex CLI.", accountRef: ref)
            case 429: return Self.codexFallback(state: .rateLimited, message: "ChatGPT is rate limiting (429).", accountRef: ref)
            case 500...599: return Self.codexFallback(state: .providerDown, message: "ChatGPT is having issues (\(status)).", accountRef: ref)
            default: return Self.codexFallback(state: .badResponse, message: "Unexpected response (HTTP \(status)).", accountRef: ref)
            }
        }

        do {
            let report = try decodeCodexUsage(data, now: now)
            var facts: [String] = []
            if let credits = report.resetCreditsAvailable, credits > 0 {
                facts.append("\(credits) reset credit\(credits == 1 ? "" : "s")")
            }
            if report.hasCredits == true, let balance = report.creditBalance, balance != "0" {
                facts.append("Credits \(balance)")
            }
            return .ok(ProviderSnapshot(
                provider: .codex,
                windows: report.windows,
                plan: report.plan,
                // Prefer the CLI account identity so live and local-log rows
                // share one namespace (they can diverge on workspace ids).
                accountRef: ref ?? report.accountRef,
                origin: .network,
                source: "chatgpt.com/backend-api/wham/usage",
                observedAt: now,
                facts: facts
            ))
        } catch {
            return Self.codexFallback(state: .badResponse, message: "Unreadable response from chatgpt.com.", accountRef: ref)
        }
    }

    static func codexFallback(state: HealthState, message: String, accountRef: String? = nil) -> ProbeResult {
        guard let local = CodexLocalLog.latest() else {
            return .failed(state, message)
        }
        let snapshot = ProviderSnapshot(
            provider: .codex,
            windows: local.windows,
            plan: local.plan,
            accountRef: accountRef,
            origin: .localLog,
            source: "Codex local session log",
            observedAt: local.observedAt
        )
        return .stale(snapshot, state, message + " Showing the last local Codex snapshot.")
    }
}
