import Foundation
import Darwin
import QuotaBarKit

// `qbar --forecast-backtest` — read-only replay report. Never writes, probes,
// or reads credentials. `insufficient_data` is the expected initial result.

enum ForecastBacktestCLI {
    // The shipped forecast only exists for 5-hour windows, so only fixed-cycle
    // 5-hour windows are scored. Weekly/monthly projections are not shown in the
    // app, and monthly cycles cannot accumulate 20 samples within retention.
    private static let windows: [(ProviderID, String, Int)] = [
        (.commandCode, "commandcode.5h", 300),
    ]

    // Sliding windows have no fixed cycle boundary to score without inventing
    // an outcome contract; they are disclosed, not silently dropped.
    private static let notEvaluated: [BacktestNotEvaluated] = [
        BacktestNotEvaluated(
            provider: ProviderID.go.rawValue,
            windowId: "go.rolling",
            reason: "rolling 5-hour window: reset advances with time, no fixed cycle to score"
        ),
        BacktestNotEvaluated(
            provider: ProviderID.codex.rawValue,
            windowId: "codex.primary",
            reason: "rolling 5-hour window: reset advances with time, no fixed cycle to score"
        ),
    ]

    static func run() -> Never {
        let url = TelemetryStore.defaultPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            emitError("no local history store; launch QuotaBar once")
        }
        guard let store = try? TelemetryStore(path: url, createDirectory: false, readOnly: true) else {
            emitError("cannot open the local history store")
        }
        let now = Date()
        let since = now.addingTimeInterval(-90 * 86_400)
        let groups = windows.compactMap { provider, windowID, minutes -> BacktestGroup? in
            let samples = store.networkSamples(provider: provider, windowID: windowID, since: since)
            guard !samples.isEmpty else { return nil }
            return ForecastBacktest.evaluate(
                provider: provider,
                windowID: windowID,
                windowMinutes: minutes,
                samples: samples,
                now: now
            )
        }
        let report = ForecastBacktest.report(groups: groups, notEvaluated: notEvaluated, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) else {
            emitError("failed to encode report")
        }
        print(json)
        exit(0)
    }

    private static func emitError(_ message: String) -> Never {
        // Same envelope key as the report: one decoder handles success and
        // failure instead of special-casing `schema_version` on errors only.
        let payload: [String: Any] = ["schemaVersion": 1, "error": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit(2)
    }
}
