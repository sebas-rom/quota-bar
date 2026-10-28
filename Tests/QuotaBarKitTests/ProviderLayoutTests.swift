import XCTest
@testable import QuotaBarKit

final class ProviderLayoutTests: XCTestCase {
    func testStandardLayoutKeepsEveryProviderVisibleInDefaultOrder() {
        let layout = ProviderLayout.standard
        XCTAssertEqual(layout.order, ProviderID.allCases)
        XCTAssertTrue(layout.hidden.isEmpty)
        XCTAssertEqual(layout.visible, ProviderID.allCases)
        XCTAssertEqual(layout.menuBarStyle, .all)
    }

    func testNormalizationDropsUnknownsDuplicatesAndAppendsMissingProviders() {
        let layout = ProviderLayout(
            order: [.codex, .codex],
            hidden: [.commandCode],
            menuBarStyle: .worst
        )
        let repaired = layout.normalized()
        XCTAssertEqual(repaired.order, [.codex, .go, .commandCode])
        XCTAssertEqual(repaired.hidden, [.commandCode])
        XCTAssertEqual(repaired.visible, [.codex, .go])
    }

    func testEmptyOrderFallsBackToDefault() {
        let repaired = ProviderLayout(order: [], hidden: [], menuBarStyle: .icon).normalized()
        XCTAssertEqual(repaired.order, ProviderID.allCases)
    }

    func testMoveUsesOffsetsAndKeepsEveryProvider() {
        var layout = ProviderLayout(order: [.go, .codex, .commandCode], hidden: [], menuBarStyle: .all)
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(layout.order, [.codex, .commandCode, .go])

        layout.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(layout.order, [.go, .codex, .commandCode])
        XCTAssertEqual(Set(layout.order), Set(ProviderID.allCases))
    }

    func testDecodingToleratesUnknownIdsAndUnknownStyle() throws {
        let json = """
        {"order":["future-provider","codex"],"hidden":["future-provider","commandcode"],"menuBarStyle":"sideways"}
        """
        let layout = try JSONDecoder().decode(ProviderLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout.order, [.codex, .go, .commandCode])
        XCTAssertEqual(layout.hidden, [.commandCode])
        XCTAssertEqual(layout.menuBarStyle, .all)
    }

    func testEncodingRoundTrips() throws {
        let original = ProviderLayout(
            order: [.commandCode, .go, .codex],
            hidden: [.go],
            menuBarStyle: .worst
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderLayout.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

final class MenuBarCompositionTests: XCTestCase {
    private func snapshot(_ provider: ProviderID, _ percent: Double, id: String = "w") -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            windows: [QuotaWindow(id: id, kind: .primary, label: "5-hour", percent: percent,
                                  resetsAt: nil, windowMinutes: 300, isLimited: false)],
            origin: .network,
            source: "test",
            observedAt: Date()
        )
    }

    func testAllPercentagesKeepProviderIdentityInUserOrder() {
        let layout = ProviderLayout(order: [.commandCode, .go, .codex], hidden: [], menuBarStyle: .all)
        let text = MenuBarComposition.text(
            style: .all,
            layout: layout,
            snapshots: [.go: snapshot(.go, 74), .codex: snapshot(.codex, 22), .commandCode: snapshot(.commandCode, 11)],
            health: [:]
        )
        XCTAssertEqual(text, "CC 11% · Go 74% · Cx 22%")
    }

    func testWorstOnlyKeepsShortNameAndSkipsProvidersWithoutReadings() {
        let layout = ProviderLayout(order: [.go, .codex, .commandCode], hidden: [.commandCode], menuBarStyle: .worst)
        let text = MenuBarComposition.text(
            style: .worst,
            layout: layout,
            snapshots: [.go: snapshot(.go, 74), .codex: snapshot(.codex, 88), .commandCode: snapshot(.commandCode, 99)],
            health: [.commandCode: ProviderHealth(state: .ok)]
        )
        XCTAssertEqual(text, "Cx 88%")
    }

    func testWorstOnlyBreaksTiesByUserOrder() {
        let layout = ProviderLayout(order: [.codex, .go], hidden: [], menuBarStyle: .worst)
        let text = MenuBarComposition.text(
            style: .worst,
            layout: layout,
            snapshots: [.go: snapshot(.go, 50), .codex: snapshot(.codex, 50)],
            health: [:]
        )
        XCTAssertEqual(text, "Cx 50%")
    }

    func testIconStyleAndAllHiddenProduceNoCaption() {
        let layout = ProviderLayout(order: [.go, .codex], hidden: [.commandCode], menuBarStyle: .icon)
        XCTAssertEqual(
            MenuBarComposition.text(style: .icon, layout: layout,
                                    snapshots: [.go: snapshot(.go, 74)], health: [:]),
            ""
        )
        let allHidden = ProviderLayout(order: ProviderID.allCases, hidden: Set(ProviderID.allCases), menuBarStyle: .all)
        XCTAssertEqual(
            MenuBarComposition.text(style: .all, layout: allHidden, snapshots: [:], health: [:]),
            ""
        )
        XCTAssertEqual(MenuBarComposition.accessibilityLabel(""), "QuotaBar")
    }

    func testAllPercentagesSkipsUnconfiguredProvidersButKeepsUnknownOnes() {
        let layout = ProviderLayout(order: [.go, .codex, .commandCode], hidden: [], menuBarStyle: .all)
        let text = MenuBarComposition.text(
            style: .all,
            layout: layout,
            snapshots: [.go: snapshot(.go, 74)],
            health: [.codex: ProviderHealth(state: .noCredentials),
                     .commandCode: ProviderHealth(state: .offline)]
        )
        XCTAssertEqual(text, "Go 74% · CC …")
    }
}

final class AttentionBannerTests: XCTestCase {
    func testHiddenProviderWarnsOnlyWhileItsAlertsAreEnabled() {
        XCTAssertTrue(AttentionBanner.shouldShow(
            isHidden: true, alertsEnabled: true, isCompact: true, isExpanded: false,
            warnedWindowID: "go.monthly", limitingWindowID: nil
        ))
        XCTAssertFalse(AttentionBanner.shouldShow(
            isHidden: true, alertsEnabled: false, isCompact: true, isExpanded: false,
            warnedWindowID: "go.monthly", limitingWindowID: nil
        ))
    }

    func testVisibleCardDoesNotRepeatItsOwnWarning() {
        XCTAssertFalse(AttentionBanner.shouldShow(
            isHidden: false, alertsEnabled: true, isCompact: true, isExpanded: false,
            warnedWindowID: "go.monthly", limitingWindowID: "go.monthly"
        ))
    }

    func testCompactCardWarnsAboutAWindowItDoesNotShow() {
        XCTAssertTrue(AttentionBanner.shouldShow(
            isHidden: false, alertsEnabled: true, isCompact: true, isExpanded: false,
            warnedWindowID: "codex.secondary", limitingWindowID: "codex.primary"
        ))
        XCTAssertFalse(AttentionBanner.shouldShow(
            isHidden: false, alertsEnabled: true, isCompact: true, isExpanded: true,
            warnedWindowID: "codex.secondary", limitingWindowID: "codex.primary"
        ))
        XCTAssertFalse(AttentionBanner.shouldShow(
            isHidden: false, alertsEnabled: true, isCompact: false, isExpanded: false,
            warnedWindowID: "codex.secondary", limitingWindowID: "codex.primary"
        ))
    }
}
