import AppKit
import CoreText

/// Screen-space controls for a selected marker. These decorations never enter
/// the document renderer or change the marker's image-space geometry.
@MainActor
struct StampSelectionChrome {
    enum Action: Equatable {
        case addLabel, removeLabel, pointer
    }

    static let color = TextSelectionChrome.color
    private static let lineWidth: CGFloat = 1.5
    private static let labelButtonSize: CGFloat = 28
    private static let controlRadius: CGFloat = 6
    private static let controlHitRadius: CGFloat = 10

    let ringRect: CGRect
    let labelButtonRect: CGRect?
    let pointerCenter: CGPoint
    let removeLabelCenter: CGPoint?
    let labelDirection: CGPoint
    private let hasPointer: Bool
    private let viewLabel: CGRect?

    init(mark: Markup, mapping: CanvasTransform) {
        hasPointer = mark.tail
        let circle = mapping.viewRect(mark.stampCircleBounds)
        let center = CGPoint(x: circle.midX, y: circle.midY)
        let radius = max(42, max(circle.width, circle.height) * 1.35)
        ringRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        let label = mark.stampLabelBounds
        viewLabel = label.isNull ? nil : mapping.viewRect(label)
        if label.isNull {
            let localCircle = mark.stampLocalCircleBounds
            let localLeft = CGPoint(x: localCircle.midX - 1, y: localCircle.midY)
            let left = mapping.viewPoint(localLeft.applying(mark.stampTransform))
            labelDirection = Self.unitVector(from: center, to: left)
        } else {
            let labelCenter = mapping.viewPoint(CGPoint(x: label.midX, y: label.midY))
            labelDirection = Self.unitVector(from: center, to: labelCenter)
        }

        let pointerDirection: CGPoint
        if let tip = mark.stampTailTip {
            pointerDirection = Self.unitVector(from: center, to: mapping.viewPoint(tip))
        } else {
            pointerDirection = CGPoint(x: -labelDirection.x, y: -labelDirection.y)
        }
        if label.isNull {
            let buttonCenter = CGPoint(
                x: center.x + labelDirection.x * (radius + Self.labelButtonSize / 2),
                y: center.y + labelDirection.y * (radius + Self.labelButtonSize / 2))
            labelButtonRect = Self.centeredRect(at: buttonCenter, radius: Self.labelButtonSize / 2)
            removeLabelCenter = nil
        } else {
            labelButtonRect = nil
            let viewLabel = mapping.viewRect(label)
            let edge = Self.outerEdge(of: viewLabel, direction: labelDirection)
            removeLabelCenter = CGPoint(
                x: edge.x + labelDirection.x * Self.controlRadius,
                y: edge.y + labelDirection.y * Self.controlRadius)
        }
        let ringPoint = CGPoint(
            x: center.x + pointerDirection.x * radius,
            y: center.y + pointerDirection.y * radius)
        pointerCenter = Self.pointerLocation(
            ringPoint: ringPoint, tailTip: mark.stampTailTip.map(mapping.viewPoint),
            direction: pointerDirection, label: viewLabel, removeCenter: removeLabelCenter)
    }

    var pointerHitRect: CGRect {
        let rect = Self.centeredRect(at: pointerCenter, radius: Self.controlHitRadius)
        guard let label = viewLabel else { return rect }
        // The larger hit target must not intercept clicks inside the label even
        // when a small marker leaves only a narrow gap beside its pointer.
        return Self.excluding(label.insetBy(dx: -1, dy: -1), from: rect, keeping: pointerCenter)
    }

    var removeLabelHitRect: CGRect? {
        removeLabelCenter.map { Self.centeredRect(at: $0, radius: Self.controlHitRadius) }
    }

    /// Register these same regions as cursor rectangles so cursor and action
    /// boundaries agree, including at small zoom levels.
    var cursorRegions: [CGRect] {
        [labelButtonRect, removeLabelHitRect, pointerHitRect].compactMap { $0 }
    }

