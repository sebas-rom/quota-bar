import SwiftUI
import Charts
import AppKit
import QuotaBarKit

// MARK: - History window
//
// Cycle-first: every chart runs from the start of a quota window to its reset,
// not over an arbitrary 24h/7d range. Forecasts are drawn only for the current
// 5-hour window when the engine says the evidence is sufficient.

struct HistoryView: View {
    @ObservedObject var model: QuotaModel
    /// Evidence snapshots render without ScrollView, which the offscreen
    /// renderer cannot lay out. The shipped window always uses the live path.
    var isSnapshot = false
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
                ProviderHistorySection(model: model, provider: provider, isSnapshot: isSnapshot)
            }
            HStack(spacing: 14) {
                legendItem("Usage", style: .solid)
                legendItem("Forecast", style: .dashed)
                legendItem("Limit", style: .limit)
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text("Fixed windows are charted per quota cycle, from window start to reset. Rolling 5-hour windows are charted as the last five hours. Forecasts are experimental estimates based on recent usage; they may change as your pace changes and never trigger alerts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quota History").font(.title2.weight(.semibold))
                Text("How this window is being spent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Window history")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: Capsule())
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

    @ViewBuilder
    private func legendItem(_ text: String, style: LegendStyle) -> some View {
        HStack(spacing: 4) {
            switch style {
            case .solid:
                Capsule().fill(Color.secondary).frame(width: 14, height: 2)
            case .dashed:
                HStack(spacing: 2) {
                    Capsule().fill(Color.secondary).frame(width: 4, height: 2)
                    Capsule().fill(Color.secondary).frame(width: 4, height: 2)
                }
            case .limit:
                Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 14, height: 1)
            }
            Text(text)
        }
    }

    private enum LegendStyle { case solid, dashed, limit }
}

struct ProviderHistorySection: View {
    @ObservedObject var model: QuotaModel
    let provider: ProviderID
    var isSnapshot = false

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
                    Text(displayPlan(plan))
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
                        CycleChartCard(model: model, provider: provider, window: window, isSnapshot: isSnapshot)
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
                : "Sign in with the provider so QuotaBar can read its quota."
        case .authFailed, .entitlementMissing:
            return health?.message ?? "Credentials need attention."
        default:
            return "The first observation is written on the next refresh."
        }
    }
}

struct CycleChartCard: View {
    @ObservedObject var model: QuotaModel
    let provider: ProviderID
    let window: QuotaWindow
    var isSnapshot = false

    @State private var cycleIndex = 0

    private var rolling: Bool { model.isRollingWindow(provider, window) }

    private var cycles: [QuotaCycle] {
        rolling ? [] : model.cycles(for: provider, window: window)
    }

    private var safeIndex: Int {
        min(max(cycleIndex, 0), max(0, cycles.count - 1))
    }

    private var cycle: QuotaCycle? {
        cycles.indices.contains(safeIndex) ? cycles[safeIndex] : nil
    }

    private var points: [SamplePoint] {
        if rolling {
            return model.trailingSamples(for: provider, window: window, now: Date())
        }
        guard let cycle else { return [] }
        return model.cycleSamples(for: cycle, provider: provider, window: window)
    }

    private var displayPercent: Double {
        if let cycle, cycle.isCurrent,
           let live = model.snapshots[provider]?.window(id: window.id) {
            return live.percent
        }
        return points.last?.percent ?? window.percent
    }

    private var isCurrent: Bool { cycle?.isCurrent ?? true }

    private var statusText: String? {
        if displayPercent >= 100 || (isCurrent && window.isLimited) { return "Limit reached" }
        if displayPercent >= 90 { return "Near limit" }
        return nil
    }

    private var isForecastable: Bool {
        window.windowMinutes == 300 && (window.kind == .rolling || window.kind == .primary)
    }

    private var forecastState: ForecastState? {
        guard isForecastable else { return nil }
        if rolling {
            return model.forecast(for: provider, window: window)
        }
        guard let cycle, cycle.isCurrent else { return nil }
        return model.cycleForecast(for: cycle, provider: provider, window: window)
    }

