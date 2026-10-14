import AppKit

/// Screen-space decoration shared by selected text and its native text editor.
/// The padding and handles never alter the annotation's image-space rectangle.
@MainActor
struct TextSelectionChrome {
    static let color = NSColor(srgbRed: 0.08, green: 0.73, blue: 0.9, alpha: 1)
    private static let lineWidth: CGFloat = 1.5
    private static let sideRadius: CGFloat = 7
    private static let hitPadding: CGFloat = 4
    private static let cornerRadius: CGFloat = 5

    let frame: CGRect
    /// Local left and right edges, in that order, even after rotation or mirroring.
    let sideCenters: [CGPoint]
    let sideDirections: [CGPoint]
    private let inwardHitAllowance: CGFloat

    init(mark: Markup, mapping: CanvasTransform) {
        let padding: CGFloat = 6
        inwardHitAllowance = 8
        frame = mapping.viewRect(mark.bounds).insetBy(dx: -padding, dy: -padding)
        let size = mark.localSize
        let center = mapping.viewPoint(CGPoint(x: mark.bounds.midX, y: mark.bounds.midY))
        let localEdges = [CGPoint(x: 0, y: size.height / 2), CGPoint(x: size.width, y: size.height / 2)]
        var centers: [CGPoint] = []
        var directions: [CGPoint] = []
        for (index, localEdge) in localEdges.enumerated() {
            let edge = mapping.viewPoint(TextAnnotationGeometry.worldPoint(localEdge, in: mark))
            var vector = CGPoint(x: edge.x - center.x, y: edge.y - center.y)
            var length = hypot(vector.x, vector.y)
            if length < 0.000_001 {
                // Retain a usable direction for an empty or zero-width text box.
                let sign: CGFloat = index == 0 ? -1 : 1
                vector = CGPoint(x: mark.mirrored ? -sign : sign, y: 0)
                    .applying(CGAffineTransform(rotationAngle: CGFloat(mark.quarterTurns) * .pi / 2))
                length = 1
            }
            let direction = CGPoint(x: vector.x / length, y: vector.y / length)
            directions.append(direction)
            centers.append(CGPoint(x: edge.x + direction.x * padding, y: edge.y + direction.y * padding))
        }
        sideCenters = centers
        sideDirections = directions
    }

    init(editorFrame: CGRect) {
        // Keep every point inside NSTextView available for native caret placement.
        inwardHitAllowance = 4
        frame = editorFrame.insetBy(dx: -4, dy: -4)
        sideCenters = [CGPoint(x: frame.minX, y: frame.midY), CGPoint(x: frame.maxX, y: frame.midY)]
        sideDirections = [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0)]
    }

    var cornerCenters: [CGPoint] {
        [
            CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY),
        ]
    }

    /// Includes the visible semicircle and the inner side of the border. Use these
    /// same rectangles for cursor registration and hit testing.
    var widthHitRects: [CGRect] {
        sideCenters.indices.map { index in
            let center = sideCenters[index]
            let direction = sideDirections[index]
            let extent = Self.sideRadius + Self.hitPadding
            let tangent = CGPoint(x: -direction.y * extent, y: direction.x * extent)
            let inside = CGPoint(
                x: center.x - direction.x * inwardHitAllowance,
                y: center.y - direction.y * inwardHitAllowance)
            let outside = CGPoint(x: center.x + direction.x * extent, y: center.y + direction.y * extent)
            let points = [
                CGPoint(x: inside.x + tangent.x, y: inside.y + tangent.y),
                CGPoint(x: inside.x - tangent.x, y: inside.y - tangent.y),
                CGPoint(x: outside.x + tangent.x, y: outside.y + tangent.y),
                CGPoint(x: outside.x - tangent.x, y: outside.y - tangent.y),
            ]
            let minX = points.map(\.x).min()!
            let maxX = points.map(\.x).max()!
            let minY = points.map(\.y).min()!
            let maxY = points.map(\.y).max()!
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    func widthHandle(at point: CGPoint) -> Int? {
        let rects = widthHitRects
        return rects.indices
            .filter { rects[$0].contains(point) }
            .min { lhs, rhs in
                hypot(point.x - sideCenters[lhs].x, point.y - sideCenters[lhs].y)
                    < hypot(point.x - sideCenters[rhs].x, point.y - sideCenters[rhs].y)
            }
            .map { $0 + 4 }
    }

    func resizeRegions(editing: Bool) -> [(index: Int, rect: CGRect, center: CGPoint)] {
        let sides = zip(widthHitRects, sideCenters).enumerated().map {
            (index: $0.offset + 4, rect: $0.element.0, center: $0.element.1)
        }
        guard !editing else { return sides }
        let corners = cornerCenters.enumerated().map {
            (
                index: $0.offset, rect: CGRect(x: $0.element.x - 10, y: $0.element.y - 10, width: 20, height: 20),
                center: $0.element
            )
        }
        // At very small zoom levels the nominal hit areas overlap. Divide the
        // short edge at the midpoints between its corner and width grips so the
        // visible corners still scale the font, with matching cursor regions.
        let vertical = abs(sideDirections[0].x) > 0.5
        let minimum = vertical ? frame.minY : frame.minX
        let length = vertical ? frame.height : frame.width
        let lower = minimum + length / 4
        let upper = minimum + length * 3 / 4
        return (sides + corners).compactMap { region in
            let center = vertical ? region.center.y : region.center.x
            var low = vertical ? region.rect.minY : region.rect.minX
            var high = vertical ? region.rect.maxY : region.rect.maxX
            if region.index >= 4 {
                low = max(low, lower)
                high = min(high, upper)
            } else if center < minimum + length / 2 {
                high = min(high, lower)
            } else {
                low = max(low, upper)
            }
            guard high > low else { return nil }
            let rect =
                vertical
                ? CGRect(x: region.rect.minX, y: low, width: region.rect.width, height: high - low)
                : CGRect(x: low, y: region.rect.minY, width: high - low, height: region.rect.height)
            return (region.index, rect, region.center)
        }
    }

    func draw(in context: CGContext, editing: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(Self.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(Self.color.cgColor)
        if editing {
            for index in sideCenters.indices {
                let center = sideCenters[index]
                if abs(sideDirections[index].x) > abs(sideDirections[index].y) {
                    context.move(to: CGPoint(x: center.x, y: frame.minY))
                    context.addLine(to: CGPoint(x: center.x, y: frame.maxY))
                } else {
                    context.move(to: CGPoint(x: frame.minX, y: center.y))
                    context.addLine(to: CGPoint(x: frame.maxX, y: center.y))
                }
            }
            context.strokePath()
        } else {
            context.stroke(frame)
        }
        for index in sideCenters.indices {
            context.addPath(sidePath(at: index))
            context.strokePath()
        }
        if !editing {
            context.setFillColor(Self.color.cgColor)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.25)
            for center in cornerCenters {
                let rect = CGRect(
                    x: center.x - Self.cornerRadius, y: center.y - Self.cornerRadius,
                    width: Self.cornerRadius * 2, height: Self.cornerRadius * 2)
                context.addEllipse(in: rect)
                context.drawPath(using: .fillStroke)
            }
        }
    }

    private func sidePath(at index: Int) -> CGPath {
        let outward = sideDirections[index]
        let angle = atan2(outward.y, outward.x)
        let path = CGMutablePath()
        path.addArc(
            center: sideCenters[index], radius: Self.sideRadius,
            startAngle: angle - .pi / 2, endAngle: angle + .pi / 2, clockwise: false)
        return path
    }
}
