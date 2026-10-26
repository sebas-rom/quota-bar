import SwiftUI
import Charts
import AppKit
import QuotaBarKit

// MARK: - History window
//
// Depth lives here: range charts per window, provenance per provider, and an
// honest empty state. The popover stays a glance.

enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week

    var id: String { rawValue }
    var hours: Int { self == .day ? 24 : 168 }
    var label: String { self == .day ? "24 hours" : "7 days" }
    var axisLabel: String { self == .day ? "24h" : "7d" }

    var xAxisFormat: Date.FormatStyle {
        self == .day
            ? .dateTime.hour()
            : .dateTime.weekday(.abbreviated)
    }
}

struct HistoryView: View {
    @ObservedObject var model: QuotaModel
    /// Evidence snapshots render without ScrollView/Picker, which the offscreen
    /// renderer cannot lay out. The shipped window always uses the live path.
    var isSnapshot = false
    @State private var range: HistoryRange = .day
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isSnapshot {
                historyContent
            } else {
                ScrollView { historyContent }
            }
            Divider()
            footer
        }
        .confirmationDialog(
            "Delete local quota history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Delete History", role: .destructive) {
                Task { await model.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every stored observation on this Mac. Live percentages keep working; history restarts empty.")
        }
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(ProviderID.allCases, id: \.self) { provider in
                ProviderHistorySection(model: model, provider: provider, range: range)
            }
            Text("Percent used per window on a fixed 0–100 scale. Sampled every 5 minutes, kept for 90 days, never uploaded.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quota History").font(.title2.weight(.semibold))
                Text("Where both stacks have been, not just where they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isSnapshot {
                Text(range.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            } else {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.historyCount) sample\(model.historyCount == 1 ? "" : "s") stored locally")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Clear History…") { confirmClear = true }
                .disabled(model.historyCount == 0)
            Button("Done") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}

struct ProviderHistorySection: View {
    @ObservedObject var model: QuotaModel
    let provider: ProviderID
    let range: HistoryRange

    private var snapshot: ProviderSnapshot? { model.snapshots[provider] }
    private var health: ProviderHealth? { model.health[provider] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor(dotColor(for: snapshot?.limiting?.percent)))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(provider.displayName).font(.headline)
                if let plan = snapshot?.plan {
                    Text(plan.capitalized)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                Spacer()
                if let snapshot {
                    Text("updated \(freshnessText(for: snapshot.observedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let snapshot, !snapshot.windows.isEmpty {
                windowRows(snapshot.windows)
            } else {
                emptyCard
            }
        }
    }

    /// Two charts per row; an odd last chart spans the full width instead of
    /// leaving a dead grid cell.
    private func windowRows(_ windows: [QuotaWindow]) -> some View {
        let rows: [[QuotaWindow]] = stride(from: 0, to: windows.count, by: 2).map {
            Array(windows[$0..<min($0 + 2, windows.count)])
        }
        return VStack(spacing: 12) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(rows[index]) { window in
                        WindowChartCard(model: model, provider: provider, window: window, range: range)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var emptyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(health?.state == .noCredentials ? "No credentials yet" : "Collecting samples…")
                    .font(.callout.weight(.medium))
                Text(emptyMessage)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptyMessage: String {
        switch health?.state {
        case .noCredentials:
            return provider == .go
                ? "Add an opencode Personal API key from the menu to start recording."
                : "Sign in with the Codex CLI so ~/.codex/auth.json exists."
        case .authFailed, .entitlementMissing:
            return health?.message ?? "Credentials need attention."
        default:
            return "The first observation is written on the next refresh. History appears once there are two samples."
        }
    }
}

struct WindowChartCard: View {
    @ObservedObject var model: QuotaModel
    let provider: ProviderID
    let window: QuotaWindow
    let range: HistoryRange

    private var points: [SamplePoint] {
        model.trend(provider: provider, windowID: window.id, hours: range.hours)
    }

    private var color: Color { dotColor(usageColorName(for: window.percent)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.subheadline.weight(.medium))
                if window.isLimited {
                    Text("limit reached").font(.caption2).foregroundStyle(.red)
                }
                Spacer()
                Text("\(Int(window.percent.rounded()))%")
                    .font(.title3.weight(.semibold)).monospacedDigit()
            }

            HStack(spacing: 8) {
                if let reset = resetText(until: window.resetsAt) {
                    Text(reset).font(.caption).foregroundStyle(.secondary)
                }
                if let delta = deltaPoints(points) {
                    Text(deltaText(delta)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if points.count >= 2 {
                chart
            } else {
                placeholder
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName), \(window.label) quota, \(range.label) history")
        .accessibilityValue(accessibilityValue)
    }

    private var chart: some View {
        let now = Date()
        return Chart(points) { point in
            AreaMark(
                x: .value("Time", point.at),
                y: .value("Used", point.percent)
            )
            .foregroundStyle(LinearGradient(
                colors: [color.opacity(0.28), color.opacity(0.02)],
                startPoint: .top, endPoint: .bottom
            ))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", point.at),
                y: .value("Used", point.percent)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
            if let last = points.last {
                PointMark(
                    x: .value("Time", last.at),
                    y: .value("Used", last.percent)
                )
                .foregroundStyle(color)
                .symbolSize(24)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(
            domain: now.addingTimeInterval(-Double(range.hours) * 3_600)...now,
            range: .plotDimension(padding: 8)
        )
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel().font(.caption2)
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDates) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: range.xAxisFormat).font(.caption2)
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.primary.opacity(0.035))
        }
        .frame(height: 104)
    }

    /// Ticks on aligned boundaries, deliberately stopping short of "now" so the
    /// last label is never clipped by the plot edge.
    private var axisDates: [Date] {
        let now = Date()
        let calendar = Calendar.current
        let start = now.addingTimeInterval(-Double(range.hours) * 3_600)
        var dates: [Date] = []

        if range == .day {
            guard var cursor = calendar.dateInterval(of: .hour, for: start)?.start else { return [] }
            let hour = calendar.component(.hour, from: cursor)
            cursor = cursor.addingTimeInterval(Double((6 - hour % 6) % 6) * 3_600)
            while cursor < now.addingTimeInterval(-2_400) {
                dates.append(cursor)
                cursor = cursor.addingTimeInterval(6 * 3_600)
            }
        } else {
            guard var cursor = calendar.dateInterval(of: .day, for: start)?.start else { return [] }
            cursor = cursor.addingTimeInterval(86_400)
            while cursor < now.addingTimeInterval(-3_600) {
                dates.append(cursor)
                cursor = cursor.addingTimeInterval(86_400)
            }
        }
        return dates
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.035))
            VStack(spacing: 3) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.caption)
                Text("Collecting samples…")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        .frame(height: 104)
    }

    private var accessibilityValue: String {
        var bits = ["\(Int(window.percent.rounded())) percent used"]
        if let reset = resetText(until: window.resetsAt) { bits.append(reset) }
        if let delta = deltaPoints(points) {
            bits.append("\(delta >= 0 ? "up" : "down") \(Int(abs(delta).rounded())) points over \(range.label)")
        }
        if points.count < 2 { bits.append("history still collecting") }
        return bits.joined(separator: ", ")
    }

    private func deltaText(_ delta: Double) -> String {
        let rounded = Int(delta.rounded())
        if rounded == 0 { return "flat · \(range.axisLabel)" }
        return "\(rounded > 0 ? "+" : "−")\(abs(rounded)) pts · \(range.axisLabel)"
    }
}
