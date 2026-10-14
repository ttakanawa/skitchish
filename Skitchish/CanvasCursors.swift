import AppKit

@MainActor
enum CanvasCursors {
    static let pixelate: NSCursor = {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { _ in
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: 1, y: 7))
            cross.line(to: CGPoint(x: 13, y: 7))
            cross.move(to: CGPoint(x: 7, y: 1))
            cross.line(to: CGPoint(x: 7, y: 13))
            NSColor.white.setStroke()
            cross.lineWidth = 4
            cross.stroke()
            NSColor.black.setStroke()
            cross.lineWidth = 1.5
            cross.stroke()
            NSColor.white.setFill()
            CGRect(x: 14, y: 14, width: 17, height: 17).fill()
            for row in 0..<3 {
                for column in 0..<3 {
                    let shades: [CGFloat] = [0.12, 0.7, 0.35]
                    NSColor(calibratedWhite: shades[(row + column * 2) % 3], alpha: 1).setFill()
                    CGRect(x: CGFloat(15 + column * 5), y: CGFloat(15 + row * 5), width: 5, height: 5).fill()
                }
            }
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 7, y: 7))
    }()

    static let diagonalResize = makeDiagonalResizeCursor(reversed: false)
    static let reverseDiagonalResize = makeDiagonalResizeCursor(reversed: true)

    private static func makeDiagonalResizeCursor(reversed: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: reversed ? 20 - x : x, y: y) }
            let path = NSBezierPath()
            path.move(to: p(3, 3))
            path.line(to: p(17, 17))
            path.move(to: p(3, 9))
            path.line(to: p(3, 3))
            path.line(to: p(9, 3))
            path.move(to: p(11, 17))
            path.line(to: p(17, 17))
            path.line(to: p(17, 11))
            NSColor.white.setStroke()
            path.lineWidth = 4
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 10, y: 10))
    }
}
