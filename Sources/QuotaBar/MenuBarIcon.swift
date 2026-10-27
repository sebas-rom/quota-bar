import AppKit

// A static monochrome "Q" monogram for the menu bar. Static on purpose: the
// numeric label already carries the state, and a template image keeps macOS
// handling light/dark and accessibility correctly.

enum MenuBarIcon {
    static let pointSize = NSSize(width: 18, height: 18)

    static let image: NSImage = {
        let image = NSImage(size: pointSize)
        for scale in [1, 2] {
            let pixels = Int(pointSize.width) * scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            rep.size = pointSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(scale: CGFloat(scale))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }()

    static func draw(scale: CGFloat) {
        let font = NSFont.systemFont(ofSize: 14.5 * scale, weight: .bold)
        let text = NSAttributedString(string: "Q", attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
        ])
        let size = text.size()
        text.draw(at: NSPoint(
            x: (pointSize.width * scale - size.width) / 2,
            y: (pointSize.height * scale - size.height) / 2 + 0.6 * scale
        ))
    }

    /// Offscreen render for evidence artifacts (no window server needed).
    static func png(scale: CGFloat = 4) -> Data? {
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(scale: scale)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
