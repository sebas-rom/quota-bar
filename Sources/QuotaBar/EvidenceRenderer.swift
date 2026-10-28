import SwiftUI
import AppKit
import QuotaBarKit

// MARK: - Offscreen evidence renderer (--render-evidence <dir>)
//
// Renders the real views with a fixed synthetic data set to PNGs without a
// window server. Used for review artifacts and regression snapshots; the
// shipped app never enters this path.
//
// Everything here is pinned: one frozen clock, an explicit layout store, and
// explicit card density. Evidence must never depend on the developer's own
// preferences or on the time of day.

@MainActor
enum EvidenceRenderer {
    /// One clock for a whole capture, so every surface agrees on "now".
    /// It is intentionally the current time: a synthetic past would render
    /// stale copy and blank charts instead of the real healthy state.
    static func captureNow() -> Date { Date() }

    static func handleCommandLineIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--render-evidence"), index + 1 < args.count else {
            return false
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("evidence: env ready"); fflush(stdout)

        let now = captureNow()
        let model = makeModel(origin: .demo, now: now)
        let networkModel = makeModel(origin: .network, now: now)
        let hiddenModel = makeModel(origin: .demo, now: now)
        print("evidence: models ready"); fflush(stdout)

        let standard = makeLayout()
        let hidden = makeLayout(hidden: [.commandCode])

        renderPopover(model: model, layout: standard, compact: true,
                      to: directory.appendingPathComponent("popover-light.png"), dark: false)
        renderPopover(model: model, layout: standard, compact: true,
                      to: directory.appendingPathComponent("popover-dark.png"), dark: true)
        renderPopover(model: model, layout: standard, compact: false,
                      to: directory.appendingPathComponent("popover-all-windows.png"), dark: false)
        renderPopover(model: networkModel, layout: standard, compact: true,
                      to: directory.appendingPathComponent("popover-network.png"), dark: false)
        renderPopover(model: hiddenModel, layout: hidden, compact: true,
                      to: directory.appendingPathComponent("popover-hidden.png"), dark: false)
        renderHistory(model: model, layout: standard,
                      to: directory.appendingPathComponent("history-light.png"), dark: false)
        renderHistory(model: model, layout: standard,
                      to: directory.appendingPathComponent("history-dark.png"), dark: true)

        let setupStore = try? TelemetryStore.inMemory()
        let setupModel = QuotaModel(store: setupStore, isDemo: true)
        DemoData.seedSetup(setupModel, now: now)
        renderPopover(model: setupModel, layout: makeLayout(), compact: true,
                      to: directory.appendingPathComponent("popover-setup.png"), dark: false)

        if let png = MenuBarIcon.png(pixelSize: 72) {
            try? png.write(to: directory.appendingPathComponent("menubar-icon.png"))
        }
        print("evidence written to \(directory.path)"); fflush(stdout)
        return true
    }

    /// Fresh in-memory model per render so snapshots cannot leak into each
    /// other or inherit real user preferences.
    private static func makeModel(origin: SnapshotOrigin, now: Date) -> QuotaModel {
        let store = try? TelemetryStore.inMemory()
        let model = QuotaModel(store: store, isDemo: true)
        DemoData.seed(model, now: now, origin: origin)
        return model
    }

    private static func makeLayout(hidden: Set<ProviderID> = []) -> ProviderLayoutStore {
        let suite = UserDefaults(suiteName: "QuotaBarEvidenceLayout") ?? .standard
        suite.removePersistentDomain(forName: "QuotaBarEvidenceLayout")
        let store = ProviderLayoutStore(defaults: suite)
        for provider in hidden {
            store.setHidden(provider, true)
        }
        return store
    }

    private static func measuredHeight<V: View>(of view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        return max(120, height.rounded(.up))
    }

    private static func renderPopover(
        model: QuotaModel,
        layout: ProviderLayoutStore,
        compact: Bool,
        to url: URL,
        dark: Bool
    ) {
        let view = PopoverView(
            model: model,
            layout: layout,
            showsPresentation: false,
            compactOverride: compact
        )
        render(view, width: 320, height: nil, dark: dark, to: url)
    }

    private static func renderHistory(
        model: QuotaModel,
        layout: ProviderLayoutStore,
        to url: URL,
        dark: Bool
    ) {
        render(HistoryView(model: model, layout: layout, isSnapshot: true),
               width: 620, height: nil, dark: dark, to: url)
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat?,
                                       dark: Bool, to url: URL) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let themed = view
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, .medium)

        let resolvedHeight = height ?? measuredHeight(of: themed, width: width)
        let framed = themed
            .frame(width: width, height: resolvedHeight)
            .background(dark ? Color(red: 0.11, green: 0.11, blue: 0.12)
                             : Color(red: 0.98, green: 0.98, blue: 0.98))

        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else {
            print("render failed: \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("png encode failed: \(url.lastPathComponent)")
            return
        }
        try? data.write(to: url)
        print("wrote \(url.lastPathComponent) \(cgImage.width)x\(cgImage.height)")
    }
}
