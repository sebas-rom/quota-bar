import Foundation
import Darwin
import QuotaBarKit

// `QuotaBar --codex-app-server-probe`
//
// A one-shot, read-only check of the Codex CLI's local RPC. It exists so the
// app-server source can be validated by hand (and in a release rehearsal)
// before anyone relies on it: binary discovery, handshake, rate-limit payload,
// reset-credit inventory. Nothing is persisted and no credentials are printed —
// the account id is reduced to the same short hash the app uses.

enum CodexProbeCLI {
    struct WindowReport: Encodable {
        let id: String
        let label: String
        let percentUsed: Double
        let windowMinutes: Int?
        let resetsAt: Date?
        let limitReached: Bool
    }

    struct ProbeReport: Encodable {
        let ok: Bool
        let binary: String
        let plan: String?
        let accountRef: String?
        let ordinaryUsageAllowed: Bool?
        let resetCreditsAvailable: Int?
        let creditBalance: String?
        let windows: [WindowReport]
        let error: String?
    }

    static func run() -> Never {
        let binary = CodexAppServer.locateBinary()
        let report: ProbeReport
        do {
            let usage = try CodexAppServer.fetchUsage()
            report = ProbeReport(
                ok: true,
                binary: binary?.path ?? "",
                plan: usage.plan,
                accountRef: accountRef(usage.accountId),
                ordinaryUsageAllowed: usage.ordinaryUsageAllowed,
                resetCreditsAvailable: usage.resetCreditsAvailable,
                creditBalance: usage.creditBalance,
                windows: usage.windows.map {
                    WindowReport(
                        id: $0.id, label: $0.label, percentUsed: $0.percent,
                        windowMinutes: $0.windowMinutes, resetsAt: $0.resetsAt,
                        limitReached: $0.isLimited
                    )
                },
                error: nil
            )
        } catch {
            report = ProbeReport(
                ok: false,
                binary: binary?.path ?? "",
                plan: nil, accountRef: nil, ordinaryUsageAllowed: nil,
                resetCreditsAvailable: nil, creditBalance: nil, windows: [],
                error: describe(error)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit(report.ok ? 0 : 2)
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? CodexAppServerError else {
            return "unexpected probe failure"
        }
        return error.message
    }
}
