import SwiftUI
import AppKit
import QuotaBarKit

// MARK: - Demo harness (--demo)
//
// Renders the real views with synthetic, clearly-labelled data so screenshots
// and manual review never depend on a live provider state. Never used by the
// shipped flow: the app only enters this path when launched with --demo.

enum DemoData {
    @MainActor static func seed(_ model: QuotaModel, now: Date = Date(), origin: SnapshotOrigin = .demo) {
        guard let store = model.store else { return }

        let goRollingReset = now.addingTimeInterval(3_073)       // 74% right now
        let codexPrimaryReset = now.addingTimeInterval(12_600)   // 22% right now

        func saw(_ t: Date, end: Date, windowSeconds: Double, base: Double, amp: Double) -> Double {
            let back = max(0, now.timeIntervalSince(t))
            let cycles = floor(back / windowSeconds)
            let windowEnd = end.addingTimeInterval(-cycles * windowSeconds)
            let remaining = windowEnd.timeIntervalSince(t)
            let phase = 1 - remaining / windowSeconds
            return min(99, base + amp * min(max(phase, 0), 1))
        }

        func linear(_ t: Date, from: Double, to: Double) -> Double {
            let span = 24 * 3_600.0
            let progress = min(max(1 - now.timeIntervalSince(t) / span, 0), 1)
            return from + (to - from) * progress
        }

        struct Series {
            let id: String
            let label: String
            let provider: ProviderID
            let minutes: Int
            let reset: Date
            let percent: (Date) -> Double
        }

        let series: [Series] = [
            Series(id: "go.rolling", label: "5-hour", provider: .go, minutes: 300, reset: goRollingReset) { t in
                saw(t, end: goRollingReset, windowSeconds: 18_000, base: 6, amp: 82)
            },
            Series(id: "go.weekly", label: "Weekly", provider: .go, minutes: 10_080, reset: now.addingTimeInterval(3 * 86_400 + 4 * 3_600)) { t in
                linear(t, from: 30, to: 38)
            },
            Series(id: "go.monthly", label: "Monthly", provider: .go, minutes: 43_200, reset: now.addingTimeInterval(3 * 86_400)) { t in
                linear(t, from: 89, to: 93)
            },
            Series(id: "codex.primary", label: "5-hour", provider: .codex, minutes: 300, reset: codexPrimaryReset) { t in
                saw(t, end: codexPrimaryReset, windowSeconds: 18_000, base: 4, amp: 60)
            },
            Series(id: "codex.secondary", label: "Weekly", provider: .codex, minutes: 10_080, reset: now.addingTimeInterval(4 * 86_400 + 6 * 3_600)) { t in
                linear(t, from: 7, to: 9)
            },
            Series(id: "commandcode.5h", label: "5-hour", provider: .commandCode, minutes: 300, reset: now.addingTimeInterval(86 * 60)) { t in
                saw(t, end: now.addingTimeInterval(86 * 60), windowSeconds: 18_000, base: 4, amp: 24)
            },
            Series(id: "commandcode.weekly", label: "Weekly", provider: .commandCode, minutes: 10_080, reset: now.addingTimeInterval(6 * 86_400)) { t in
                linear(t, from: 4, to: 6)
            },
            Series(id: "commandcode.monthly", label: "Monthly", provider: .commandCode, minutes: 43_200, reset: now.addingTimeInterval(30 * 86_400)) { t in
                linear(t, from: 1, to: 2.2)
            },
        ]

        // 24 hours of five-minute samples.
        let sampleCount = 288
        for index in 0..<sampleCount {
            let t = now.addingTimeInterval(-Double(sampleCount - 1 - index) * 300)
            for s in series {
                let windowSeconds = Double(s.minutes) * 60
                let cyclesBack = floor(max(0, now.timeIntervalSince(t)) / windowSeconds)
                let reset = s.reset.addingTimeInterval(-cyclesBack * windowSeconds)
                let snapshot = ProviderSnapshot(
                    provider: s.provider,
                    windows: [QuotaWindow(
                        id: s.id, kind: .primary, label: s.label,
                        percent: s.percent(t), resetsAt: reset,
                        windowMinutes: s.minutes, isLimited: false
                    )],
                    plan: s.provider == .codex ? "plus" : nil,
                    // Synthetic history is stored as observations; the origin
                    // parameter only labels the current snapshot.
                    origin: .network,
                    source: "demo data",
                    observedAt: t
                )
                _ = store.insert(snapshot)
            }
        }

        let goSnapshot = ProviderSnapshot(
            provider: .go,
            windows: [
                QuotaWindow(id: "go.rolling", kind: .rolling, label: "5-hour",
                            percent: 74, resetsAt: goRollingReset, windowMinutes: 300, isLimited: false),
                QuotaWindow(id: "go.weekly", kind: .weekly, label: "Weekly",
                            percent: 38, resetsAt: now.addingTimeInterval(3 * 86_400 + 4 * 3_600), windowMinutes: 10_080, isLimited: false),
                QuotaWindow(id: "go.monthly", kind: .monthly, label: "Monthly",
                            percent: 93, resetsAt: now.addingTimeInterval(3 * 86_400), windowMinutes: 43_200, isLimited: false),
            ],
            plan: nil,
            origin: origin,
            source: "opencode.ai/zen/go/v1/usage",
            observedAt: now.addingTimeInterval(-120)
        )

        let codexSnapshot = ProviderSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(id: "codex.primary", kind: .primary, label: "5-hour",
                            percent: 22, resetsAt: codexPrimaryReset, windowMinutes: 300, isLimited: false),
                QuotaWindow(id: "codex.secondary", kind: .secondary, label: "Weekly",
                            percent: 9, resetsAt: now.addingTimeInterval(4 * 86_400 + 6 * 3_600), windowMinutes: 10_080, isLimited: false),
            ],
            plan: "plus",
            origin: origin,
            source: "chatgpt.com/backend-api/wham/usage",
            observedAt: now.addingTimeInterval(-40),
            facts: ["2 reset credits"]
        )

        let commandCodeSnapshot = ProviderSnapshot(
            provider: .commandCode,
            windows: [
                QuotaWindow(id: "commandcode.5h", kind: .primary, label: "5-hour",
                            percent: 10.9, resetsAt: now.addingTimeInterval(86 * 60), windowMinutes: 300, isLimited: false),
                QuotaWindow(id: "commandcode.weekly", kind: .weekly, label: "Weekly",
                            percent: 4.4, resetsAt: now.addingTimeInterval(6 * 86_400), windowMinutes: 10_080, isLimited: false),
                QuotaWindow(id: "commandcode.monthly", kind: .monthly, label: "Monthly",
                            percent: 2.2, resetsAt: now.addingTimeInterval(30 * 86_400), windowMinutes: 43_200, isLimited: false,
                            cycleStart: now.addingTimeInterval(-86_400)),
            ],
            plan: "GOAT",
            origin: origin,
            source: "api.commandcode.ai",
            observedAt: now.addingTimeInterval(-30),
            facts: ["68.6 of 70 credits left", "Renews Nov 27"]
        )

        model.ingestDemo(goSnapshot)
        model.ingestDemo(codexSnapshot)
        model.ingestDemo(commandCodeSnapshot)
        model.invalidateHistory()
    }
}

