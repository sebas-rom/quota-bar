import SwiftUI
import QuotaBarKit

// MARK: - Shared presentation components
//
// Cards, meters and sparklines render any provider from normalized snapshots.
// No provider-specific branches live here, so a third provider needs no UI work.

enum Layout {
    static let outer: CGFloat = 12
    static let card: CGFloat = 12
    static let cardSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 10
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
            if let resetText = resetText(until: reset) {
                Text(resetText).font(.caption).foregroundStyle(.secondary)
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
        if let resetText = resetText(until: reset) { bits.append(resetText.capitalized + ".") }
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
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack(spacing: 6) {
                Circle().fill(dotColor(dot)).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(title).font(.headline)
                Spacer()
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            content
        }
        .padding(Layout.card)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 24h (or any range) mini chart. Y is pinned to 0–100 so a 2% window never
/// looks as dramatic as a 90% one.
struct Sparkline: View {
    let points: [SamplePoint]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if points.count >= 2, size.width > 4, size.height > 2 {
                let coords = normalized(in: size)
                ZStack {
                    Path { path in
                        path.addLines(coords)
                    }
                    .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        path.addLines(coords)
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(
                        colors: [color.opacity(0.22), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
                }
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                    path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                }
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        let sorted = points.sorted { $0.at < $1.at }
        let t0 = sorted.first?.at ?? Date()
        let t1 = sorted.last?.at ?? Date()
        let span = max(1, t1.timeIntervalSince(t0))
        return sorted.map { point in
            let x = t1 == t0 ? size.width : CGFloat(point.at.timeIntervalSince(t0) / span) * size.width
            let clamped = min(max(point.percent, 0), 100)
            let y = size.height - CGFloat(clamped / 100) * size.height
            return CGPoint(x: x, y: y)
        }
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
