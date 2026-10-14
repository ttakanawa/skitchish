import CoreGraphics

/// All interaction and display conversions pass through this pixel-to-view mapping.
struct CanvasTransform {
    var canvas: CGRect
    var zoom: CGFloat
    var origin: CGPoint

    func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - origin.x) / zoom + canvas.minX,
            y: (point.y - origin.y) / zoom + canvas.minY)
    }

    func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - canvas.minX) * zoom + origin.x,
            y: (point.y - canvas.minY) * zoom + origin.y)
    }

    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(origin: viewPoint(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }
}
