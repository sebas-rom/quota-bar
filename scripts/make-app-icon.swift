#!/usr/bin/env swift
// Generates the QuotaBar app icon (.icns) — a graphite rounded square with two
// static meters. Run: swift scripts/make-app-icon.swift [out.iconset]

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/QuotaBar.iconset"

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("context") }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Plate
    let inset = s * 0.085
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 0.225
    let platePath = rounded(plate, radius)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [
        CGColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1),
        CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: s),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }
    // Soft top light (gradient, no hard edge)
    let highlight = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.07),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    if let g = CGGradient(colorsSpace: cs, colors: highlight, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s * 0.62), options: [])
    }
    ctx.restoreGState()

    // Inner border
    ctx.addPath(platePath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()

    // Meters
    let barWidth = s * 0.56
    let barHeight = s * 0.080
    let barX = (s - barWidth) / 2
    let radiusBar = barHeight / 2

    struct Meter { let y: CGFloat; let value: CGFloat; let color: CGColor }
    let amber = CGColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)
    let green = CGColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    let meters = [
        Meter(y: s * 0.535, value: 0.68, color: amber),
        Meter(y: s * 0.395, value: 0.34, color: green),
    ]

    for meter in meters {
        let rect = CGRect(x: barX, y: meter.y, width: barWidth, height: barHeight)
        ctx.addPath(rounded(rect, radiusBar))
        ctx.setFillColor(CGColor(red: 0.24, green: 0.24, blue: 0.27, alpha: 1))
        ctx.fillPath()

        let fillRect = CGRect(x: barX, y: meter.y, width: max(barHeight, barWidth * meter.value), height: barHeight)
        ctx.addPath(rounded(fillRect, radiusBar))
        ctx.setFillColor(meter.color)
        ctx.fillPath()
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("dest")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (name, size) in variants {
    writePNG(render(size: size), to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
// Preview image for review artifacts.
writePNG(render(size: 1024), to: URL(fileURLWithPath: outDir).deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))
print("wrote \(outDir) + AppIcon-1024.png")