    private var projection: ForecastProjection? {
        guard isForecastable else { return nil }
        if rolling {
            return model.forecastProjection(for: provider, window: window)
        }
        guard let cycle, cycle.isCurrent else { return nil }
        return model.cycleProjection(for: cycle, provider: provider, window: window)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if rolling {
                Text(rollingSubtitle)
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let cycle {
                Text(cycleSubtitle(cycle))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let statusText {
                Text(statusText)
                    .font(.caption2).fontWeight(.medium)
                    .foregroundStyle(displayPercent >= 100 ? .red : .orange)
            }

            chart
                .frame(height: 132)
                .padding(.top, 2)

            footerNotes
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(window.label).font(.subheadline.weight(.medium))
            if !rolling, cycles.count > 1 {
                if isSnapshot {
                    Image(systemName: "chevron.left").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                } else {
                    Button {
                        cycleIndex = min(cycleIndex + 1, cycles.count - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(safeIndex >= cycles.count - 1)
                    .help("Previous cycle")

                    Button {
                        cycleIndex = max(cycleIndex - 1, 0)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(safeIndex == 0)
                    .help("Next cycle")
                }
            }
            Spacer()
            Text("\(Int(displayPercent.rounded()))%")
                .font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    @ViewBuilder
    private var chart: some View {
        if points.count >= 2 {
            Chart {
                RuleMark(y: .value("Limit", 100))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment) { point in
                        LineMark(
                            x: .value("Time", point.at),
                            y: .value("Used", point.percent),
                            series: .value("Segment", index)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    }
                }

                if let projection {
                    LineMark(
                        x: .value("Time", projection.from),
                        y: .value("Used", projection.fromPercent),
                        series: .value("Segment", "forecast")
                    )
                    .foregroundStyle(color.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))

                    LineMark(
                        x: .value("Time", projection.to),
                        y: .value("Used", projection.toPercent),
                        series: .value("Segment", "forecast")
                    )
                    .foregroundStyle(color.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }

                if let last = points.last {
                    PointMark(x: .value("Time", last.at), y: .value("Used", last.percent))
                        .foregroundStyle(color)
                        .symbolSize(28)
                }
            }
            .chartYScale(domain: 0...yMax)
            .chartXScale(domain: xDomain)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel().font(.caption2)
                }
            }
            .chartXAxis {
                AxisMarks(values: tickDates) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: tickFormat).font(.caption2)
                }
            }
            .chartPlotStyle { plot in
                plot.background(Color.primary.opacity(0.035))
            }
        } else if points.count == 1 {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035))
                Text("Collecting history…").font(.caption2).foregroundStyle(.tertiary)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035))
                VStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath").font(.caption)
                    Text("No samples in this cycle").font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var footerNotes: some View {
        if !points.isEmpty {
            let frameStart = rolling
                ? Date().addingTimeInterval(-5 * 3_600)
                : (cycle?.start ?? Date())
            if let first = points.first, first.at.timeIntervalSince(frameStart) > 3600 {
                Text("History starts \(first.at.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let line = forecastState.flatMap({ ForecastCopy.line(for: $0) }) {
                Text(line).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        dotColor(usageColorName(for: displayPercent))
    }

    private var xDomain: ClosedRange<Date> {
        if rolling {
            let now = Date()
            return now.addingTimeInterval(-5 * 3_600)...now.addingTimeInterval(2 * 3_600)
        }
        guard let cycle else { return Date()...Date().addingTimeInterval(1) }
        return cycle.start...cycle.end
    }

    private var yMax: Double {
        let maxValue = max(100, points.map(\.percent).max() ?? 0, projection?.toPercent ?? 0)
        if maxValue <= 100 { return 110 }
        if maxValue <= 110 { return 125 }
        if maxValue <= 125 { return 150 }
        return (maxValue / 25).rounded(.up) * 25
    }

    private var segments: [[SamplePoint]] {
        var out: [[SamplePoint]] = []
        var current: [SamplePoint] = []
        for point in points.sorted(by: { $0.at < $1.at }) {
            if let last = current.last, point.at.timeIntervalSince(last.at) > 15 * 60 {
                if !current.isEmpty { out.append(current) }
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private var tickDates: [Date] {
        let start = xDomain.lowerBound
        let end = xDomain.upperBound
        let span = end.timeIntervalSince(start)
        let fractions: [Double] = span <= 8 * 3_600
            ? [0.0, 0.5, 1.0]
            : [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0]
        return fractions.map { start.addingTimeInterval(span * $0) }
    }

    private var tickFormat: Date.FormatStyle {
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        if span <= 8 * 3_600 { return .dateTime.hour().minute() }
        return .dateTime.month(.abbreviated).day()
    }

    private var rollingSubtitle: String {
        var text = "Rolling 5-hour window"
        if let reset = window.resetsAt, reset > Date(), let value = resetText(until: reset) {
            text += " · \(value.prefix(1).uppercased() + value.dropFirst())"
        } else {
            text += " · awaiting refresh"
        }
        return text
    }

    private func cycleSubtitle(_ cycle: QuotaCycle) -> String {
        let span = cycle.end.timeIntervalSince(cycle.start)
        let prefix: String
        switch cycle.provenance {
        case .exact: prefix = "Billing period"
        case .estimated: prefix = "Quota cycle · approx."
        case .derived: prefix = "Quota cycle"
        }
        let dates: String
        if span <= 6 * 3600 {
            let start = cycle.start.formatted(.dateTime.hour().minute())
            let end = cycle.end.formatted(.dateTime.hour().minute())
            dates = "\(start)–\(end)"
        } else {
            let start = cycle.start.formatted(.dateTime.month(.abbreviated).day())
            let end = cycle.end.formatted(.dateTime.month(.abbreviated).day())
            dates = "\(start)–\(end)"
        }
        var text = "\(prefix) · \(dates)"
        if cycle.isCurrent {
            if let reset = resetText(until: cycle.end) {
                text += " · \(reset.prefix(1).uppercased() + reset.dropFirst())"
            }
        } else {
            text += " · Ended"
        }
        return text
    }

    private var accessibilitySummary: String {
        var bits = ["\(provider.displayName), \(window.label) quota"]
        bits.append("\(Int(displayPercent.rounded())) percent used")
        if rolling {
            bits.append(rollingSubtitle)
        } else if let cycle {
            bits.append(cycleSubtitle(cycle))
        }
        if let statusText { bits.append(statusText) }
        if let line = forecastState.flatMap({ ForecastCopy.line(for: $0) }) { bits.append(line) }
        if points.count < 2 { bits.append("history collecting") }
        return bits.joined(separator: ", ")
    }
}
