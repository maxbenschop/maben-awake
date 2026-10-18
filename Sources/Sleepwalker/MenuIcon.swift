import AppKit

/// Menu bar icon: a crescent moon (the Mac "sleeps"), outlined when the Mac
/// may sleep, filled when it's kept awake, with a sparkle while an AI works
/// and an exclamation mark after a heat cutoff. Template images, so macOS
/// tints them for light and dark menu bars.
enum MenuIcon {
    enum State { case idle, awake, aiWorking, overheated }

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let moon = crescent(center: NSPoint(x: 8, y: 8.5), radius: 6.5,
                                bite: NSPoint(x: 12, y: 11.5), biteRadius: 5.6)
            switch state {
            case .idle, .overheated:
                moon.lineWidth = 1.4
                moon.stroke()
            case .awake, .aiWorking:
                moon.fill()
            }
            if state == .aiWorking { sparkle(center: NSPoint(x: 14.5, y: 14.5), radius: 3.3).fill() }
            if state == .overheated {
                NSBezierPath(roundedRect: NSRect(x: 14, y: 7, width: 1.8, height: 7), xRadius: 0.9, yRadius: 0.9).fill()
                NSBezierPath(ovalIn: NSRect(x: 13.9, y: 3.6, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Circle minus an overlapping circle: the moon's outer arc, then the
    /// bite's inner arc back to the start.
    private static func crescent(center c: NSPoint, radius r: CGFloat,
                                 bite b: NSPoint, biteRadius br: CGFloat) -> NSBezierPath {
        func circle(_ o: NSPoint, _ rad: CGFloat, _ a: CGFloat) -> NSPoint {
            NSPoint(x: o.x + rad * cos(a), y: o.y + rad * sin(a))
        }
        // Angles where the two circles intersect, seen from each center.
        let d = hypot(b.x - c.x, b.y - c.y)
        let toBite = atan2(b.y - c.y, b.x - c.x)
        let alpha = acos((r * r + d * d - br * br) / (2 * r * d))        // at moon center
        let beta = acos((br * br + d * d - r * r) / (2 * br * d))         // at bite center
        let fromBite = toBite + .pi

        let path = NSBezierPath()
        let steps = 48
        // Outer arc: moon circle, going the long way around away from the bite.
        for i in 0...steps {
            let a = toBite + alpha + CGFloat(i) / CGFloat(steps) * (2 * .pi - 2 * alpha)
            i == 0 ? path.move(to: circle(c, r, a)) : path.line(to: circle(c, r, a))
        }
        // Inner arc: bite circle between the intersections, inside the moon.
        for i in 0...steps {
            let a = fromBite - beta + CGFloat(i) / CGFloat(steps) * (2 * beta)
            path.line(to: circle(b, br, a))
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    /// Four-point star.
    private static func sparkle(center c: NSPoint, radius r: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let w = r * 0.28
        p.move(to: NSPoint(x: c.x, y: c.y + r))
        p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
        p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w), controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
        p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
        p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w), controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
        p.close()
        return p
    }
}