extension DemoData {
    @MainActor
    static func seedSetup(_ model: QuotaModel, now: Date = Date()) {
        let codex = ProviderSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(id: "codex.primary", kind: .primary, label: "5-hour",
                            percent: 22, resetsAt: now.addingTimeInterval(12600), windowMinutes: 300, isLimited: false),
                QuotaWindow(id: "codex.secondary", kind: .secondary, label: "Weekly",
                            percent: 9, resetsAt: now.addingTimeInterval(4 * 86_400 + 6 * 3_600), windowMinutes: 10_080, isLimited: false),
            ],
            plan: "plus",
            origin: .demo,
            source: "chatgpt.com/backend-api/wham/usage",
            observedAt: now,
            facts: ["2 reset credits"]
        )
        model.ingestDemo(codex)
        model.markDemoUnconfigured([.go, .commandCode])
    }
}

@MainActor
final class DemoHost {
    static let shared = DemoHost()
    private var popover: NSPopover?
    private var anchor: NSWindow?

    func present(model: QuotaModel, layout: ProviderLayoutStore) {
        guard let screen = NSScreen.main else { return }

        let anchorRect = NSRect(x: screen.frame.minX + 120, y: screen.frame.maxY - 1, width: 1, height: 1)
        let anchor = NSWindow(contentRect: anchorRect, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.orderFrontRegardless()
        self.anchor = anchor

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let host = NSHostingController(rootView: PopoverView(model: model, layout: layout))
        host.view.layoutSubtreeIfNeeded()
        popover.contentSize = host.view.fittingSize
        popover.contentViewController = host
        popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        self.popover = popover

        HistoryWindowController.shared.show(model: model, layout: layout)
    }
}
