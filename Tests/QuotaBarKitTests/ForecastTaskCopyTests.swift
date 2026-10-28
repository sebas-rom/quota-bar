import XCTest
@testable import QuotaBarKit

/// The task-length variant of the forecast line. It must only ever restate what
/// the forecast already proved, must stay away from rolling windows, and must
/// never describe the 95% threshold as exhaustion or a block.
final class ForecastTaskCopyTests: XCTestCase {
    func testTransitionInsideTaskMentionsBothDurations() {
        let line = ForecastCopy.taskRiskLine(
            for: .approaching95(minutes: 30, resetMinutes: 120),
            taskMinutes: 60,
            rolling: false
        )
        XCTAssertEqual(line, "At recent pace, 95% in ~30m — inside your 1h task")
    }

    func testTransitionAfterTheTaskStaysSilent() {
        XCTAssertNil(ForecastCopy.taskRiskLine(
            for: .approaching95(minutes: 60, resetMinutes: 120),
            taskMinutes: 45,
            rolling: false
        ))
    }

    func testRollingWindowsAreExcluded() {
        XCTAssertNil(ForecastCopy.taskRiskLine(
            for: .approaching95(minutes: 10, resetMinutes: 120),
            taskMinutes: 60,
            rolling: true
        ), "a rolling reset has no stable boundary to compare against")
    }

    func testNonApproachingStatesKeepThePlainLine() {
        XCTAssertNil(ForecastCopy.taskRiskLine(for: .below95(resetMinutes: 60), taskMinutes: 60, rolling: false))
        XCTAssertNil(ForecastCopy.taskRiskLine(for: .already95(resetMinutes: 60), taskMinutes: 60, rolling: false))
        XCTAssertNil(ForecastCopy.taskRiskLine(for: .collecting, taskMinutes: 60, rolling: false))
        XCTAssertNil(ForecastCopy.taskRiskLine(for: .unavailable("beyond horizon"), taskMinutes: 60, rolling: false))
    }

    func testNonPositiveTaskLengthIsIgnored() {
        XCTAssertNil(ForecastCopy.taskRiskLine(
            for: .approaching95(minutes: 10, resetMinutes: 60),
            taskMinutes: 0,
            rolling: false
        ))
    }

    func testCopyNeverClaimsExhaustionOrBlocking() {
        let states: [ForecastState] = [
            .approaching95(minutes: 15, resetMinutes: 60),
            .approaching95(minutes: 240, resetMinutes: 400),
            .already95(resetMinutes: 30),
            .below95(resetMinutes: 30),
        ]
        for state in states {
            for minutes in [25, 60, 180] {
                let line = ForecastCopy.taskRiskLine(for: state, taskMinutes: minutes, rolling: false) ?? ""
                let lower = line.lowercased()
                XCTAssertFalse(lower.contains("exhaust"))
                XCTAssertFalse(lower.contains("block"))
                XCTAssertFalse(lower.contains("guarantee"))
            }
        }
    }

    func testLongTaskUsesHourFormatting() {
        let line = ForecastCopy.taskRiskLine(
            for: .approaching95(minutes: 120, resetMinutes: 400),
            taskMinutes: 180,
            rolling: false
        )
        XCTAssertEqual(line, "At recent pace, 95% in ~2h — inside your 3h task")
    }
}
