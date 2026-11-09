// Renders the app icon (an abstract glowing ring — not Apple's logo) to an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-square "lid" in near-black aluminium.
    let inset = s * 0.09
    let lid = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let lidPath = CGPath(roundedRect: lid, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
    ctx.addPath(lidPath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space,
                        colors: [CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1),
                                 CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // Soft glow.
    let center = CGPoint(x: s / 2, y: s / 2)
    let glow = CGGradient(colorsSpace: space,
                          colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
                                   CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: s * 0.08, endCenter: center,
                           endRadius: s * 0.42, options: [])

    // Bright dot.
    let r = s * 0.13
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
    ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: px).write(to: outDir.appendingPathComponent(name))
    }
}
print(outDir.path)
