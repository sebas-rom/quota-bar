import Foundation

// MARK: - Window semantics
//
// Go's 5-hour window and Codex's primary 5-hour window report a reset that
// advances with time: they are sliding (rolling) windows, not fixed cycles.
// One classification, shared by presentation, history, replay and alerts, so
// the three surfaces cannot disagree.
//
// `QuotaWindow.kind` describes a window's role, not whether it rolls: Codex
// and Command Code both expose a `.primary` 5-hour window, but only Codex's
// advances. Anything that needs "can this window be charted as a fixed cycle"
// must ask this type, never infer it from the kind.

public enum WindowSemantics {
    public static func isRolling(provider: ProviderID, window: QuotaWindow) -> Bool {
        guard window.windowMinutes == 300 else { return false }
        return (provider == .go && window.id == "go.rolling")
            || (provider == .codex && window.id == "codex.primary")
    }

    /// A 5-hour window whose cycle has a stable enough boundary for the
    /// conservative forecast: rolling windows and fixed server-anchored cycles
    /// both qualify, because the forecast only needs samples plus a reset.
    /// Weekly/monthly windows never do — a one-hour slope is not evidence for a
    /// month-long projection.
    public static func isForecastable(window: QuotaWindow) -> Bool {
        guard window.windowMinutes == 300 else { return false }
        switch window.kind {
        case .rolling, .primary: return true
        case .weekly, .monthly, .secondary, .review, .additional: return false
        }
    }
}
