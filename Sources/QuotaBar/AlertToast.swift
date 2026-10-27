import AppKit
import SwiftUI

// Ad-hoc signed builds cannot register with Notification Center (macOS accepts
// the request but never lists the app, so banners are silently dropped). Until
// QuotaBar is distributed with a Developer ID, alerts are shown as a local
// floating panel instead: same copy, no system permission, works today.

@MainActor
final class AlertToast {
    static let shared = AlertToast()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ message: String) {
        let host = NSHostingView(rootView: ToastView(
            message: message,
            onClose: { [weak self] in self?.hide() }
        ))
        host.layoutSubtreeIfNeeded()
        let height = max(56, host.fittingSize.height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        panel.setContentSize(NSSize(width: 340, height: height))
        position(panel)

        panel.orderFrontRegardless()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = min(max(visible.minX + 12, visible.maxX - size.width - 12), visible.maxX - size.width - 12)
        let y = min(max(visible.minY + 12, visible.maxY - size.height - 10), visible.maxY - size.height - 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct ToastView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("QuotaBar")
                    .font(.caption).fontWeight(.semibold)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss alert")
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .onTapGesture(perform: onClose)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("QuotaBar alert. \(message)")
    }
}