    func action(at point: CGPoint) -> Action? {
        // A leftward pointer can meet the label tab. Resolve intersecting regions
        // by the visible controls' centers so both controls remain reachable.
        var regions: [(Action, CGRect, CGPoint)] = [(.pointer, pointerHitRect, pointerCenter)]
        if let rect = labelButtonRect { regions.append((.addLabel, rect, CGPoint(x: rect.midX, y: rect.midY))) }
        if let rect = removeLabelHitRect, let center = removeLabelCenter {
            regions.append((.removeLabel, rect, center))
        }
        return regions.filter { $0.1.contains(point) }
            .min { lhs, rhs in
                hypot(point.x - lhs.2.x, point.y - lhs.2.y)
                    < hypot(point.x - rhs.2.x, point.y - rhs.2.y)
            }?.0
    }

    func hitTest(_ point: CGPoint) -> Action? { action(at: point) }

    func draw(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(Self.lineWidth)
        context.setStrokeColor(Self.color.cgColor)
        context.saveGState()
        if let label = viewLabel {
            context.addRect(ringRect.insetBy(dx: -2, dy: -2))
            context.addRect(label.insetBy(dx: -3, dy: -3))
            context.clip(using: .evenOdd)
        }
        context.strokeEllipse(in: ringRect)
        context.restoreGState()
        if let rect = labelButtonRect { drawLabelButton(in: context, rect: rect) }
        drawRoundControl(in: context, center: pointerCenter, glyph: hasPointer ? nil : .pointer)
        if let center = removeLabelCenter { drawRoundControl(in: context, center: center, glyph: .removeLabel) }
    }

