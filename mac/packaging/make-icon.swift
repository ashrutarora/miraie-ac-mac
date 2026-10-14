// Draws the app icon (a white snowflake on a blue rounded square, on the
// macOS icon grid) and writes AppIcon.icns into the folder given.
//   swift mac/packaging/make-icon.swift <out-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    // Apple's grid: an 824-point square with a 185-point corner, centred.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor(srgbRed: 0.16, green: 0.42, blue: 0.95, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.66, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.12, green: 0.36, blue: 0.92, alpha: 1)])!
        .draw(in: shape, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    let flake = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let size = flake.size
    flake.draw(in: NSRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                          width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try! render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
