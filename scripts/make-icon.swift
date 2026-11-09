// Draws the app icon and writes Resources/AppIcon.icns.  Run: swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Background: night sky on the standard macOS icon shape.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.42, alpha: 1),
                        NSColor(red: 0.05, green: 0.06, blue: 0.17, alpha: 1)])!.draw(in: shape, angle: -90)
    shape.addClip()

    // Stars.
    NSColor(white: 1, alpha: 0.75).setFill()
    for (x, y, r) in [(250.0, 760.0, 7.0), (330, 640, 4), (760, 800, 5), (800, 600, 4), (210, 560, 4), (560, 830, 4)] {
        NSBezierPath(ovalIn: NSRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)).fill()
    }

    // Crescent moon.
    let moon = NSBezierPath(ovalIn: NSRect(x: 560 * s, y: 600 * s, width: 190 * s, height: 190 * s))
    let bite = NSBezierPath(ovalIn: NSRect(x: 620 * s, y: 640 * s, width: 170 * s, height: 170 * s))
    NSGraphicsContext.saveGraphicsState()
    let outside = NSBezierPath(rect: tile)
    outside.append(bite.reversed)
    outside.addClip()
    NSColor(red: 1.0, green: 0.84, blue: 0.48, alpha: 1).setFill()
    moon.fill()
    NSGraphicsContext.restoreGraphicsState()

    // A stack of three books.
    let books: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: NSColor)] = [
        (250, 230, 524, 100, NSColor(red: 0.93, green: 0.42, blue: 0.33, alpha: 1)),
        (290, 330, 470, 90, NSColor(red: 0.96, green: 0.91, blue: 0.80, alpha: 1)),
        (265, 420, 430, 96, NSColor(red: 0.36, green: 0.62, blue: 0.86, alpha: 1)),
    ]
    for book in books {
        let rect = NSRect(x: book.x * s, y: book.y * s, width: book.w * s, height: book.h * s)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16 * s, yRadius: 16 * s)
        book.color.setFill()
        path.fill()
        // Pages showing at the right-hand end, and a band on the spine.
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: (book.x + book.w - 70) * s, y: (book.y + 14) * s,
                                         width: 70 * s, height: (book.h - 28) * s),
                     xRadius: 6 * s, yRadius: 6 * s).fill()
        NSColor(white: 0, alpha: 0.16).setFill()
        NSBezierPath(rect: NSRect(x: (book.x + 60) * s, y: book.y * s, width: 26 * s, height: book.h * s)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let png = draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent(name))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try draw(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print("Wrote Resources/AppIcon.icns")