    private func drawLabelButton(in context: CGContext, rect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(NSColor.black.cgColor)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.25)
        context.addPath(
            CGPath(roundedRect: rect.insetBy(dx: 0.625, dy: 0.625), cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.drawPath(using: .fillStroke)

        let font = NSFont(name: "HelveticaNeue-Bold", size: 21) ?? NSFont.boldSystemFont(ofSize: 21)
        let text = NSAttributedString(string: "a", attributes: [.font: font, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        // Canvas coordinates point downwards; flip Core Text locally while keeping
        // the control upright when the underlying marker rotates or mirrors.
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
        CTLineDraw(line, context)
    }

    private func drawRoundControl(in context: CGContext, center: CGPoint, glyph: Action?) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(Self.color.cgColor)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.25)
        context.addEllipse(in: Self.centeredRect(at: center, radius: Self.controlRadius))
        context.drawPath(using: .fillStroke)
        guard let glyph else { return }
        context.translateBy(x: center.x, y: center.y)
        if glyph == .removeLabel { context.rotate(by: .pi / 4) }
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: -2.5, y: 0))
        context.addLine(to: CGPoint(x: 2.5, y: 0))
        context.move(to: CGPoint(x: 0, y: -2.5))
        context.addLine(to: CGPoint(x: 0, y: 2.5))
        context.strokePath()
    }

    private static func centeredRect(at center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func pointerLocation(
        ringPoint: CGPoint, tailTip: CGPoint?, direction: CGPoint, label: CGRect?, removeCenter: CGPoint?
    ) -> CGPoint {
        guard let label else { return ringPoint }
        var point = ringPoint
        if label.insetBy(dx: -9, dy: -9).contains(point), let tailTip { point = tailTip }
        let clearance = label.insetBy(dx: -8, dy: -8)
        let minimumSeparation = controlHitRadius * 2
        let nearRemove = removeCenter.map { hypot(point.x - $0.x, point.y - $0.y) < minimumSeparation } ?? false
        guard clearance.contains(point) || nearRemove else { return point }

        // A fixed left-side label can occupy the pointer's ring position. At
        // small zoom even the real tail tip may be too close: step sideways along
        // the tail's tangent, choosing the nearest clear side of the label.
        let tangent = CGPoint(x: -direction.y, y: direction.x)
        func candidate(sign: CGFloat) -> (point: CGPoint, distance: CGFloat) {
            let vector = CGPoint(x: tangent.x * sign, y: tangent.y * sign)
            var distance: CGFloat = 0
            if clearance.contains(point) {
                let dx = vector.x > 0 ? clearance.maxX - point.x : clearance.minX - point.x
                let dy = vector.y > 0 ? clearance.maxY - point.y : clearance.minY - point.y
                let horizontal = abs(vector.x) > 0.000_001 ? dx / vector.x : CGFloat.infinity
                let vertical = abs(vector.y) > 0.000_001 ? dy / vector.y : CGFloat.infinity
                distance = min(horizontal, vertical) + 0.5
            }
            if let removeCenter {
                let delta = CGPoint(x: point.x - removeCenter.x, y: point.y - removeCenter.y)
                let projected = delta.x * vector.x + delta.y * vector.y
                let candidateDelta = CGPoint(x: delta.x + vector.x * distance, y: delta.y + vector.y * distance)
                if hypot(candidateDelta.x, candidateDelta.y) < minimumSeparation {
                    let discriminant =
                        projected * projected - delta.x * delta.x - delta.y * delta.y
                        + minimumSeparation * minimumSeparation
                    distance = max(distance, -projected + sqrt(max(0, discriminant)) + 0.5)
                }
            }
            let shifted = CGPoint(x: point.x + vector.x * distance, y: point.y + vector.y * distance)
            if clearance.contains(shifted) {
                let dx = vector.x > 0 ? clearance.maxX - shifted.x : clearance.minX - shifted.x
                let dy = vector.y > 0 ? clearance.maxY - shifted.y : clearance.minY - shifted.y
                let horizontal = abs(vector.x) > 0.000_001 ? dx / vector.x : CGFloat.infinity
                let vertical = abs(vector.y) > 0.000_001 ? dy / vector.y : CGFloat.infinity
                distance += min(horizontal, vertical) + 0.5
            }
            return (CGPoint(x: point.x + vector.x * distance, y: point.y + vector.y * distance), distance)
        }
        let first = candidate(sign: 1)
        let second = candidate(sign: -1)
        return first.distance <= second.distance ? first.point : second.point
    }

    private static func excluding(_ excluded: CGRect, from rect: CGRect, keeping center: CGPoint) -> CGRect {
        let intersection = rect.intersection(excluded)
        guard !intersection.isNull, !intersection.isEmpty else { return rect }
        let pieces = [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: intersection.minY - rect.minY),
            CGRect(x: rect.minX, y: intersection.maxY, width: rect.width, height: rect.maxY - intersection.maxY),
            CGRect(
                x: rect.minX, y: intersection.minY, width: intersection.minX - rect.minX, height: intersection.height),
            CGRect(
                x: intersection.maxX, y: intersection.minY, width: rect.maxX - intersection.maxX,
                height: intersection.height),
        ]
        return pieces.filter { $0.contains(center) }.max { $0.width * $0.height < $1.width * $1.height } ?? rect
    }

    private static func unitVector(from origin: CGPoint, to point: CGPoint) -> CGPoint {
        let delta = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let length = hypot(delta.x, delta.y)
        guard length > 0.000_001 else { return CGPoint(x: -1, y: 0) }
        return CGPoint(x: delta.x / length, y: delta.y / length)
    }

    private static func outerEdge(of rect: CGRect, direction: CGPoint) -> CGPoint {
        let horizontal = abs(direction.x) > 0.000_001 ? rect.width / (2 * abs(direction.x)) : CGFloat.infinity
        let vertical = abs(direction.y) > 0.000_001 ? rect.height / (2 * abs(direction.y)) : CGFloat.infinity
        let distance = min(horizontal, vertical)
        return CGPoint(x: rect.midX + direction.x * distance, y: rect.midY + direction.y * distance)
    }
}
