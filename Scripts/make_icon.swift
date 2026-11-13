// Renders the app icon into an .iconset folder. Usage: swift make_icon.swift <out.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.09, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.30, alpha: 1)]))
    if let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = sun.size
        sun.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(points * scale).write(to: output.appendingPathComponent(name))
}
