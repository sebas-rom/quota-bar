import Foundation

// MARK: - Window semantics
//
// Go's 5-hour window and Codex's primary 5-hour window report a reset that
// advances with time: they are sliding (rolling) windows, not fixed cycles.
// One classification, shared by presentation, history, replay and alerts, so
// the three surfaces cannot disagree.

public enum WindowSemantics {
    public static func isRolling(provider: ProviderID, window: QuotaWindow) -> Bool {
        guard window.windowMinutes == 300 else { return false }
        return (provider == .go && window.id == "go.rolling")
            || (provider == .codex && window.id == "codex.primary")
    }
}
