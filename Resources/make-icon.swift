// Renders the Sleepwalker app icon: swift Resources/make-icon.swift <out.png>
// Deliberately minimal: an indigo squircle, one crescent moon, one sparkle.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Squircle on Apple's icon grid (824pt body, 100pt margin), soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
color(0x3B2F9E).setFill(); squircle.fill()
ctx.restoreGState()
ctx.saveGState()
squircle.addClip()
NSGradient(starting: color(0x5B4BDB), ending: color(0x2A1F7A))!.draw(in: body, angle: -90)
ctx.restoreGState()

// Crescent: full circle with an offset circle cut out (even-odd clip).
let moon = NSRect(x: 262, y: 262, width: 500, height: 500)
let bite = NSRect(x: 412, y: 372, width: 440, height: 440)
ctx.saveGState()
let cut = NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size))
cut.append(NSBezierPath(ovalIn: bite)); cut.windingRule = .evenOdd; cut.addClip()
color(0xFFFFFF).setFill(); NSBezierPath(ovalIn: moon).fill()
ctx.restoreGState()

// One four-point sparkle in the moon's opening.
let c = NSPoint(x: 668, y: 640), r: CGFloat = 70, w = r * 0.2
let star = NSBezierPath()
star.move(to: NSPoint(x: c.x, y: c.y + r))
star.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
star.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w), controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
star.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
star.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w), controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
color(0xFFFFFF).setFill(); star.fill()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
