import SwiftUI

// QuotaBar — minimal menu-bar: opencode-go + Codex (ChatGPT), local-auth only.
// Reads tokens already on disk, calls 2 GET endpoints, no browser, no keychain.

struct GoState {
    var keyPresent = false
    var keyValid: Bool? = nil
    var modelCount: Int? = nil
    var rolling: Double? = nil
    var weekly: Double? = nil
    var monthly: Double? = nil
    var note = "—"
}

struct CodexState {
    var tokenPresent = false
    var primary: Double? = nil
    var secondary: Double? = nil
    var plan: String? = nil
    var note = "—"
}

func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

func readGoKey() -> String? {
    var paths: [URL] = []
    if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
        paths.append(URL(fileURLWithPath: NSString(string: xdg).expandingTildeInPath).appendingPathComponent("opencode/auth.json"))
    }
    paths.append(home().appendingPathComponent(".local/share/opencode/auth.json"))
    paths.append(home().appendingPathComponent("Library/Application Support/opencode/auth.json"))
    for url in paths {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        if let entry = obj["opencode-go"] as? [String: Any] {
            for k in ["key", "access", "token", "apiKey", "value"] {
                if let v = entry[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
            }
        } else if let s = obj["opencode-go"] as? String, !s.isEmpty { return s }
    }
    return nil
}

struct CodexCreds { let token: String; let accountId: String? }

