import AppKit

/// Derived annotation geometry shared by drawing, selection, and canvas transforms.
extension Markup {
    /// Marker inks are independent from the annotation palette, measured from an
    /// sRGB image exported by Skitch 2.9.
    static let stampColors: [RGBA] = [
        .init(r: 0, g: 196.0 / 255, b: 61.0 / 255),
        .init(r: 243.0 / 255, g: 55.0 / 255, b: 39.0 / 255),
        .init(r: 34.0 / 255, g: 153.0 / 255, b: 220.0 / 255),
        .init(r: 1, g: 149.0 / 255, b: 22.0 / 255),
        .init(r: 1, g: 60.0 / 255, b: 119.0 / 255),
    ]
    var stampColor: RGBA { Self.stampColors[max(0, min(4, stamp))] }
    var strokeExtent: CGFloat { tool == .highlight ? max(10, size * 4) : size }
    /// The annotation's dimensions before its persisted rotation is applied.
    var localSize: CGSize {
        let rect = bounds
        return quarterTurns % 2 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
    }
    var stampTransform: CGAffineTransform {
        CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .rotated(by: CGFloat(quarterTurns) * .pi / 2)
            .scaledBy(x: mirrored ? -1 : 1, y: 1)
    }
    var stampLocalCircleBounds: CGRect {
        let local = localSize
        let diameter = min(local.width, local.height)
        return CGRect(x: -local.width / 2, y: -local.height / 2, width: diameter, height: diameter)
    }
    var stampLocalLabelBounds: CGRect {
        let circle = stampLocalCircleBounds
        guard !text.isEmpty else { return .null }
        let style = StampLabelStyle(diameter: circle.width)
        let measured = style.textSize(for: text)
        let width = measured.width + style.paddingX * 2
        let height = measured.height + style.paddingY * 2
        let attachmentMinX = min(circle.minX, stampLocalTailPath?.boundingBoxOfPath.minX ?? circle.minX)
        return CGRect(
            x: attachmentMinX - max(3, circle.width * 0.1) - width,
            y: circle.midY - height / 2, width: width, height: height)
    }
    var stampLocalLabelTextBounds: CGRect {
        let outer = stampLocalLabelBounds
        guard !outer.isNull else { return .null }
        let style = StampLabelStyle(diameter: stampLocalCircleBounds.width)
        return outer.insetBy(dx: style.paddingX, dy: style.paddingY)
    }
    var stampLocalTailTip: CGPoint? {
        guard tail else { return nil }
        let circle = stampLocalCircleBounds
        let angle = CGFloat(tailDirection ?? 1) * .pi / 4
        return CGPoint(
            x: circle.midX + cos(angle) * circle.width * 0.85,
            y: circle.midY + sin(angle) * circle.width * 0.85)
    }
    var stampLocalTailPath: CGPath? {
        guard let tip = stampLocalTailTip else { return nil }
        let circle = stampLocalCircleBounds
        let angle = CGFloat(tailDirection ?? 1) * .pi / 4
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: -direction.y, y: direction.x)
        func point(_ radial: CGFloat, _ lateral: CGFloat) -> CGPoint {
            CGPoint(
                x: circle.midX + circle.width * (direction.x * radial + normal.x * lateral),
                y: circle.midY + circle.width * (direction.y * radial + normal.y * lateral))
        }
        let path = CGMutablePath()
        path.move(to: point(0.1, 0.28))
        path.addLine(to: point(0.62, 0.28))
        path.addLine(to: tip)
        path.addLine(to: point(0.62, -0.28))
        path.addLine(to: point(0.1, -0.28))
        path.closeSubpath()
        return path
    }
    /// One perimeter for the circle and pointer keeps the white frame and shadow
    /// continuous, with no white seam where the pointer attaches to the circle.
    var stampLocalSilhouette: CGPath {
        let circle = stampLocalCircleBounds
        guard tail else { return CGPath(ellipseIn: circle, transform: nil) }
        let diameter = circle.width
        let halfTab: CGFloat = 0.28
        let angle = asin(halfTab * 2)
        let join = sqrt(0.25 - halfTab * halfTab)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: join * diameter, y: halfTab * diameter))
        path.addArc(center: .zero, radius: diameter / 2, startAngle: angle, endAngle: 2 * .pi - angle, clockwise: false)
        path.addLine(to: CGPoint(x: diameter * 0.62, y: -diameter * halfTab))
        path.addLine(to: CGPoint(x: diameter * 0.85, y: 0))
        path.addLine(to: CGPoint(x: diameter * 0.62, y: diameter * halfTab))
        path.closeSubpath()
        var transform = CGAffineTransform(translationX: circle.midX, y: circle.midY)
            .rotated(by: CGFloat(tailDirection ?? 1) * .pi / 4)
        return path.copy(using: &transform)!
    }
    var stampCircleBounds: CGRect { stampLocalCircleBounds.applying(stampTransform) }
    var stampLabelBounds: CGRect {
        stampLocalLabelBounds.isNull ? .null : stampLocalLabelBounds.applying(stampTransform)
    }
    var stampTailTip: CGPoint? { stampLocalTailTip?.applying(stampTransform) }
    var arrowHeadLength: CGFloat {
        guard let first = points.first, let last = points.last else { return 0 }
        let length = hypot(last.x - first.x, last.y - first.y)
        guard length > 0, size > 0 else { return 0 }
        // Grow smoothly with both length and weight, without allowing a short arrow's
        // head to consume its shaft. Uniform image resizing scales this geometry exactly.
        let maximum = size * 8.5
        return maximum * tanh(length * 0.48 / maximum)
    }
    var arrowPath: CGPath? {
        guard let first = points.first, let last = points.last else { return nil }
        let length = hypot(last.x - first.x, last.y - first.y)
        guard length > 0 else { return nil }
        let head = arrowHeadLength
        let wing = head * 0.52
        let shaft = head * 0.235
        let neck = length - head * 0.90
        let root = min(size * 0.30, head * 0.04)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: root, y: -root))
        path.addCurve(
            to: CGPoint(x: neck, y: -shaft),
            control1: CGPoint(x: length * 0.35, y: -head * 0.10),
            control2: CGPoint(x: neck * 0.65, y: -head * 0.067))
        path.addLine(to: CGPoint(x: length - head, y: -wing))
        path.addLine(to: CGPoint(x: length, y: 0))
        path.addLine(to: CGPoint(x: length - head, y: wing))
        path.addLine(to: CGPoint(x: neck, y: shaft))
        path.addCurve(
            to: CGPoint(x: root, y: root),
            control1: CGPoint(x: neck * 0.65, y: head * 0.067),
            control2: CGPoint(x: length * 0.35, y: head * 0.10))
        path.addCurve(
            to: CGPoint(x: root, y: -root),
            control1: CGPoint(x: -root / 3, y: root), control2: CGPoint(x: -root / 3, y: -root))
        path.closeSubpath()
        var transform = CGAffineTransform(translationX: first.x, y: first.y)
            .rotated(by: atan2(last.y - first.y, last.x - first.x))
        return path.copy(using: &transform)
    }

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { box, p in
            CGRect(
                x: min(box.minX, p.x), y: min(box.minY, p.y),
                width: max(box.maxX, p.x) - min(box.minX, p.x),
                height: max(box.maxY, p.y) - min(box.minY, p.y))
        }
    }
    var visualBounds: CGRect {
        if tool == .arrow, let path = arrowPath {
            let shadowExtent = max(0.25, arrowHeadLength / 46) * 8 + 1
            return path.boundingBoxOfPath.insetBy(dx: -shadowExtent, dy: -shadowExtent)
        }
        if tool == .stamp {
            var rect = stampCircleBounds.union(stampLabelBounds)
            if let path = stampLocalTailPath { rect = rect.union(path.boundingBoxOfPath.applying(stampTransform)) }
            let padding = max(size / 2 + 2, stampLocalCircleBounds.width * 0.16 + 2)
            return rect.insetBy(dx: -padding, dy: -padding)
        }
        let rect = bounds
        return rect.insetBy(
            dx: -(tool == .arrow ? size * 3 : strokeExtent / 2 + 2),
            dy: -(tool == .arrow ? size * 3 : strokeExtent / 2 + 2))
    }
    func translated(dx: CGFloat, dy: CGFloat) -> Markup {
        var result = self
        result.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return result
    }
    func resized(from source: CGRect, to target: CGRect) -> Markup {
        var result = self
        result.points = points.map { p in
            CGPoint(
                x: target.minX + (source.width == 0 ? 0 : (p.x - source.minX) / source.width * target.width),
                y: target.minY + (source.height == 0 ? 0 : (p.y - source.minY) / source.height * target.height))
        }
        return result
    }
    func hitTest(_ point: CGPoint, tolerance: CGFloat = 5) -> Bool {
        if tool == .stamp {
            let local = point.applying(stampTransform.inverted())
            if !stampLocalLabelBounds.isNull
                && stampLocalLabelBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
            {
                return true
            }
            let circle = stampLocalCircleBounds
            if hypot(local.x - circle.midX, local.y - circle.midY) <= circle.width / 2 + tolerance { return true }
            if let path = stampLocalTailPath {
                if path.contains(local) { return true }
                return tolerance > 0
                    && path.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
                        .contains(local)
            }
            return false
        }
        if tool == .arrow, let path = arrowPath {
            if path.contains(point) { return true }
            return tolerance > 0
                && path.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
                    .contains(point)
        }
        let radius = max(tolerance, strokeExtent / 2)
        guard
            bounds.insetBy(dx: -radius * (tool == .arrow ? 3 : 1), dy: -radius * (tool == .arrow ? 3 : 1)).contains(
                point)
        else { return false }
        if [.text, .pixelate].contains(tool) { return true }
        if [.line, .arrow, .pen, .highlight].contains(tool) {
            if points.count == 1, let first = points.first {
                return hypot(point.x - first.x, point.y - first.y) <= radius
            }
            return zip(points, points.dropFirst()).contains { p, q in
                let vx = q.x - p.x
                let vy = q.y - p.y
                let length = vx * vx + vy * vy
                let t = length == 0 ? 0 : max(0, min(1, ((point.x - p.x) * vx + (point.y - p.y) * vy) / length))
                return hypot(point.x - p.x - t * vx, point.y - p.y - t * vy) <= radius * (tool == .arrow ? 2.5 : 1)
            }
        }
        if tool == .ellipse {
            let rx = max(bounds.width / 2, 0.01)
            let ry = max(bounds.height / 2, 0.01)
            let v = hypot((point.x - bounds.midX) / rx, (point.y - bounds.midY) / ry)
            return abs(v - 1) <= radius / min(rx, ry)
        }
        return !bounds.insetBy(dx: radius, dy: radius).contains(point)
    }
}
