// Renders Resources/AppIcon.icns: a dark squircle with a glowing island pill.
// Usage: swift scripts/make-icon.swift  (from the package root)
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.04, alpha: 1)])!.draw(in: squircle, angle: -90)

    // The island pill near the top.
    let pillW = body.width * 0.56, pillH = body.width * 0.17
    let pill = NSRect(x: body.midX - pillW / 2, y: body.maxY - body.height * 0.3, width: pillW, height: pillH)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)
    NSColor.black.setFill()
    pillPath.fill()
    NSColor(white: 1, alpha: 0.12).setStroke()
    pillPath.lineWidth = max(1, s * 0.004)
    pillPath.stroke()

    // Accent dot (live activity) and a little tray glyph under it.
    let dot = pillH * 0.42
    NSColor(red: 0.38, green: 0.64, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: pill.maxX - pillH * 0.5 - dot / 2, y: pill.midY - dot / 2, width: dot, height: dot)).fill()

    let trayW = body.width * 0.34, trayH = body.width * 0.2
    let tray = NSRect(x: body.midX - trayW / 2, y: body.minY + body.height * 0.2, width: trayW, height: trayH)
    let trayPath = NSBezierPath()
    trayPath.move(to: NSPoint(x: tray.minX, y: tray.maxY))
    trayPath.line(to: NSPoint(x: tray.minX, y: tray.minY))
    trayPath.line(to: NSPoint(x: tray.maxX, y: tray.minY))
    trayPath.line(to: NSPoint(x: tray.maxX, y: tray.maxY))
    trayPath.lineWidth = s * 0.03
    trayPath.lineCapStyle = .round
    trayPath.lineJoinStyle = .round
    NSColor(white: 1, alpha: 0.85).setStroke()
    trayPath.stroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: tray.midX, y: tray.maxY + trayH * 0.55))
    arrow.line(to: NSPoint(x: tray.midX, y: tray.minY + trayH * 0.3))
    arrow.move(to: NSPoint(x: tray.midX - trayW * 0.16, y: tray.minY + trayH * 0.62))
    arrow.line(to: NSPoint(x: tray.midX, y: tray.minY + trayH * 0.3))
    arrow.line(to: NSPoint(x: tray.midX + trayW * 0.16, y: tray.minY + trayH * 0.62))
    arrow.lineWidth = s * 0.03
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
