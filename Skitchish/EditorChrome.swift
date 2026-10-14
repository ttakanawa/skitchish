import AppKit

/// Neutral, compact chrome, drawn locally rather than using third-party artwork.
final class EditorChromeView: NSView {
    var topBorder = false
    var bottomBorder = false
    var isSidebar = false
    var onBackgroundClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if let onBackgroundClick { onBackgroundClick() } else { super.mouseDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if isSidebar {
            NSColor(white: 0.925, alpha: 1).setFill()
            bounds.fill()
        } else {
            NSGradient(starting: NSColor(white: 0.80, alpha: 1), ending: NSColor(white: 0.95, alpha: 1))?.draw(
                in: bounds, angle: 90)
        }
        NSColor(white: 0.75, alpha: 1).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        if topBorder {
            path.move(to: NSPoint(x: 0, y: bounds.maxY - 0.5))
            path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        }
        if bottomBorder {
            path.move(to: NSPoint(x: 0, y: 0.5))
            path.line(to: NSPoint(x: bounds.maxX, y: 0.5))
        }
        path.stroke()
    }
}

class EditorPaletteButton: NSButton {
    private(set) var isMouseHovering = false
    private var hoverTracking: NSTrackingArea?
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        isMouseHovering = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        isMouseHovering = false
        needsDisplay = true
    }

    /// Every toolbar glyph sits on the same quiet, inset surface. Keeping the
    /// hit region at 40 points leaves room around the 22-point optical artwork.
    func drawInteractionBackground(selected: Bool) {
        guard selected || (isEnabled && (isHighlighted || isMouseHovering)) else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
        if selected {
            let bottom = NSColor(srgbRed: 0.29, green: 0.31, blue: 0.34, alpha: 1)
            let top = NSColor(srgbRed: 0.36, green: 0.38, blue: 0.41, alpha: 1)
            NSGradient(starting: bottom, ending: isHighlighted ? bottom : top)?.draw(in: path, angle: 90)
            NSColor(white: 0, alpha: 0.12).setStroke()
        } else {
            NSColor(white: isHighlighted ? 0.80 : 0.99, alpha: isHighlighted ? 0.8 : 0.7).setFill()
            path.fill()
            NSColor(white: 0.54, alpha: isHighlighted ? 0.3 : 0.16).setStroke()
        }
        path.lineWidth = 0.75
        path.stroke()
    }

    func inkColor(selected: Bool) -> NSColor {
        selected ? .white : NSColor(srgbRed: 0.31, green: 0.33, blue: 0.36, alpha: 1)
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 7, yRadius: 7).fill()
    }
}

final class EditorToolButton: EditorPaletteButton {
    override var isFlipped: Bool { false }
    var tool: EditorTool { didSet { needsDisplay = true } }
    var stamp = 0 { didSet { needsDisplay = true } }
    var onOpenVariants: (() -> Void)?
    var alwaysOpensVariants = false
    init(tool: EditorTool, target: AnyObject?, action: Selector) {
        self.tool = tool
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setButtonType(.toggle)
        isBordered = false
        title = ""
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let onOpenVariants, alwaysOpensVariants || state == .on || (point.x > bounds.maxX - 12 && point.y < 14) {
            onOpenVariants()
            return
        }
        super.mouseDown(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        if let onOpenVariants { onOpenVariants() } else { super.rightMouseDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        if alwaysOpensVariants, let onOpenVariants {
            onOpenVariants()
            return true
        }
        return super.accessibilityPerformPress()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.3)
        let selected = state == .on
        drawInteractionBackground(selected: selected)
        let color = inkColor(selected: selected)
        if tool == .stamp {
            EditorStampButton.drawBadge(in: bounds, stamp: stamp, color: color, outlined: false)
        } else {
            EditorToolGlyph.draw(tool: tool, in: bounds, color: color, selected: selected)
        }
        if onOpenVariants != nil { drawDisclosure(in: bounds, color: color) }
    }
}

/// A current-style control that opens choices in place of the normal toolbar.
final class EditorStyleButton: EditorPaletteButton {
    override var isFlipped: Bool { false }
    enum Kind { case color, width }
    let kind: Kind
    var swatch = NSColor.red { didSet { needsDisplay = true } }
    var sizeIndex = 2 { didSet { needsDisplay = true } }
    init(kind: Kind, target: AnyObject?, action: Selector) {
        self.kind = kind
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        title = ""
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.3)
        drawStyleRing(in: bounds, selected: isEnabled && (isMouseHovering || isHighlighted))
        if kind == .color {
            swatch.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)).fill()
        } else {
            drawSizeSlash(in: bounds, sizeIndex: sizeIndex)
        }
        drawDisclosure(in: bounds, color: NSColor(white: 0.4, alpha: 1))
    }
}

