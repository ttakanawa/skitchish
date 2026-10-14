import AppKit
import CoreText

/// Toolbar artwork uses a centered, upward-y, 24-point optical canvas inside a
/// 40-point control. These paths deliberately stay separate from document geometry.
enum EditorToolGlyph {
    static func draw(tool: EditorTool, in bounds: NSRect, color: NSColor, selected: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: bounds.midX, y: bounds.midY)
        let scale = min(bounds.width, bounds.height) / 40
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2.1)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch tool {
        case .select:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -7.5, y: 10.5))
            path.addLine(to: CGPoint(x: -6.7, y: -8))
            path.addLine(to: CGPoint(x: -2.2, y: -3.9))
            path.addLine(to: CGPoint(x: 1.4, y: -10.5))
            path.addLine(to: CGPoint(x: 4.5, y: -8.8))
            path.addLine(to: CGPoint(x: 0.9, y: -2.4))
            path.addLine(to: CGPoint(x: 7.3, y: -1.7))
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        case .arrow:
            drawArrow(in: context)
        case .text:
            let font = NSFont(name: "Helvetica-Bold", size: 34) ?? NSFont.boldSystemFont(ofSize: 34)
            let text = NSAttributedString(string: "a", attributes: [.font: font, .foregroundColor: color])
            let line = CTLineCreateWithAttributedString(text)
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY + 0.1)
            CTLineDraw(line, context)
        case .rectangle:
            context.stroke(CGRect(x: -10.5, y: -7.5, width: 21, height: 15))
        case .roundedRectangle:
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: -10.5, y: -7.5, width: 21, height: 15),
                    cornerWidth: 3.8, cornerHeight: 3.8, transform: nil))
            context.strokePath()
        case .ellipse:
            context.strokeEllipse(in: CGRect(x: -10.5, y: -8, width: 21, height: 16))
        case .line:
            context.move(to: CGPoint(x: -8.5, y: -8.5))
            context.addLine(to: CGPoint(x: 8.5, y: 8.5))
            context.strokePath()
        case .pen:
            drawPencil(in: context)
        case .highlight:
            drawHighlighter(in: context)
        case .pixelate:
            drawPixelation(in: context, color: color, selected: selected)
        case .crop:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -10.5, y: 6.5))
            path.addLine(to: CGPoint(x: 6.5, y: 6.5))
            path.addLine(to: CGPoint(x: 6.5, y: -10.5))
            path.move(to: CGPoint(x: -6.5, y: 10.5))
            path.addLine(to: CGPoint(x: -6.5, y: -6.5))
            path.addLine(to: CGPoint(x: 10.5, y: -6.5))
            context.addPath(path)
            context.strokePath()
        case .stamp:
            // The stamp button displays the currently selected marker and its color.
            break
        }
    }

    private static func drawArrow(in context: CGContext) {
        context.saveGState()
        context.rotate(by: -.pi * 0.75)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -12, y: -0.45))
        path.addCurve(
            to: CGPoint(x: 4.9, y: -2.35),
            control1: CGPoint(x: -5.9, y: -0.65), control2: CGPoint(x: 0.7, y: -1.0))
        path.addLine(to: CGPoint(x: 2.8, y: -6.0))
        path.addLine(to: CGPoint(x: 12, y: 0))
        path.addLine(to: CGPoint(x: 2.8, y: 6.0))
        path.addLine(to: CGPoint(x: 4.9, y: 2.35))
        path.addCurve(
            to: CGPoint(x: -12, y: 0.45),
            control1: CGPoint(x: 0.7, y: 1.0), control2: CGPoint(x: -5.9, y: 0.65))
        path.addCurve(
            to: CGPoint(x: -12, y: -0.45),
            control1: CGPoint(x: -12.6, y: 0.45), control2: CGPoint(x: -12.6, y: -0.45))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    private static func drawPencil(in context: CGContext) {
        context.saveGState()
        context.rotate(by: -.pi / 4)
        // Separate barrel, end cap, and sharpened wood leave crisp negative-space
        // seams at small sizes, so the silhouette reads as a pencil rather than a bar.
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: -3.2, y: -3.8, width: 6.4, height: 11.6),
                cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
        context.fillPath()
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: -3.2, y: 9, width: 6.4, height: 3.1),
                cornerWidth: 1.0, cornerHeight: 1.0, transform: nil))
        context.fillPath()
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: -3.2, y: -5.1))
        tip.addLine(to: CGPoint(x: 3.2, y: -5.1))
        tip.addLine(to: CGPoint(x: 0, y: -11))
        tip.closeSubpath()
        context.addPath(tip)
        context.fillPath()
        context.restoreGState()
    }

    private static func drawHighlighter(in context: CGContext) {
        context.saveGState()
        context.rotate(by: -.pi / 4)
        let barrel = CGMutablePath()
        barrel.move(to: CGPoint(x: -4.1, y: 9.5))
        barrel.addLine(to: CGPoint(x: 4.1, y: 9.5))
        barrel.addLine(to: CGPoint(x: 4.1, y: -1.9))
        barrel.addLine(to: CGPoint(x: 2.4, y: -4.1))
        barrel.addLine(to: CGPoint(x: -2.4, y: -4.1))
        barrel.addLine(to: CGPoint(x: -4.1, y: -1.9))
        barrel.closeSubpath()
        context.addPath(barrel)
        context.strokePath()
        context.move(to: CGPoint(x: -4.1, y: 5.8))
        context.addLine(to: CGPoint(x: 4.1, y: 5.8))
        context.strokePath()
        let nib = CGMutablePath()
        nib.move(to: CGPoint(x: -2.4, y: -5.2))
        nib.addLine(to: CGPoint(x: 2.4, y: -5.2))
        nib.addLine(to: CGPoint(x: 2.4, y: -8.0))
        nib.addLine(to: CGPoint(x: -2.4, y: -10))
        nib.closeSubpath()
        context.addPath(nib)
        context.fillPath()
        context.restoreGState()
    }

    private static func drawPixelation(in context: CGContext, color: NSColor, selected: Bool) {
        context.setLineWidth(1.7)
        let frame = CGMutablePath()
        frame.move(to: CGPoint(x: 0, y: 8))
        frame.addLine(to: CGPoint(x: -9, y: 8))
        frame.addQuadCurve(to: CGPoint(x: -10, y: 7), control: CGPoint(x: -10, y: 8))
        frame.addLine(to: CGPoint(x: -10, y: -7))
        frame.addQuadCurve(to: CGPoint(x: -9, y: -8), control: CGPoint(x: -10, y: -8))
        frame.addLine(to: CGPoint(x: 0, y: -8))
        context.addPath(frame)
        context.strokePath()
        context.fillEllipse(in: CGRect(x: -7.8, y: 2.8, width: 3.0, height: 3.0))
        context.move(to: CGPoint(x: -9.8, y: -3.3))
        context.addLine(to: CGPoint(x: -6.4, y: 0.2))
        context.addLine(to: CGPoint(x: -2.0, y: -4.3))
        context.addLine(to: CGPoint(x: 0.7, y: -1.6))
        context.strokePath()
        // The right half dissolves into image blocks; the intact landscape on the
        // left distinguishes this from a grid of applications or an app launcher.
        let tiles: [(CGRect, CGFloat)] = [
            (CGRect(x: 0.5, y: -8, width: 4.7, height: 4.7), 0.55),
            (CGRect(x: 6.3, y: -8, width: 4.7, height: 4.7), 1),
            (CGRect(x: 0.5, y: -2.2, width: 4.7, height: 4.7), 1),
            (CGRect(x: 6.3, y: -2.2, width: 4.7, height: 4.7), 0.42),
            (CGRect(x: 0.5, y: 3.6, width: 4.7, height: 4.7), 0.42),
            (CGRect(x: 6.3, y: 3.6, width: 4.7, height: 4.7), 0.82),
        ]
        for (rect, opacity) in tiles {
            let alpha = selected ? 0.6 + opacity * 0.4 : opacity
            context.setFillColor(color.withAlphaComponent(color.alphaComponent * alpha).cgColor)
            context.fill(rect)
        }
    }
}
