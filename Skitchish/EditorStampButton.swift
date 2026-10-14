import AppKit

/// Stamp choices use the same badge and symbol geometry as the canvas.
final class EditorStampButton: EditorPaletteButton {
    override var isFlipped: Bool { false }

    var stamp: Int {
        didSet {
            setAccessibilityLabel(Self.symbol(for: stamp))
            needsDisplay = true
        }
    }

    init(stamp: Int, target: AnyObject?, action: Selector) {
        self.stamp = stamp
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        setButtonType(.toggle)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.symbol(for: stamp))
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        drawInteractionBackground(selected: state == .on)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.3)
        Self.drawBadge(
            in: bounds, stamp: stamp, color: Markup.stampColors[Self.index(for: stamp)].nsColor, outlined: true)
    }

    private static let badgeSilhouette: CGPath = {
        var mark = Markup(tool: .stamp, points: [CGPoint(x: -0.5, y: -0.5), CGPoint(x: 0.5, y: 0.5)])
        mark.tail = true
        mark.tailDirection = 4
        return mark.stampLocalSilhouette
    }()

    static func drawBadge(in bounds: NSRect, stamp: Int, color: NSColor, outlined: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The primary glyph has the visual weight of the other 22-point tools.
        // Palette badges are larger so their colored ring remains easy to read.
        let diameter: CGFloat = outlined ? 22 : 18
        let outlineWidth: CGFloat = 1.2 / diameter
        let silhouette = badgeSilhouette
        let extent = silhouette.boundingBoxOfPath
        let interior = CGRect(x: -0.35, y: -0.35, width: 0.7, height: 0.7)
        context.saveGState()
        // Center the complete silhouette, including its left pointer.
        context.translateBy(x: bounds.midX - extent.midX * diameter, y: bounds.midY)
        context.scaleBy(x: diameter, y: -diameter)
        context.setLineJoin(.round)
        context.setFillColor(color.cgColor)
        context.addPath(silhouette)
        if outlined {
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(outlineWidth)
            context.drawPath(using: .fillStroke)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: interior)
        } else {
            // A transparent counter works on normal, hover and selected surfaces.
            context.addEllipse(in: interior)
            context.fillPath(using: .evenOdd)
        }
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        // Keep punctuation away from the ring without making the compact × faint.
        let symbolScale: CGFloat = [0.94, 1.12, 0.9, 0.9, 0.96][index(for: stamp)]
        context.scaleBy(x: symbolScale, y: symbolScale)
        EditorRenderer.drawStampSymbol(stamp: index(for: stamp), in: context)
        context.restoreGState()
    }

    private static func index(for stamp: Int) -> Int { max(0, min(4, stamp)) }
    static func symbol(for stamp: Int) -> String { ["✓", "×", "?", "!", "♥"][index(for: stamp)] }
}