func readCodexCreds() -> CodexCreds? {
    let url = home().appendingPathComponent(".codex/auth.json")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let t = obj["tokens"] as? [String: Any],
          let access = t["access_token"] as? String, !access.isEmpty else { return nil }
    let aid = (t["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return CodexCreds(token: access, accountId: aid)
}

struct GoDashboardCreds { let workspaceId: String; let cookie: String }

func readGoDashboardCreds() -> GoDashboardCreds? {
    let env = ProcessInfo.processInfo.environment
    if let w = env["OPENCODE_GO_WORKSPACE_ID"], let c = env["OPENCODE_GO_AUTH_COOKIE"], !w.isEmpty, !c.isEmpty {
        return GoDashboardCreds(workspaceId: w, cookie: c)
    }
    let candidates = [
        home().appendingPathComponent(".config/quota-bar/opencode-go.json"),
        home().appendingPathComponent(".config/opencode-bar/opencode-go.json"),
    ]
    for url in candidates {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let w = (obj["workspaceId"] as? String) ?? (obj["workspaceID"] as? String) ?? (obj["workspace_id"] as? String)
        let c = (obj["authCookie"] as? String) ?? (obj["auth_cookie"] as? String) ?? (obj["cookie"] as? String)
        if let w, let c, !w.isEmpty, !c.isEmpty { return GoDashboardCreds(workspaceId: w, cookie: c) }
    }
    return nil
}

func num(_ body: String, _ field: String) -> Double? {
    let pat = #"["']?"# + NSRegularExpression.escapedPattern(for: field) + #"["']?\s*:\s*"?(-?\d+(?:\.\d+)?)"?"#
    guard let re = try? NSRegularExpression(pattern: pat),
          let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
          let r = Range(m.range(at: 1), in: body) else { return nil }
    return Double(body[r])
}

func windowObj(_ text: String, _ name: String) -> String? {
    let pat = #"["']?"# + NSRegularExpression.escapedPattern(for: name) + #"["']?\s*:\s*(?:\$R\[\d+\]\s*=\s*)?\{([^{}]*)\}"#
    guard let re = try? NSRegularExpression(pattern: pat, options: [.dotMatchesLineSeparators]),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

@MainActor
final class Model: ObservableObject {
    @Published var go = GoState()
    @Published var codex = CodexState()
    @Published var lastUpdate: Date? = nil
    @Published var busy = false

    var barText: String {
        var parts: [String] = []
        if let w = go.weekly { parts.append("Go \(Int(w.rounded()))%") }
        else if go.keyPresent { parts.append("Go …") }
        if let p = codex.primary { parts.append("Cx \(Int(p.rounded()))%") }
        else if codex.tokenPresent { parts.append("Cx …") }
        return parts.isEmpty ? "○" : parts.joined(separator: " · ")
    }

    func refresh() async {
        if busy { return }
        busy = true
        defer { busy = false }
        async let g: Void = loadGo()
        async let c: Void = loadCodex()
        _ = await (g, c)
        lastUpdate = Date()
    }

    func loadGo() async {
        guard let key = readGoKey() else {
            go = GoState(keyPresent: false, note: "no key in opencode auth.json")
            return
        }
        var st = GoState(keyPresent: true, note: "checking…")
        self.go = st
        // 1) validate key + model count
        do {
            var req = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/models")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try? JSONSerialization.jsonObject(with: data)
            if let d = (obj as? [String: Any])?["data"] as? [Any] { st.modelCount = d.count; st.keyValid = true }
            else if let m = (obj as? [String: Any])?["models"] as? [Any] { st.modelCount = m.count; st.keyValid = true }
            else if (obj as? [Any]) != nil { st.modelCount = (obj as? [Any])?.count; st.keyValid = true }
            else { st.keyValid = true }
        } catch { st.keyValid = false; st.note = "key check failed (403?)" }
        // 2) dashboard windows (optional — needs workspace creds; try even if key check failed)
        guard let creds = readGoDashboardCreds(),
              let url = URL(string: "https://opencode.ai/workspace/\(creds.workspaceId)/go") else {
            st.note = "key OK (\(st.modelCount ?? 0) models) · link dashboard for %"
            self.go = st
            return
        }
        do {
            var req = URLRequest(url: url)
            req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let cookie = creds.cookie.contains("auth=") ? creds.cookie : "auth=\(creds.cookie)"
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/126.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: req)
            let html = String(data: data, encoding: .utf8) ?? ""
            if let b = windowObj(html, "rollingUsage") { st.rolling = num(b, "usagePercent") }
            if let b = windowObj(html, "weeklyUsage") { st.weekly = num(b, "usagePercent") }
            if let b = windowObj(html, "monthlyUsage") { st.monthly = num(b, "usagePercent") }
            st.note = (st.rolling ?? st.weekly ?? st.monthly) != nil ? "dashboard OK" : "dashboard changed"
        } catch { st.note = "dashboard fetch failed" }
        self.go = st
    }

    func loadCodex() async {
        guard let creds = readCodexCreds() else {
            codex = CodexState(tokenPresent: false, note: "no token in ~/.codex/auth.json")
            return
        }
        var st = CodexState(tokenPresent: true, note: "checking…")
        self.codex = st
        do {
            var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
            if let aid = creds.accountId { req.setValue(aid, forHTTPHeaderField: "ChatGPT-Account-Id") }
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { st.note = "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"; self.codex = st; return }
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            st.plan = obj["plan_type"] as? String
            if let rl = obj["rate_limit"] as? [String: Any] {
                // pick shortest window as primary (5h-style)
                var best: (String, Double, Int)? = nil
                for (k, v) in rl {
                    guard let w = v as? [String: Any],
                          let pct = (w["used_percent"] as? Double) ?? (w["used_percent"] as? Int).map(Double.init) else { continue }
                    let secs = (w["limit_window_seconds"] as? Int) ?? Int.max
                    if best == nil || secs < best!.2 { best = (k, pct, secs) }
                    if k == "primary_window" { st.primary = pct }
                    if k == "secondary_window" { st.secondary = pct }
                }
                if st.primary == nil { st.primary = best?.1 }
                // spark windows (optional, ignore for bar)
            }
            st.note = st.primary != nil ? "ok" : "no window"
        } catch { st.note = "fetch failed" }
        self.codex = st
    }
}

@main
struct QuotaBarApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        MenuBarExtra(model.barText, systemImage: "gauge") {
            VStack(alignment: .leading, spacing: 8) {
                Text("opencode-go").font(.headline)
                if !model.go.keyPresent { Text("no key in opencode auth.json").foregroundStyle(.secondary) }
                else {
                    if let w = model.go.weekly, let m = model.go.monthly, let r = model.go.rolling {
                        Text("5h \(Int(r.rounded()))% · 7d \(Int(w.rounded()))% · 30d \(Int(m.rounded()))%")
                    } else if let w = model.go.weekly { Text("weekly \(Int(w.rounded()))%") }
                    else { Text(model.go.keyValid == true ? "key OK (\(model.go.modelCount ?? 0) models)" : "checking…").foregroundStyle(.secondary) }
                    Text(model.go.note).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Codex").font(.headline)
                if !model.codex.tokenPresent { Text("no token in ~/.codex/auth.json").foregroundStyle(.secondary) }
                else {
                    if let p = model.codex.primary {
                        Text("primary \(Int(p.rounded()))%" + (model.codex.secondary.map { " · secondary \(Int($0.rounded()))%" } ?? ""))
                    } else { Text("checking…").foregroundStyle(.secondary) }
                    Text(([model.codex.plan, model.codex.note].compactMap { $0 }.joined(separator: " · "))).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if let t = model.lastUpdate { Text("updated \(t.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                Button(model.busy ? "Refreshing…" : "Refresh now") { Task { await model.refresh() } }.keyboardShortcut("r").disabled(model.busy)
                Button("Reveal auth files") {
                    NSWorkspace.shared.open(home().appendingPathComponent(".local/share/opencode"))
                    NSWorkspace.shared.open(home().appendingPathComponent(".codex"))
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
            .padding(8).frame(minWidth: 240)
                .task { await model.refresh() }
                .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
                    Task { await model.refresh() }
                }
        }
        .menuBarExtraStyle(.window)
    }
}
