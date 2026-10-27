import AppKit

// A static monochrome "Q" monogram for the menu bar. Static on purpose: the
// numeric label already carries the state, and a template image keeps macOS
// handling light/dark and accessibility correctly.
//
// Drawn through NSImage's resolution-independent handler: AppKit calls it at
// the display's scale, so the same 18pt coordinates render crisply at 1x and
// 2x. (Drawing into a hand-made bitmap rep at 2x and then resizing it caused
// the clipped glyph that shipped in 0.5.0.)

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
            ), let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            rep.size = pointSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // The context already maps 18pt to the rep's pixels; draw in points.
            draw()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }()

    static func draw() {
        let font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        let text = NSAttributedString(string: "Q", attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
        ])
        let size = text.size()
        // Optical centering: capital glyphs sit slightly high in their line box.
        let rect = NSRect(
            x: (pointSize.width - size.width) / 2,
            y: (pointSize.height - size.height) / 2 + 0.4,
            width: size.width,
            height: size.height
        )
        text.draw(in: rect)
    }

    /// Renders the actual NSImage at a given pixel size, so evidence shows what
    /// the menu bar gets rather than a parallel drawing path.
    static func png(pixelSize: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