final class EditorSizeButton: EditorPaletteButton {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.3)
        if state == .on || isMouseHovering || isHighlighted { drawStyleRing(in: bounds, selected: isHighlighted) }
        drawSizeSlash(in: bounds, sizeIndex: tag)
    }
}

private func drawSizeSlash(in bounds: NSRect, sizeIndex: Int) {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: bounds.midX - 6, y: bounds.midY - 6))
    line.line(to: NSPoint(x: bounds.midX + 6, y: bounds.midY + 6))
    line.lineCapStyle = .butt
    line.withStroke(NSColor(white: 0.4, alpha: 1), width: CGFloat(2 + max(0, min(4, sizeIndex)) * 2))
}

private func drawStyleRing(in bounds: NSRect, selected: Bool) {
    let outer = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24))
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.2)
    shadow.shadowOffset = NSSize(width: 0, height: -0.5)
    shadow.shadowBlurRadius = 0.7
    shadow.set()
    NSColor.white.setFill()
    outer.fill()
    NSGraphicsContext.restoreGraphicsState()
    outer.withStroke(NSColor(white: selected ? 0.43 : 0.72, alpha: 1), width: selected ? 2.4 : 0.8)
}

final class EditorPinButton: EditorPaletteButton {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawInteractionBackground(selected: state == .on)
        context.saveGState()
        context.setAlpha(isEnabled ? 1 : 0.3)
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: -.pi / 4)
        context.setFillColor(inkColor(selected: state == .on).cgColor)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -4, y: 7))
        path.addLine(to: CGPoint(x: 4, y: 7))
        path.addLine(to: CGPoint(x: 3, y: 5))
        path.addLine(to: CGPoint(x: 3, y: -1))
        path.addLine(to: CGPoint(x: 6, y: -4))
        path.addLine(to: CGPoint(x: 1, y: -4))
        path.addLine(to: CGPoint(x: 0, y: -11))
        path.addLine(to: CGPoint(x: -1, y: -4))
        path.addLine(to: CGPoint(x: -6, y: -4))
        path.addLine(to: CGPoint(x: -3, y: -1))
        path.addLine(to: CGPoint(x: -3, y: 5))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}

private func drawDisclosure(in bounds: NSRect, color: NSColor) {
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: bounds.maxX - 9.5, y: 8.5))
    chevron.line(to: NSPoint(x: bounds.maxX - 7.5, y: 6.5))
    chevron.line(to: NSPoint(x: bounds.maxX - 5.5, y: 8.5))
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.withStroke(color.withAlphaComponent(0.75), width: 1.1)
}

final class EditorColorButton: EditorPaletteButton {
    let swatch: NSColor
    var isCustomColor = false
    init(color: NSColor, target: AnyObject?, action: Selector) {
        swatch = color
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        setButtonType(.toggle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.3)
        drawStyleRing(in: bounds, selected: state == .on || (isEnabled && (isMouseHovering || isHighlighted)))
        let rect = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        let circle = NSBezierPath(ovalIn: rect)
        if isCustomColor {
            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            let colors: [NSColor] = [.red, .orange, .yellow, .green, .cyan, .blue, .magenta]
            NSGradient(colors: colors)?.draw(in: rect, angle: -45)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            swatch.setFill()
            circle.fill()
        }
    }
}

extension NSBezierPath {
    fileprivate func withStroke(_ color: NSColor, width: CGFloat) {
        color.setStroke()
        lineWidth = width
        stroke()
    }
}
