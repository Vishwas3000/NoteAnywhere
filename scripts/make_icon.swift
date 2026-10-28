// Draws the app icon: a note floating over an app window, the overlay idea. Writes a 1024 px PNG to the given path.
// Usage: swift scripts/make_icon.swift out.png   (scripts/install.sh turns it into AppIcon.icns)
import AppKit

let size: CGFloat = 1024
// A bitmap at exactly 1024 px; NSImage.lockFocus would render at the screen's 2x scale.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824 px tile centred on the 1024 canvas, with room for the drop shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = .black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
rgb(0x3B47D6).setFill()
tilePath.fill()
ctx.restoreGState()
NSGradient(starting: rgb(0x5B6CFF), ending: rgb(0x2E2A9E))!.draw(in: tilePath, angle: -90)

// The app underneath: a translucent window with traffic lights and content bars.
let window = NSRect(x: 190, y: 300, width: 520, height: 440)
let windowPath = NSBezierPath(roundedRect: window, xRadius: 44, yRadius: 44)
NSColor.white.withAlphaComponent(0.16).setFill()
windowPath.fill()
NSColor.white.withAlphaComponent(0.28).setStroke()
windowPath.lineWidth = 4
windowPath.stroke()
for (i, color) in [0xFF6159, 0xFFBD2E, 0x28C941].enumerated() {
    rgb(UInt32(color), 0.9).setFill()
    NSBezierPath(ovalIn: NSRect(x: window.minX + 40 + CGFloat(i) * 46, y: window.maxY - 66, width: 28, height: 28)).fill()
}
NSColor.white.withAlphaComponent(0.22).setFill()
for (i, width) in [300.0, 230, 270].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: window.minX + 40, y: window.maxY - 140 - CGFloat(i) * 54, width: width, height: 22),
                 xRadius: 11, yRadius: 11).fill()
}

// The note on top, slightly tilted, with a soft shadow.
ctx.saveGState()
ctx.translateBy(x: 600, y: 400)
ctx.rotate(by: -0.07)
let note = NSRect(x: -210, y: -200, width: 420, height: 400)
let notePath = NSBezierPath(roundedRect: note, xRadius: 40, yRadius: 40)
ctx.saveGState()
let noteShadow = NSShadow()
noteShadow.shadowColor = .black.withAlphaComponent(0.35)
noteShadow.shadowOffset = NSSize(width: 0, height: -18)
noteShadow.shadowBlurRadius = 40
noteShadow.set()
rgb(0xFFF8E1).setFill()
notePath.fill()
ctx.restoreGState()
// Yellow header band, like Notes.
ctx.saveGState()
notePath.addClip()
NSGradient(starting: rgb(0xFFD84D), ending: rgb(0xFFC21A))!.draw(in: NSRect(x: note.minX, y: note.maxY - 92, width: note.width, height: 92), angle: -90)
ctx.restoreGState()
// Text lines, the first one a checked item.
rgb(0x34C759).setFill()
NSBezierPath(ovalIn: NSRect(x: note.minX + 40, y: note.maxY - 166, width: 40, height: 40)).fill()
let check = NSBezierPath()
check.move(to: NSPoint(x: note.minX + 50, y: note.maxY - 146))
check.line(to: NSPoint(x: note.minX + 58, y: note.maxY - 155))
check.line(to: NSPoint(x: note.minX + 71, y: note.maxY - 137))
check.lineWidth = 6
check.lineCapStyle = .round
check.lineJoinStyle = .round
NSColor.white.setStroke()
check.stroke()
rgb(0xC9C2AE).setFill()
NSBezierPath(roundedRect: NSRect(x: note.minX + 100, y: note.maxY - 156, width: 260, height: 22), xRadius: 11, yRadius: 11).fill()
for (i, width) in [340.0, 300, 220].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: note.minX + 40, y: note.maxY - 220 - CGFloat(i) * 52, width: width, height: 22),
                 xRadius: 11, yRadius: 11).fill()
}
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
