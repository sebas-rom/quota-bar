import AppKit

// Two stacked meter marks, matching the app icon. At 18pt a letter monogram
// read as a search glyph; two bars are unmistakable at menu-bar size and need
// no colour (template images are monochrome by definition).
//
// Rendered once at 4x into a plain pixel context and then given an 18pt size.
// This avoids NSImageRep/coordinate-scale ambiguity entirely: 1 unit = 1 pixel
// while drawing, and AppKit downsamples the 72px bitmap for 1x/2x displays.

enum MenuBarIcon {
    static let pointSize = NSSize(width: 18, height: 18)

    static let image: NSImage = {
        guard let data = renderPNG(pixelSize: 72), let image = NSImage(data: data) else {
            return NSImage(size: pointSize)
        }
        image.size = pointSize
        image.isTemplate = true
        return image
    }()

    static func draw(scale: CGFloat) {
        NSColor.black.setFill()
        let bars: [(width: CGFloat, y: CGFloat)] = [
            (13.2, 10.1),
            (8.4, 4.9),
        ]
        for bar in bars {
            let rect = NSRect(
                x: 2.7 * scale, y: bar.y * scale,
                width: bar.width * scale, height: 3.0 * scale
            )
            NSBezierPath(
                roundedRect: rect,
                xRadius: 1.5 * scale, yRadius: 1.5 * scale
            ).fill()
        }
    }

    static func renderPNG(pixelSize: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(scale: CGFloat(pixelSize) / pointSize.width)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Evidence artifact: what the template bitmap actually contains.
    static func png(pixelSize: Int = 72) -> Data? {
        renderPNG(pixelSize: pixelSize)
    }
}
