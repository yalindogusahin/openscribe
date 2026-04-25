#!/usr/bin/env swift
// Generates AppIcon.icns from a procedurally-drawn waveform glyph.
// Usage: swift scripts/make-icon.swift

import AppKit
import CoreGraphics

let outDir = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: outDir)
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let w = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Rounded square dark background
    let radius = w * 0.225
    let rect = CGRect(x: 0, y: 0, width: w, height: w).insetBy(dx: w * 0.02, dy: w * 0.02)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    ctx.fillPath()

    // Subtle inner gradient
    let grad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.16, green: 0.16, blue: 0.20, alpha: 1),
            CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: w), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // Waveform bars
    let bars: [CGFloat] = [0.25, 0.55, 0.35, 0.85, 0.65, 0.95, 0.50, 0.75, 0.40, 0.60, 0.30]
    let barCount = CGFloat(bars.count)
    let area = rect.insetBy(dx: w * 0.10, dy: w * 0.18)
    let barW = area.width / (barCount + (barCount - 1) * 0.4)
    let gap = barW * 0.4
    let mid = area.midY
    let blue = CGColor(red: 0.39, green: 0.71, blue: 1.0, alpha: 1)
    ctx.setFillColor(blue)
    for (i, h) in bars.enumerated() {
        let x = area.minX + CGFloat(i) * (barW + gap)
        let half = h * area.height * 0.5
        let r = CGRect(x: x, y: mid - half, width: barW, height: half * 2)
        let p = CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
        ctx.addPath(p)
        ctx.fillPath()
    }

    // Red playhead
    let phX = area.minX + area.width * 0.62
    let phRect = CGRect(x: phX - w * 0.012, y: rect.minY + w * 0.05, width: w * 0.024, height: rect.height - w * 0.10)
    let phPath = CGPath(roundedRect: phRect, cornerWidth: w * 0.012, cornerHeight: w * 0.012, transform: nil)
    ctx.addPath(phPath)
    ctx.setFillColor(red: 1.0, green: 0.30, blue: 0.30, alpha: 1)
    ctx.fillPath()

    let cgImage = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])!
}

// macOS iconset sizes
let entries: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in entries {
    let data = drawIcon(size: size)
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    print("wrote \(name) (\(size)x\(size))")
}

// Convert to .icns
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["--convert", "icns", outDir, "--output", "AppIcon.icns"]
try task.run()
task.waitUntilExit()
print("wrote AppIcon.icns")
