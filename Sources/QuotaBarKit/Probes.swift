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

/// Where Codex numbers come from.
///
/// - `http` (default): the long-standing private endpoint. No local process.
/// - `appServer`: the Codex CLI's typed local RPC only. Chosen deliberately for
///   its extra payload (per-limit buckets, plan, reset credits) and because it
///   makes no network request of its own; a failure is reported, not hidden.
/// - `automatic`: the RPC when it answers, HTTP otherwise.
public enum CodexSource: String, Sendable {
    case http
    case appServer
    case automatic
}

/// The three probe entry points the model needs. `QuotaProbes` is the real
/// implementation; the protocol exists so a test can control timing and source
/// switches instead of hitting the network.
public protocol ProbeProviding: Sendable {
    var codexSource: CodexSource { get }
    func go(now: Date) async -> ProbeResult
    func codex(now: Date) async -> ProbeResult
    func commandCode(now: Date) async -> ProbeResult
    /// Used only by the in-app "Enter API key…" flow, which validates a key
    /// before saving it.
    func fetchGo(key: String, source: String) async -> GoFetchState
}

public struct QuotaProbes {
    private let session: URLSession
    public let codexSource: CodexSource

    public init(session: URLSession = .shared, codexSource: CodexSource = .http) {
        self.session = session
        self.codexSource = codexSource
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

    // MARK: Command Code

    public func commandCode(now: Date = Date()) async -> ProbeResult {
        guard let key = CommandCode.discoverKey() else {
            return .failed(.noCredentials, "No Command Code API key found.")
        }
        async let creditsResponse = fetchCommandCode(path: "/alpha/billing/credits", key: key)
        async let subscriptionResponse = fetchCommandCode(path: "/alpha/billing/subscriptions", key: key)
        let (credits, subscription) = await (creditsResponse, subscriptionResponse)

        let data: Data
        switch credits {
        case let .success((body, status)) where status == 200:
            data = body
        case let .success((_, status)):
            switch status {
            case 401: return .failed(.authFailed, "Command Code key rejected (401).")
            case 403: return .failed(.entitlementMissing, "Command Code rejected the key (403).")
            case 429: return .failed(.rateLimited, "Command Code is rate limiting (429).")
            case 500...599: return .failed(.providerDown, "api.commandcode.ai is having issues (\(status)).")
            default: return .failed(.badResponse, "Unexpected response (HTTP \(status)).")
            }
        case .failure:
            return .failed(.offline, "Can't reach api.commandcode.ai.")
        }

        let report: CommandCodeCredits
        do {
            report = try CommandCode.decodeCredits(data)
        } catch {
            return .failed(.badResponse, "Unreadable response from api.commandcode.ai.")
        }

        var sub: CommandCodeSubscription?
        if case let .success((body, status)) = subscription, status == 200 {
            sub = try? CommandCode.decodeSubscription(body)
        }

        return .ok(ProviderSnapshot(
            provider: .commandCode,
            windows: CommandCode.windows(report, subscription: sub),
            plan: CommandCode.planName(for: sub?.planId),
            accountRef: accountRef(sub?.userId),
            origin: .network,
            source: "api.commandcode.ai",
            observedAt: now,
            facts: CommandCode.facts(report, subscription: sub, now: now)
        ))
    }

    private func fetchCommandCode(path: String, key: String) async -> Result<(Data, Int), Error> {
        guard let url = URL(string: CommandCode.baseURL + path) else {
            return .failure(URLError(.badURL))
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(CommandCode.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(URLError(.badServerResponse))
            }
            return .success((data, http.statusCode))
        } catch {
            return .failure(error)
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
        if codexSource != .http {
            // A child process with a hard timeout, run off the cooperative pool.
            let outcome = await Task.detached(priority: .utility) { () -> Result<CodexAppServerUsage, CodexAppServerError> in
                do {
                    return .success(try CodexAppServer.fetchUsage(timeout: 12, now: now))
                } catch let error as CodexAppServerError {
                    return .failure(error)
                } catch {
                    // Any non-protocol failure is a launch problem; the detail
                    // is untrusted and is intentionally not carried.
                    return .failure(.launch)
                }
            }.value
            switch outcome {
            case let .success(usage):
                var facts: [String] = []
                if let credits = usage.resetCreditsAvailable, credits > 0 {
                    facts.append("\(credits) reset credit\(credits == 1 ? "" : "s")")
                }
                if usage.hasCredits == true, let balance = usage.creditBalance, balance != "0" {
                    facts.append("Credits \(balance)")
                }
                return .ok(ProviderSnapshot(
                    provider: .codex,
                    windows: usage.windows,
                    plan: usage.plan,
                    accountRef: accountRef(usage.accountId),
                    origin: .network,
                    source: "codex app-server",
                    observedAt: now,
                    facts: facts
                ))
            case let .failure(error):
                if codexSource == .appServer {
                    // Strict mode: the user chose a local-only source, so a
                    // quiet fall back to chatgpt.com would break that promise.
                    return .failed(error.healthState, error.message)
                }
                // Automatic: a missing binary, a logged-out CLI or a protocol
                // change must degrade, not blank the card.
            }
        }
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
            // Local logs are device-level; no trustworthy account identity.
            accountRef: nil,
            origin: .localLog,
            source: "Codex local session log",
            observedAt: local.observedAt
        )
        return .stale(snapshot, state, message + " Showing the last local Codex snapshot.")
    }
}

extension QuotaProbes: ProbeProviding {
    /// The protocol surface drops the optional credential override.
    public func codex(now: Date) async -> ProbeResult {
        await codex(now: now, credentials: nil)
    }
}
