import Foundation
import Darwin

// MARK: - Codex app-server source (read-only)
//
// The Codex CLI ships a typed local RPC (`codex app-server`) with
// `account/rateLimits/read`. Compared with the private chatgpt.com endpoint it
// adds per-limit buckets, plan type and the reset-credit inventory, and it talks
// to the account the CLI is actually signed into.
//
// It is a child process, not a URL, so this is deliberately conservative:
//   * read-only calls only — `account/rateLimitResetCredit/consume` exists in
//     the protocol and is never called here;
//   * one request, one response, hard timeout, the process is always killed;
//   * no shell, no arguments, a located absolute binary;
//   * nothing is written to disk and no tokens are read.
//
// Anything unexpected becomes an error the caller can fall back from.

public struct CodexAppServerUsage: Equatable, Sendable {
    public let windows: [QuotaWindow]
    public let plan: String?
    public let hasCredits: Bool?
    public let creditBalance: String?
    public let resetCreditsAvailable: Int?
    public let limitReached: Bool
    /// Raw account id — callers hash it with `accountRef` before display.
    public let accountId: String?
    public let ordinaryUsageAllowed: Bool?
}

public enum CodexAppServerError: Error, Equatable {
    case binaryNotFound
    case launch
    case timeout
    case protocolError
    case notSignedIn

    /// What the card should say when this is the source of truth.
    public var healthState: HealthState {
        switch self {
        case .notSignedIn: return .noCredentials
        case .protocolError: return .badResponse
        case .binaryNotFound, .launch, .timeout: return .providerDown
        }
    }

    /// Fixed, human-facing explanation. Deliberately carries no child-process
    /// text: stderr and JSON-RPC error strings are untrusted diagnostics and can
    /// contain tokens, account ids or private paths. They are inspected for a
    /// sign-in hint and then discarded, never stored, displayed or logged.
    public var message: String {
        switch self {
        case .binaryNotFound:
            return "codex CLI not found (looked in PATH, /opt/homebrew/bin, /usr/local/bin, ~/.local/bin)"
        case .launch:
            return "Could not start the codex CLI"
        case .timeout:
            return "codex app-server did not answer in time"
        case .protocolError:
            return "codex app-server returned an unexpected reply"
        case .notSignedIn:
            return "codex CLI is not signed in"
        }
    }

    /// True when untrusted text hints at an authentication problem. Used only to
    /// pick a fixed category; the text itself is never propagated.
    static func hintsAtMissingSignIn(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let hints = ["login", "log in", "sign in", "signed in", "sign-in", "unauthorized"]
        return hints.contains(where: lowered.contains)
    }
}

