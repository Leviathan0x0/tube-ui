import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
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

for (name, pixels) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor.clear.setFill()
    canvas.fill()
    let shape = NSBezierPath(roundedRect: canvas, xRadius: CGFloat(pixels) * 0.2237, yRadius: CGFloat(pixels) * 0.2237)
    NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
    shape.fill()
    NSColor.white.setFill()
    let play = NSBezierPath()
    let width = CGFloat(pixels)
    let height = CGFloat(pixels)
    play.move(to: NSPoint(x: width * 0.40, y: height * 0.30))
    play.line(to: NSPoint(x: width * 0.40, y: height * 0.70))
    play.line(to: NSPoint(x: width * 0.73, y: height * 0.50))
    play.close()
    play.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Couldn't encode \(name)\n", stderr)
        exit(1)
    }
    try png.write(to: output.appendingPathComponent(name))
}
