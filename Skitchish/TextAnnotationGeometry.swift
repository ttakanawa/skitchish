import AppKit
import CoreText

/// Geometry and layout calculations shared by text interaction and native editing.
enum TextAnnotationGeometry {
    private static let maximumDimension: CGFloat = 65_536
    private static let maximumCanvasPixels: CGFloat = 150_000_000
    private static let coordinateLimit: CGFloat = 1_000_000
    private static let canvasExpansionPadding: CGFloat = 16

    static func stampEditingRect(_ mark: Markup) -> CGRect {
        var preview = mark
        // Keep short labels comfortable to edit, without enlarging the saved plate.
        // The circle-facing edge stays fixed as the editor grows to the left.
        if preview.text.isEmpty { preview.text = " " }
        let local = mark.localSize
        var rect = preview.stampLocalLabelBounds.offsetBy(dx: local.width / 2, dy: local.height / 2)
        let minimumWidth = preview.stampLocalCircleBounds.width * (190.0 / 60)
        if rect.width < minimumWidth {
            rect.origin.x -= minimumWidth - rect.width
            rect.size.width = minimumWidth
        }
        return rect
    }
    static func worldPoint(_ point: CGPoint, in mark: Markup) -> CGPoint {
        let local = mark.localSize
        var point = CGPoint(x: point.x - local.width / 2, y: point.y - local.height / 2)
        if mark.mirrored { point.x = -point.x }
        point = point.applying(CGAffineTransform(rotationAngle: CGFloat(mark.quarterTurns) * .pi / 2))
        return CGPoint(x: mark.bounds.midX + point.x, y: mark.bounds.midY + point.y)
    }
    static func resized(_ mark: Markup, to size: CGSize) -> Markup {
        var result = mark
        result.points = [worldPoint(.zero, in: mark), worldPoint(CGPoint(x: size.width, y: size.height), in: mark)]
        return result
    }
    static func scaled(_ mark: Markup, corner: Int, to point: CGPoint, canvas: CGRect) -> Markup {
        let bounds = mark.bounds
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
        guard corners.indices.contains(corner), bounds.width > 0, bounds.height > 0 else { return mark }
        let anchor = corners[(corner + 2) % 4]
        let diagonal = CGPoint(x: corners[corner].x - anchor.x, y: corners[corner].y - anchor.y)
        let squaredLength = diagonal.x * diagonal.x + diagonal.y * diagonal.y
        // Project onto the original diagonal so corners scale proportionally. Scaling
        // world points about a fixed corner also preserves rotated/mirrored text.
        let requested = ((point.x - anchor.x) * diagonal.x + (point.y - anchor.y) * diagonal.y) / squaredLength
        guard requested.isFinite else { return mark }
        let fontSize = max(1, mark.size * 4)
        let minimum = 1 / fontSize
        let maximum = max(minimum, min(4096 / fontSize, maximumDimension / max(bounds.width, bounds.height)))
        var scale = min(maximum, max(minimum, requested))
        func result(at scale: CGFloat) -> Markup {
            var resized = mark
            resized.points = mark.points.map {
                CGPoint(
                    x: anchor.x + ($0.x - anchor.x) * scale,
                    y: anchor.y + ($0.y - anchor.y) * scale)
            }
            resized.size = fontSize * scale / 4
            return resized
        }
        func fits(_ scale: CGFloat) -> Bool {
            fitsCanvas(result(at: scale), canvas: canvas)
        }
        if !fits(scale) {
            var lower = min(1, scale)
            var upper = scale
            guard fits(lower) else { return mark }
            for _ in 0..<24 {
                let middle = (lower + upper) / 2
                if fits(middle) { lower = middle } else { upper = middle }
            }
            scale = lower
        }
        return result(at: scale)
    }
    /// Uses the same font and paragraph policy as the export renderer. A nil height
    /// means that fitting this text would exceed the supported annotation dimension.
    static func measuredHeight(text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat? {
        guard width.isFinite, width > 0, width <= maximumDimension, fontSize.isFinite, fontSize > 0 else { return nil }
        return TextLayout(text: text, fontSize: fontSize).height(for: width)
    }

    static func reflowed(_ mark: Markup, draggingLeftEdge: Bool, to point: CGPoint, canvas: CGRect? = nil) -> Markup {
        let size = mark.localSize
        guard point.x.isFinite, point.y.isFinite, size.width > 0, size.height > 0 else { return mark }
        var local = CGPoint(x: point.x - mark.bounds.midX, y: point.y - mark.bounds.midY)
            .applying(CGAffineTransform(rotationAngle: -CGFloat(mark.quarterTurns) * .pi / 2))
        if mark.mirrored { local.x = -local.x }
        local.x += size.width / 2
        let requestedWidth = draggingLeftEdge ? size.width - local.x : local.x
        let fontSize = max(1, mark.size * 4)
        let width = min(maximumDimension, max(max(12, fontSize), requestedWidth))
        let layout = TextLayout(text: mark.text, fontSize: fontSize)
        func fitted(_ width: CGFloat) -> Markup? {
            guard let height = layout.height(for: width) else { return nil }
            let left = draggingLeftEdge ? size.width - width : 0
            var result = mark
            // Keep the opposite edge and local top fixed through rotation/mirroring.
            result.points = [
                worldPoint(CGPoint(x: left, y: 0), in: mark),
                worldPoint(CGPoint(x: left + width, y: height), in: mark),
            ]
            guard fitsCanvas(result, canvas: canvas ?? mark.bounds) else { return nil }
            return result
        }
        if let result = fitted(width) { return result }
        // Stop at the nearest safe width instead of truncating text height. Reuse
        // one framesetter throughout the search, even for a long pasted paragraph.
        guard var result = fitted(size.width) else { return mark }
        var safeWidth = size.width
        var unsafeWidth = width
        for _ in 0..<24 {
            let middle = (safeWidth + unsafeWidth) / 2
            if let candidate = fitted(middle) {
                safeWidth = middle
                result = candidate
            } else {
                unsafeWidth = middle
            }
        }
        return result
    }

    private static func fitsCanvas(_ mark: Markup, canvas: CGRect) -> Bool {
        let visual = mark.visualBounds
        let expanded =
            canvas.contains(visual)
            ? canvas : canvas.union(visual.insetBy(dx: -canvasExpansionPadding, dy: -canvasExpansionPadding)).integral
        return expanded.width <= maximumDimension && expanded.height <= maximumDimension
            && expanded.width * expanded.height <= maximumCanvasPixels
            && [expanded.minX, expanded.minY, expanded.maxX, expanded.maxY].allSatisfy {
                $0.isFinite && abs($0) < coordinateLimit
            }
    }

    private struct TextLayout {
        let framesetter: CTFramesetter
        let length: Int
        let lineHeight: CGFloat

        init(text: String, fontSize: CGFloat) {
            let font = EditorRenderer.annotationFont(size: fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            // Core Text can omit a final empty baseline from its suggested size.
            // A measurement-only glyph reserves that line without changing storage.
            let hasTrailingBreak = text.unicodeScalars.last.map { CharacterSet.newlines.contains($0) } ?? false
            let measuredText = text.isEmpty ? "M" : hasTrailingBreak ? text + "M" : text
            let string = NSAttributedString(
                string: measuredText, attributes: [.font: font, .paragraphStyle: paragraph])
            framesetter = CTFramesetterCreateWithAttributedString(string)
            length = string.length
            lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        }

        func height(for width: CGFloat) -> CGFloat? {
            guard width.isFinite, width > 0, width <= maximumDimension else { return nil }
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            var height = max(20, ceil(measured.height) + 8)
            guard height.isFinite, height <= maximumDimension else { return nil }
            // A suggested size is not a guarantee that the actual frame contains
            // the final Japanese/fallback-font line. Check the renderer's layout.
            for _ in 0..<8 {
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.location + visible.length >= length { return height }
                height += lineHeight
                if height > maximumDimension { return nil }
            }
            return nil
        }
    }
}
