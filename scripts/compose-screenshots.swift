// Composes README images from UI snapshots (`swift run UIChecks --snapshots <dir>`).
// Usage: swift scripts/compose-screenshots.swift <snapshots dir> <output dir>

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: compose-screenshots <snapshots> <output>\n".utf8))
    exit(64)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func image(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: input.appendingPathComponent(name + ".png")) else {
        fatalError("missing snapshot \(name).png")
    }
    return image
}

/// Places images side by side on a gradient, each with rounded corners and a soft shadow.
func compose(_ names: [String], dark: Bool, to file: String) {
    let images = names.map(image)
    let pixels = { (i: NSImage) in i.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? i.size }
    let sizes = images.map(pixels)
    let gap: CGFloat = 64, margin: CGFloat = 96
    let width = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(images.count - 1) + margin * 2
    let height = (sizes.map(\.height).max() ?? 0) + margin * 2

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let colors: [CGColor] = dark
        ? [CGColor(red: 0.10, green: 0.10, blue: 0.13, alpha: 1), CGColor(red: 0.20, green: 0.19, blue: 0.24, alpha: 1)]
        : [CGColor(red: 0.90, green: 0.91, blue: 0.95, alpha: 1), CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

    var x = margin
    for (img, size) in zip(images, sizes) {
        let rect = CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
        let path = CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.25))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: dark ? 0.15 : 0.96, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        img.draw(in: rect)
        ctx.restoreGState()
        x += size.width + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: output.appendingPathComponent(file))
    print(output.appendingPathComponent(file).path)
}

compose(["popover-breathe-dark", "popover-agents-dark", "popover-music-dark"], dark: true, to: "hero-dark.png")
compose(["popover-breathe-light", "popover-agents-light", "popover-music-light"], dark: false, to: "hero-light.png")
compose(["settings-light"], dark: false, to: "settings.png")
compose(["preview-window-dark"], dark: true, to: "preview.png")
