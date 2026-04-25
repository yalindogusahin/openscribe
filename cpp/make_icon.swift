// Generates AppIcon.icns from a programmatic design — no external assets.
// Run once: `swift make_icon.swift`. Commits the resulting AppIcon.icns.
import AppKit

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let iconset = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try? FileManager.default.createDirectory(atPath: iconset,
                                         withIntermediateDirectories: true)

func render(size: Int, to outPath: String) {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // Rounded background with vertical gradient — deep teal → blue.
    let radius = s * 0.225
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius,
                        cornerHeight: radius, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    let cs = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.16, green: 0.28, blue: 0.44, alpha: 1.0),
        CGColor(red: 0.08, green: 0.13, blue: 0.22, alpha: 1.0),
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: 0, y: 0),
                           options: [])

    // Subtle inner highlight on top edge.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.fill(CGRect(x: 0, y: s * 0.82, width: s, height: s * 0.18))

    // Waveform glyph: stylized symmetric bars in pale cyan.
    let bars: [CGFloat] = [
        0.18, 0.32, 0.55, 0.78, 0.92, 0.78, 0.55, 0.40,
        0.62, 0.85, 0.95, 0.85, 0.62, 0.40, 0.55, 0.78,
        0.55, 0.32, 0.18,
    ]
    let count = bars.count
    let usableW = s * 0.74
    let originX = (s - usableW) / 2
    let centerY = s * 0.50
    let maxBarH = s * 0.42
    let barW = usableW / CGFloat(count) * 0.55
    let gap = usableW / CGFloat(count)
    ctx.setFillColor(CGColor(red: 0.62, green: 0.85, blue: 1.0, alpha: 0.95))
    for i in 0..<count {
        let h = bars[i] * maxBarH
        let x = originX + CGFloat(i) * gap + (gap - barW) / 2
        let r = CGRect(x: x, y: centerY - h / 2, width: barW, height: h)
        let bp = CGPath(roundedRect: r,
                        cornerWidth: barW * 0.45,
                        cornerHeight: barW * 0.45,
                        transform: nil)
        ctx.addPath(bp)
    }
    ctx.fillPath()

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:])
    else { return }
    try? data.write(to: URL(fileURLWithPath: outPath))
}

for (sz, name) in sizes {
    render(size: sz, to: "\(iconset)/\(name)")
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", "AppIcon.icns"]
try task.run()
task.waitUntilExit()
print("Wrote AppIcon.icns")