public enum CodexAppServer {
    /// Where a Finder-launched app can actually find the CLI. A menu-bar app
    /// inherits launchd's PATH, which usually has none of these.
    public static func defaultBinaryPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var paths: [String] = []
        let home = homeDir().path
        paths.append("/opt/homebrew/bin/codex")
        paths.append("/usr/local/bin/codex")
        paths.append("\(home)/.local/bin/codex")
        paths.append("\(home)/.bun/bin/codex")
        paths.append("\(home)/.npm-global/bin/codex")
        if let raw = environment["PATH"] {
            for dir in raw.split(separator: ":") {
                paths.append("\(dir)/codex")
            }
        }
        return paths
    }

    public static func locateBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        extraPaths: [String] = []
    ) -> URL? {
        let manager = FileManager.default
        for candidate in extraPaths + defaultBinaryPaths(environment: environment) {
            var isDir: ObjCBool = false
            if manager.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue,
               manager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Runs `codex app-server`, initializes the session, reads rate limits, and
    /// always kills the child. Throws instead of guessing.
    public static func fetchUsage(
        timeout: TimeInterval = 12,
        binary: URL? = nil,
        now: Date = Date()
    ) throws -> CodexAppServerUsage {
        guard let binary = binary ?? locateBinary() else { throw CodexAppServerError.binaryNotFound }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launch
        }
        defer {
            // SIGTERM first, then SIGKILL, then a bounded wait so the child is
            // actually reaped instead of left as a zombie for the app's
            // lifetime. Closing the pipes also ends the CLI's inner process on
            // EOF. `waitUntilExit` returns immediately once the child is dead.
            if process.isRunning { process.terminate() }
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(timeout)
        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        let outputFD = stdout.fileHandleForReading.fileDescriptor
        let errorFD = stderr.fileHandleForReading.fileDescriptor
        var buffer = Data()

        func send(_ object: [String: Any]) throws {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else {
                throw CodexAppServerError.protocolError
            }
            var payload = data
            payload.append(0x0A)
            try writeAll(payload, to: inputFD)
        }

        func nextLine() throws -> String {
            while true {
                if let index = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<index]
                    buffer.removeSubrange(buffer.startIndex...index)
                    if let text = String(data: line, encoding: .utf8) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                    continue
                }
                let chunk = try readChunk(from: outputFD, until: deadline)
                if chunk.isEmpty {
                    // EOF: the process died. The stderr tail is inspected for a
                    // sign-in hint and then dropped; only the category survives.
                    if let tail = try? readChunk(from: errorFD, until: Date().addingTimeInterval(0.2)),
                       !tail.isEmpty, let text = String(data: tail, encoding: .utf8),
                       CodexAppServerError.hintsAtMissingSignIn(text) {
                        throw CodexAppServerError.notSignedIn
                    }
                    throw CodexAppServerError.protocolError
                }
                buffer.append(chunk)
            }
        }

        func response(id: Int) throws -> [String: Any] {
            while true {
                let line = try nextLine()
                guard let data = line.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    continue // notifications are not our reply
                }
                if let error = object["error"] as? [String: Any] {
                    let message = (error["message"] as? String) ?? ""
                    if CodexAppServerError.hintsAtMissingSignIn(message) {
                        throw CodexAppServerError.notSignedIn
                    }
                    throw CodexAppServerError.protocolError
                }
                guard (object["id"] as? Int) == id || (object["id"] as? NSNumber)?.intValue == id else { continue }
                return object
            }
        }

        try send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "quotabar", "version": "1.0"]],
        ])
        _ = try response(id: 1)

        try send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [:]])
        let reply = try response(id: 2)
        guard let result = reply["result"] as? [String: Any] else {
            throw CodexAppServerError.protocolError
        }
        return try decodeRateLimits(result, now: now)
    }

    // MARK: raw pipe IO
    //
    // `FileHandle.read(upToCount:)` on a Process pipe can block indefinitely on
    // current macOS, which would also defeat the timeout below: a child that
    // never answers would hang the probe forever instead of failing it. `poll`
    // gives the deadline real teeth, and raw `read` avoids the Foundation path.

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                throw CodexAppServerError.launch
            }
        }
    }

    /// One chunk from `fd`, waiting until the deadline. An empty result means
    /// EOF; a missed deadline throws `.timeout`.
    private static func readChunk(from fd: Int32, until deadline: Date) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexAppServerError.timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(remaining * 1000, 2_000_000))
            let ready = poll(&descriptor, 1, max(1, milliseconds))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw CodexAppServerError.launch
            }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { return Data(bytes[0..<Int(count)]) }
            if count == 0 { return Data() }
            if errno == EINTR || errno == EAGAIN { continue }
            throw CodexAppServerError.launch
        }
    }

    /// Pure decoder for the `account/rateLimits/read` result. Exposed for tests
    /// so the mapping is exercised without spawning a process.
    public static func decodeRateLimits(_ result: Any, now: Date = Date()) throws -> CodexAppServerUsage {
        guard let root = result as? [String: Any] else {
            throw CodexAppServerError.protocolError
        }
        let primary = root["rateLimits"] as? [String: Any]
        var windows: [QuotaWindow] = []

        func window(_ raw: Any?, id: String, kind: WindowKind, reached: String?, role: String) -> QuotaWindow? {
            guard let w = raw as? [String: Any] else { return nil }
            guard let percent = (w["usedPercent"] as? NSNumber)?.doubleValue, percent.isFinite else { return nil }
            let minutes = (w["windowDurationMins"] as? NSNumber)?.intValue
            let reset = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            // `rateLimitReachedType` names the bucket the provider says is
            // exhausted. Applying it to every bucket would claim a limit the
            // provider never reported.
            let named = reached?.lowercased().hasPrefix(role) ?? false
            return QuotaWindow(
                id: id,
                kind: kind,
                label: minutes.map { windowLabel(forSeconds: $0 * 60) } ?? "Window",
                percent: percent,
                resetsAt: reset,
                windowMinutes: minutes,
                isLimited: named && percent >= 99
            )
        }

        if let primary {
            let reached = primary["rateLimitReachedType"] as? String
            if let w = window(primary["primary"], id: "codex.primary", kind: .primary, reached: reached, role: "primary") {
                windows.append(w)
            }
            if let w = window(primary["secondary"], id: "codex.secondary", kind: .secondary, reached: reached, role: "secondary") {
                windows.append(w)
            }
        }

        // Additional model/feature buckets, keyed by their own limit id.
        if let byId = root["rateLimitsByLimitId"] as? [String: Any] {
            for key in byId.keys.sorted() where key != "codex" {
                guard let bucket = byId[key] as? [String: Any] else { continue }
                let reached = bucket["rateLimitReachedType"] as? String
                if let w = window(bucket["primary"], id: "codex.extra.\(key).primary", kind: .additional, reached: reached, role: "primary") {
                    windows.append(w)
                }
                if let w = window(bucket["secondary"], id: "codex.extra.\(key).secondary", kind: .additional, reached: reached, role: "secondary") {
                    windows.append(w)
                }
            }
        }

        guard !windows.isEmpty else {
            throw CodexAppServerError.protocolError
        }

        let credits = primary?["credits"] as? [String: Any]
        let resetCredits = root["rateLimitResetCredits"] as? [String: Any]
        let plan = primary?["planType"] as? String
        let accountId = root["accountId"] as? String

        return CodexAppServerUsage(
            windows: windows,
            plan: plan,
            hasCredits: credits?["hasCredits"] as? Bool,
            creditBalance: credits?["balance"] as? String,
            resetCreditsAvailable: (resetCredits?["availableCount"] as? NSNumber)?.intValue,
            limitReached: (primary?["rateLimitReachedType"] as? String) != nil,
            accountId: accountId,
            ordinaryUsageAllowed: root["ordinaryUsageAllowed"] as? Bool
        )
    }
}
