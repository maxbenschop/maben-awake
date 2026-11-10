import AppKit
import SwiftUI

/// The Maben Awake freeze icon ("Crystal"): a six-armed snowflake with a V on
/// each arm, the same drawing as on awake.maben.gg. Drawn as a template image,
/// so it takes the colour of the surrounding text like an SF Symbol.
enum FreezeIcon {
    /// Line segments in a 24 × 24 grid (y down), as on the website.
    private static let segments: [(CGPoint, CGPoint)] = {
        var s: [(CGPoint, CGPoint)] = [
            (.init(x: 12, y: 2), .init(x: 12, y: 22)),
            (.init(x: 3.3, y: 7), .init(x: 20.7, y: 17)),
            (.init(x: 20.7, y: 7), .init(x: 3.3, y: 17)),
        ]
        // The V on each arm end: (tip, left, right).
        let vs: [(CGPoint, CGPoint, CGPoint)] = [
            (.init(x: 12, y: 6), .init(x: 9.5, y: 3.8), .init(x: 14.5, y: 3.8)),
            (.init(x: 12, y: 18), .init(x: 9.5, y: 20.2), .init(x: 14.5, y: 20.2)),
            (.init(x: 7, y: 9.5), .init(x: 4, y: 10.3), .init(x: 6.3, y: 6.5)),
            (.init(x: 17, y: 9.5), .init(x: 20, y: 10.3), .init(x: 17.7, y: 6.5)),
            (.init(x: 7, y: 14.5), .init(x: 4, y: 13.7), .init(x: 6.3, y: 17.5)),
            (.init(x: 17, y: 14.5), .init(x: 20, y: 13.7), .init(x: 17.7, y: 17.5)),
        ]
        for (tip, a, b) in vs { s.append((a, tip)); s.append((tip, b)) }
        return s
    }()

    static func image(size: CGFloat, lineWidth: CGFloat = 1.9) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let scale = rect.width / 24
            let path = NSBezierPath()
            for (a, b) in segments {
                path.move(to: NSPoint(x: a.x * scale, y: a.y * scale))
                path.line(to: NSPoint(x: b.x * scale, y: b.y * scale))
            }
            path.lineWidth = lineWidth * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The freeze icon at a given point size, coloured by `.foregroundStyle`.
struct FreezeGlyph: View {
    var size: CGFloat
    var lineWidth: CGFloat = 1.9
    var body: some View {
        Image(nsImage: FreezeIcon.image(size: size * 2, lineWidth: lineWidth))
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
    }
}
