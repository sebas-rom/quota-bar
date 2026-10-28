import SwiftUI
import QuotaBarKit

// MARK: - Shared presentation components
//
// Cards and meters render any provider from normalized snapshots.
// No provider-specific branches live here, so a third provider needs no UI work.

enum Layout {
    static let outer: CGFloat = 12
    static let card: CGFloat = 12
    static let cardSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 10
}

// MARK: - Next-task advice
//
// One quiet row above the cards. It answers "where should the next task go?"
// with a sentence plus one chip per provider, and it never invents confidence:
// when the evidence does not single out a provider, the row says so instead of
// picking a winner. Chips are glanceable, so the full sentence lives in the
// tooltip and in the accessibility label.

func eligibilityColor(_ eligibility: Eligibility) -> Color {
    switch eligibility {
    case .available: return .green
    case .constrained: return .orange
    case .exhausted: return .red
    case .unknown: return .secondary
    }
}

private func eligibilityWord(_ eligibility: Eligibility) -> String {
    switch eligibility {
    case .available: return "headroom"
    case .constrained: return "close to limit"
    case .exhausted: return "out of quota"
    case .unknown: return "unknown"
    }
}

struct AdvisorRow: View {
    let advice: Advice

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                // No leading icon: a question mark would say "uncertain
                // readings", while the row only means "no single winner".
                // Eligibility is a provider-scope decision: it does not
                // depend on the task length, so the row must not imply that it
                // does. Duration only affects the 5-hour forecast caption.
                Text("Quota availability")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer(minLength: 4)
            }
            Text(advice.recommendation.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !advice.providers.isEmpty {
                HStack(spacing: 4) {
                    ForEach(advice.providers, id: \.id) { provider in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(eligibilityColor(provider.eligibility))
                                .frame(width: 4, height: 4)
                            Text(shortProviderName(provider.id))
                                .font(.caption2)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.4), in: Capsule())
                        .help("\(provider.name): \(eligibilityWord(provider.eligibility)). \(provider.headline)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(provider.name): \(eligibilityWord(provider.eligibility)). \(provider.headline)")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    /// The popover is 320pt wide, so chips use the same short labels as the
    /// menu bar rather than full provider names.
    private func shortProviderName(_ id: String) -> String {
        guard let provider = ProviderID(rawValue: id) else { return id }
        return provider.shortName
    }
}

func dotColor(_ name: String) -> Color {
    switch name {
    case "green": return .green
    case "yellow": return .yellow
    case "orange": return .orange
    case "red": return .red
    default: return .gray
    }
}

/// "plus" -> "Plus", but keep acronyms like "GOAT" intact.
func displayPlan(_ plan: String) -> String {
    plan == plan.uppercased() ? plan : plan.capitalized
}

func dotColor(for percent: Double?) -> String {
    guard let percent else { return "gray" }
    return usageColorName(for: percent)
}

struct MeterRow: View {
    let provider: String
    let label: String
    let percent: Double
    let reset: Date?
    let flag: String?
    let isLimiting: Bool
    var forecast: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                if let flag {
                    Text(flag).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.subheadline).fontWeight(.semibold).monospacedDigit()
            }
            MeterBar(percent: percent, color: dotColor(usageColorName(for: percent)))
            if let resetText = remainingText(until: reset) {
                Text(resetText).font(.caption).foregroundStyle(.secondary)
            }
            if let forecast {
                Text(forecast)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider), \(label) quota")
        .accessibilityValue("\(Int(percent.rounded())) percent used")
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        var bits: [String] = []
        if isLimiting { bits.append("Limiting window.") }
        if flag != nil { bits.append("Limit reached.") }
        if let resetText = remainingText(until: reset) { bits.append(resetText.capitalized + ".") }
        if let forecast { bits.append(forecast) }
        return bits.joined(separator: " ")
    }
}

/// Deterministic quota bar: no AppKit control, renders identically on screen
/// and in offscreen evidence snapshots.
struct MeterBar: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(percent, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(color)
                    .frame(width: max(6, geo.size.width * clamped))
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

struct Card<Content: View>: View {
    let title: String
    let dot: String
    let subtitle: String?
    var isExpandable = false
    var isExpanded = false
    var onToggleExpanded: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpandable, let onToggleExpanded {
                // The whole header is the target: an 11pt chevron glyph is not
                // a clickable control for a human. The chevron stays as the
                // affordance, at the trailing edge after the plan.
                Button(action: onToggleExpanded) {
                    header(showsChevron: true)
                        // Inside the label: the whole 32pt row, edge to edge,
                        // is the button's own hit area.
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Show only the most-used window" : "Show all quota windows")
                .help(isExpanded ? "Show fewer windows" : "Show all quota windows")
                .padding(.bottom, 4)
            } else {
                header(showsChevron: false)
                    .accessibilityElement(children: .combine)
                    .padding(.bottom, Layout.rowSpacing)
            }
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                content
            }
        }
        .padding(Layout.card)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func header(showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor(dot)).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Spacer(minLength: 6)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            } else {
                // Reserve the same trailing slot so plan labels line up whether
                // or not the card has a disclosure control.
                Color.clear.frame(width: 14).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct StatusLine: View {
    let text: String
    let degraded: Bool

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(degraded ? Color.orange : Color.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }
}
