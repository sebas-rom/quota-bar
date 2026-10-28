import Foundation

// MARK: - Provider layout
//
// Order and visibility are user preferences, not provider facts. They are
// presentation metadata only: probes, storage, alerts and the machine-readable
// status contract never consult this type.

public enum MenuBarStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case worst
    case icon

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All percentages"
        case .worst: return "Worst only"
        case .icon: return "Icon only"
        }
    }
}

public struct ProviderLayout: Equatable, Sendable {
    public var order: [ProviderID]
    public var hidden: Set<ProviderID>
    public var menuBarStyle: MenuBarStyle

    public static let standard = ProviderLayout(
        order: ProviderID.allCases,
        hidden: [],
        menuBarStyle: .all
    )

    public init(order: [ProviderID], hidden: Set<ProviderID>, menuBarStyle: MenuBarStyle) {
        self.order = order
        self.hidden = hidden
        self.menuBarStyle = menuBarStyle
    }

    /// Providers in user order, minus the ones explicitly hidden.
    public var visible: [ProviderID] {
        order.filter { !hidden.contains($0) }
    }

    public func isVisible(_ provider: ProviderID) -> Bool {
        order.contains(provider) && !hidden.contains(provider)
    }

    /// Deterministic repair for anything that reaches disk: unknown or
    /// duplicated entries are dropped, providers added by an app update are
    /// appended in their default order so a new service is never invisible,
    /// and an empty order falls back to the default.
    public func normalized() -> ProviderLayout {
        var seen: [ProviderID] = []
        for provider in order where !seen.contains(provider) {
            seen.append(provider)
        }
        for provider in ProviderID.allCases where !seen.contains(provider) {
            seen.append(provider)
        }
        var repaired = self
        repaired.order = seen
        repaired.hidden = hidden.intersection(ProviderID.allCases)
        return repaired
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var repaired = normalized()
        var items = repaired.order
        let valid = source.filter { items.indices.contains($0) }
        guard !valid.isEmpty else {
            self = repaired
            return
        }
        let moving = valid.sorted().map { items[$0] }
        let insertion = destination - valid.filter { $0 < destination }.count
        for index in valid.sorted(by: >) {
            items.remove(at: index)
        }
        items.insert(contentsOf: moving, at: max(0, min(items.count, insertion)))
        repaired.order = items
        self = repaired
    }

    public mutating func setHidden(_ provider: ProviderID, _ isHidden: Bool) {
        if isHidden {
            hidden.insert(provider)
        } else {
            hidden.remove(provider)
        }
    }
}

// MARK: - Persistence shape
//
// Decoding goes through raw strings so a layout written by a newer build (or a
// hand-edited value) degrades to the providers this build knows instead of
// failing the whole preference.

extension ProviderLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case order, hidden, menuBarStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let orderRaw = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        let hiddenRaw = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        let style = try container.decodeIfPresent(String.self, forKey: .menuBarStyle)
            .flatMap(MenuBarStyle.init(rawValue:)) ?? .all
        self.init(
            order: orderRaw.compactMap(ProviderID.init(rawValue:)),
            hidden: Set(hiddenRaw.compactMap(ProviderID.init(rawValue:))),
            menuBarStyle: style
        )
        self = normalized()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalized().order.map(\.rawValue), forKey: .order)
        try container.encode(normalized().hidden.map(\.rawValue).sorted(), forKey: .hidden)
        try container.encode(menuBarStyle.rawValue, forKey: .menuBarStyle)
    }
}

// MARK: - Menu bar composition

public enum MenuBarComposition {
    /// The menu-bar caption. An empty string means "icon only": the stored
    /// style is never mutated, so unhiding a provider restores the user's
    /// chosen mode.
    public static func text(
        style: MenuBarStyle,
        layout: ProviderLayout,
        snapshots: [ProviderID: ProviderSnapshot],
        health: [ProviderID: ProviderHealth]
    ) -> String {
        let visible = layout.visible
        guard !visible.isEmpty else { return "" }
        switch style {
        case .icon:
            return ""
        case .all:
            var parts: [String] = []
            for provider in visible {
                if let limiting = snapshots[provider]?.limiting {
                    parts.append("\(provider.shortName) \(Int(limiting.percent.rounded()))%")
                } else if health[provider]?.state == .noCredentials {
                    continue
                } else {
                    parts.append("\(provider.shortName) …")
                }
            }
            return parts.joined(separator: " · ")
        case .worst:
            // Highest limiting window wins; ties keep the earlier provider in
            // user order. Providers without a reading are skipped rather than
            // rendered as a fake percentage.
            var best: (provider: ProviderID, percent: Double)?
            for provider in visible {
                guard let percent = snapshots[provider]?.limiting?.percent,
                      percent.isFinite else { continue }
                if let current = best, current.percent >= percent { continue }
                best = (provider, percent)
            }
            guard let best else { return "" }
            return "\(best.provider.shortName) \(Int(best.percent.rounded()))%"
        }
    }

    /// VoiceOver must never receive an empty label.
    public static func accessibilityLabel(_ text: String) -> String {
        text.isEmpty ? "QuotaBar" : text
    }
}

// MARK: - Trend coverage

public enum TrendCoverage {
    /// A trend is only meaningful when its samples span a real share of the
    /// frame it claims to describe. Two points five minutes apart inside a
    /// monthly cycle are not a monthly trend.
    public static let minimumFrameFraction: Double = 0.05

    public static func isMeaningful(
        points: [SamplePoint],
        frameStart: Date,
        frameEnd: Date
    ) -> Bool {
        guard points.count >= 2, frameEnd > frameStart else { return false }
        let span = (points.map(\.at).max() ?? frameEnd).timeIntervalSince(points.map(\.at).min() ?? frameStart)
        guard span > 0 else { return false }
        return span >= frameEnd.timeIntervalSince(frameStart) * minimumFrameFraction
    }
}

// MARK: - Attention banner rule

public enum AttentionBanner {
    /// A warning row exists to surface something the cards cannot show. A
    /// warning already on a visible card is not repeated.
    ///
    /// - A hidden provider only draws attention while its own alerts are on.
    /// - A visible provider on a compact, unexpanded card only needs the row
    ///   when the warned window is not the one its meter displays.
    public static func shouldShow(
        isHidden: Bool,
        alertsEnabled: Bool,
        isCompact: Bool,
        isExpanded: Bool,
        warnedWindowID: String,
        limitingWindowID: String?
    ) -> Bool {
        if isHidden { return alertsEnabled }
        guard isCompact, !isExpanded, let limitingWindowID else { return false }
        return limitingWindowID != warnedWindowID
    }
}
