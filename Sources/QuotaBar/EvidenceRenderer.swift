import SwiftUI
import AppKit
import QuotaBarKit

// MARK: - Offscreen evidence renderer (--render-evidence <dir>)
//
// Renders the real views with the demo data set to PNGs without a window
// server. Used for review artifacts and regression snapshots; the shipped app
// never enters this path.

@MainActor
enum EvidenceRenderer {
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
        let model = AppEnvironment.model
        print("evidence: model ready"); fflush(stdout)

        renderPopover(model: model, to: directory.appendingPathComponent("popover-light.png"), dark: false)
        renderPopover(model: model, to: directory.appendingPathComponent("popover-dark.png"), dark: true)
        renderHistory(model: model, to: directory.appendingPathComponent("history-light.png"), dark: false)
        renderHistory(model: model, to: directory.appendingPathComponent("history-dark.png"), dark: true)
        if let png = MenuBarIcon.png(pixelSize: 36) {
            try? png.write(to: directory.appendingPathComponent("menubar-icon.png"))
        }
        print("evidence written to \(directory.path)"); fflush(stdout)
        return true
    }

    private static func measuredHeight<V: View>(of view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        return max(120, height.rounded(.up))
    }

    private static func renderPopover(model: QuotaModel, to url: URL, dark: Bool) {
        let view = PopoverView(model: model, launchAtLogin: .constant(false), showsPresentation: false)
        render(view, width: 320, height: nil, dark: dark, to: url)
    }

    private static func renderHistory(model: QuotaModel, to url: URL, dark: Bool) {
        render(HistoryView(model: model, isSnapshot: true), width: 620, height: nil, dark: dark, to: url)
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
