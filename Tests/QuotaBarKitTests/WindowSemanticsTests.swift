import XCTest
@testable import QuotaBarKit

/// Rolling-ness and forecastability used to be inferred from `WindowKind`,
/// which broke silently when Command Code's 5-hour window was reclassified as
/// `.primary`. These tests pin the shared answer so presentation, history,
/// replay and alerts cannot diverge again.
final class WindowSemanticsTests: XCTestCase {
    private func window(
        _ id: String,
        kind: WindowKind,
        minutes: Int? = 300,
        percent: Double = 10
    ) -> QuotaWindow {
        QuotaWindow(id: id, kind: kind, label: id, percent: percent,
                    resetsAt: Date().addingTimeInterval(3600), windowMinutes: minutes,
                    isLimited: false)
    }

    func testFiveHourWindowsAreForecastable() {
        XCTAssertTrue(WindowSemantics.isForecastable(window: window("go.rolling", kind: .rolling)))
        XCTAssertTrue(WindowSemantics.isForecastable(window: window("codex.primary", kind: .primary)))
        XCTAssertTrue(WindowSemantics.isForecastable(window: window("commandcode.5h", kind: .primary)))
    }

    func testLongWindowsAreNotForecastable() {
        XCTAssertFalse(WindowSemantics.isForecastable(window: window("go.weekly", kind: .weekly, minutes: 10_080)))
        XCTAssertFalse(WindowSemantics.isForecastable(window: window("codex.secondary", kind: .secondary, minutes: 10_080)))
        XCTAssertFalse(WindowSemantics.isForecastable(window: window("commandcode.monthly", kind: .monthly, minutes: 43_200)))
    }

    func testShortOrUnknownDurationIsNotForecastable() {
        XCTAssertFalse(WindowSemantics.isForecastable(window: window("x", kind: .primary, minutes: 60)))
        XCTAssertFalse(WindowSemantics.isForecastable(window: window("x", kind: .rolling, minutes: nil)))
    }

    func testOnlyGoAndCodexFiveHourWindowsRoll() {
        XCTAssertTrue(WindowSemantics.isRolling(provider: .go, window: window("go.rolling", kind: .rolling)))
        XCTAssertTrue(WindowSemantics.isRolling(provider: .codex, window: window("codex.primary", kind: .primary)))
        // Same kind, fixed 5-hour cycle: not rolling.
        XCTAssertFalse(WindowSemantics.isRolling(provider: .commandCode, window: window("commandcode.5h", kind: .primary)))
        XCTAssertFalse(WindowSemantics.isRolling(provider: .go, window: window("go.weekly", kind: .weekly, minutes: 10_080)))
    }

    func testCommandCodeFiveHourWindowIsPrimaryAndNotRolling() throws {
        let credits = CommandCodeCredits(
            monthlyRemaining: 50, fiveHourUsed: 10, fiveHourCap: 100,
            fiveHourReset: nil, fiveHourExceeded: false,
            weeklyUsed: 20, weeklyCap: 500, weeklyReset: nil, weeklyExceeded: false
        )
        let windows = CommandCode.windows(credits, subscription: nil)
        let fiveHour = try XCTUnwrap(windows.first { $0.id == "commandcode.5h" })
        XCTAssertEqual(fiveHour.kind, .primary)
        XCTAssertEqual(fiveHour.percent, 10, accuracy: 0.001)
        XCTAssertTrue(WindowSemantics.isForecastable(window: fiveHour))
        XCTAssertFalse(WindowSemantics.isRolling(provider: .commandCode, window: fiveHour))
    }
}
