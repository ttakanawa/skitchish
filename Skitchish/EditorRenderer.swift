import AppKit
import CoreText
import ImageIO

/// Shared screen/export renderer. Its input context uses upper-left pixel coordinates.
final class EditorRenderer {
    private var cachedData: Data?
    private var cachedImage: CGImage?
    private struct PixelationSignature: Equatable {
        var marks: [Markup]
        var transform: PixelTransform
        var canvas: CGRect
    }
    private struct PixelationSnapshot {
        var image: CGImage
        var isOpaque: Bool
    }
    private var pixelCache: [UUID: (signature: PixelationSignature, snapshot: PixelationSnapshot)] = [:]
    /// Internal diagnostic used to verify that repeated frames reuse mosaic snapshots.
    private(set) var pixelationRenderCount = 0
    private(set) var transparencyMaskClipCount = 0

    static func annotationFont(size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }
    static func stampLabelFont(size: CGFloat) -> NSFont {
        NSFont(name: "HelveticaNeue-Medium", size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium)
    }
    /// A centered four-pixel stroke leaves a two-pixel outer white border at24px.
    static let textOutlinePercent: CGFloat = 100 / 6
    static func annotationTextShadow(fontSize: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        let scale = fontSize / 24
        shadow.shadowOffset = CGSize(width: 0, height: -scale)
        shadow.shadowBlurRadius = 1.5 * scale
        shadow.shadowColor = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 0.45)
        return shadow
    }

    func render(document: EditorDocument) throws -> CGImage {
        try document.validate()
        guard sourceImage(document) != nil else { throw EditorRenderError.invalidImage }
        let canvas = document.canvas.integral
        guard let context = Self.bitmap(width: Int(canvas.width), height: Int(canvas.height)) else {
            throw EditorRenderError.allocationFailed
        }
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        draw(document: document, in: context)
        guard let image = context.makeImage() else { throw EditorRenderError.allocationFailed }
        return image
    }

    func draw(document: EditorDocument, in context: CGContext) {
        // Source changes invalidate every mosaic before opacity/cache decisions are made.
        _ = sourceImage(document)
        let masks: [(index: Int, rect: CGRect)] = document.annotations.enumerated().compactMap { index, markup in
            guard markup.tool == .pixelate,
                let snapshot = pixelationSnapshot(markup, preceding: index, document: document),
                !snapshot.isOpaque
            else { return nil }
            return (index, markup.bounds.intersection(document.canvas).integral)
        }
        context.saveGState()
        context.clip(to: document.canvas)
        context.saveGState()
        excludePixelations(masks.map(\.rect), canvas: document.canvas, in: context)
        drawSource(document, in: context)
        context.restoreGState()
        for (index, annotation) in document.annotations.enumerated() {
            context.saveGState()
            let affected = annotation.visualBounds.insetBy(dx: -annotation.size, dy: -annotation.size)
            excludePixelations(
                masks.filter { $0.index > index && $0.rect.intersects(affected) }.map(\.rect),
                canvas: document.canvas, in: context)
            if annotation.tool == .pixelate {
                drawPixelation(annotation, preceding: index, document: document, in: context, replacesExisting: false)
            } else {
                draw(markup: annotation, in: context)
            }
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// Mask covered content before painting, so transparent mosaic pixels neither leak the
    /// original detail nor punch holes through the canvas checkerboard on screen.
    private func excludePixelations(_ rectangles: [CGRect], canvas: CGRect, in context: CGContext) {
        for rect in rectangles {
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            let path = CGMutablePath()
            path.addRect(canvas)
            path.addRect(rect)
            context.addPath(path)
            context.clip(using: .evenOdd)
            transparencyMaskClipCount += 1
        }
    }

    private func draw(markup: Markup, in context: CGContext) {
        guard let first = markup.points.first else { return }
        let rect = markup.bounds
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(markup.color.cgColor)
        context.setFillColor(markup.color.cgColor)
        context.setLineWidth(markup.size)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch markup.tool {
        case .arrow:
            guard let path = markup.arrowPath else { return }
            let scale = max(0.25, markup.arrowHeadLength / 46)
            context.setShadow(
                offset: CGSize(width: 0, height: -2 * scale), blur: 2 * scale,
                color: NSColor(white: 0, alpha: 0.3).cgColor)
            context.addPath(path)
            context.fillPath()
        case .rectangle:
            context.stroke(rect)
        case .roundedRectangle:
            let radius = min(min(rect.width, rect.height) / 4, markup.size * 2.5)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case .ellipse:
            context.strokeEllipse(in: rect)
        case .line, .pen, .highlight:
            drawStroke(markup, from: first, in: context)
        case .text, .stamp:
            drawOrientedText(markup, in: context)
        case .select, .crop, .pixelate: break
        }
    }

    private func drawStroke(_ markup: Markup, from first: CGPoint, in context: CGContext) {
        let isPoint = markup.points.allSatisfy { $0 == first }
        if markup.tool == .highlight {
            context.setAlpha(0.33)
            context.setBlendMode(.multiply)
            context.setLineWidth(markup.strokeExtent)
            context.setLineCap(.butt)
            if isPoint {
                context.fill(
                    CGRect(
                        x: first.x - markup.strokeExtent / 2, y: first.y - markup.strokeExtent / 2,
                        width: markup.strokeExtent, height: markup.strokeExtent))
                return
            }
        } else if isPoint {
            context.fillEllipse(
                in: CGRect(
                    x: first.x - markup.size / 2, y: first.y - markup.size / 2,
                    width: markup.size, height: markup.size))
            return
        }
        context.beginPath()
        context.move(to: first)
        for point in markup.points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }

    private func drawOrientedText(_ markup: Markup, in context: CGContext) {
        // The box follows world coordinates; orientation follows non-destructive image transforms.
        let rect = markup.bounds
        let size = markup.localSize
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: CGFloat(markup.quarterTurns) * .pi / 2)
        if markup.mirrored { context.scaleBy(x: -1, y: 1) }
        let local = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        if markup.tool == .stamp {
            drawStamp(markup, in: context)
        } else {
            drawText(markup.text, rect: local, fontSize: max(1, markup.size * 4), color: markup.color, in: context)
        }
    }

    private func sourceImage(_ document: EditorDocument) -> CGImage? {
        guard document.imageSize.width.isFinite, document.imageSize.height.isFinite,
            document.imageSize.width > 0, document.imageSize.height > 0,
            document.imageSize.width < 1_000_000, document.imageSize.height < 1_000_000
        else { return nil }
        if cachedData != document.imageData {
            cachedData = document.imageData
            cachedImage = nil
            pixelCache.removeAll()
            guard document.imageData.count <= 256_000_000,
                let source = CGImageSourceCreateWithData(document.imageData as CFData, nil),
                let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = info[kCGImagePropertyPixelHeight] as? NSNumber,
                width.doubleValue > 0, height.doubleValue > 0,
                width.doubleValue * height.doubleValue <= 150_000_000,
                width.doubleValue == Double(document.imageSize.width),
                height.doubleValue == Double(document.imageSize.height)
            else { return nil }
            cachedImage = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard cachedImage?.width == Int(document.imageSize.width), cachedImage?.height == Int(document.imageSize.height)
        else { return nil }
        return cachedImage
    }

    private func drawSource(_ document: EditorDocument, in context: CGContext) {
        guard let image = sourceImage(document) else { return }
        context.saveGState()
        context.concatenate(document.imageTransform.cgAffineTransform)
        Self.drawImage(image, rect: CGRect(origin: .zero, size: document.imageSize), in: context)
        context.restoreGState()
    }

    private func drawPixelation(
        _ markup: Markup, preceding count: Int, document: EditorDocument, in context: CGContext,
        replacesExisting: Bool = true
    ) {
        guard let snapshot = pixelationSnapshot(markup, preceding: count, document: document) else { return }
        let rect = markup.bounds.intersection(document.canvas).integral
        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .none
        context.setBlendMode(replacesExisting ? .copy : .normal)
        Self.drawImage(snapshot.image, rect: rect, in: context)
        context.restoreGState()
    }

    private func pixelationSnapshot(_ markup: Markup, preceding count: Int, document: EditorDocument)
        -> PixelationSnapshot?
    {
        let rect = markup.bounds.intersection(document.canvas).integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        // JSON object key order is unspecified, so encoded bytes are not a stable cache key.
        let signature = PixelationSignature(
            marks: Array(document.annotations.prefix(count + 1)),
            transform: document.imageTransform, canvas: document.canvas)
        if let cached = pixelCache[markup.id], cached.signature == signature {
            return cached.snapshot
        }
        let blockSize = max(6, markup.size * 2)
        let width = max(1, Int(ceil(rect.width / blockSize)))
        let height = max(1, Int(ceil(rect.height / blockSize)))
        guard let reduced = Self.bitmap(width: width, height: height) else { return nil }
        reduced.translateBy(x: 0, y: CGFloat(height))
        reduced.scaleBy(x: CGFloat(width) / rect.width, y: -CGFloat(height) / rect.height)
        reduced.translateBy(x: -rect.minX, y: -rect.minY)
        reduced.clip(to: rect)
        drawSource(document, in: reduced)
        for (index, previous) in document.annotations.prefix(count).enumerated() {
            if previous.tool == .pixelate {
                drawPixelation(previous, preceding: index, document: document, in: reduced)
            } else {
                draw(markup: previous, in: reduced)
            }
        }
        guard let rendered = reduced.makeImage() else { return nil }
        let snapshot = PixelationSnapshot(image: rendered, isOpaque: Self.isOpaqueRGBA(rendered))
        pixelationRenderCount += 1
        if pixelCache.count > 128 { pixelCache.removeAll() }
        pixelCache[markup.id] = (signature, snapshot)
        return snapshot
    }

    /// Only proven opaque RGBA snapshots bypass masking. Source opacity alone is insufficient
    /// after cropping, canvas expansion, transforms, or earlier transparent mosaics.
    private static func isOpaqueRGBA(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
            image.alphaInfo == .premultipliedLast,
            !image.bitmapInfo.contains(.byteOrder32Little),
            let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
            CFDataGetLength(data) >= image.bytesPerRow * image.height
        else { return false }
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4 + 3] != 255 { return false }
        }
        return true
    }

    private func drawText(
        _ text: String, rect: CGRect, fontSize: CGFloat, color: RGBA, in context: CGContext, outlined: Bool = true,
        isStampLabel: Bool = false
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let font = isStampLabel ? Self.stampLabelFont(size: fontSize) : Self.annotationFont(size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        if isStampLabel { paragraph.alignment = .right }
        let base: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph,
            .foregroundColor: color.nsColor,
        ]
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        func pass(_ attributes: [NSAttributedString.Key: Any]) {
            let string = NSAttributedString(string: text, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTFrameDraw(frame, context)
        }
        if outlined {
            var outline = base
            // Draw a complete white silhouette and its shadow, then restore the colored
            // glyph face. Keeping the halo white matches Skitch even for yellow text.
            outline[.foregroundColor] = NSColor.white
            outline[.strokeColor] = NSColor.white
            outline[.strokeWidth] = -Self.textOutlinePercent
            let shadow = Self.annotationTextShadow(fontSize: fontSize)
            context.setShadow(
                offset: shadow.shadowOffset, blur: shadow.shadowBlurRadius,
                color: shadow.shadowColor?.cgColor)
            pass(outline)
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        pass(base)
        context.restoreGState()
    }

    private func drawStamp(_ markup: Markup, in context: CGContext) {
        let circle = markup.stampLocalCircleBounds
        let diameter = circle.width
        guard diameter > 0 else { return }
        context.saveGState()
        let scale = diameter / 60
        context.setShadow(
            offset: CGSize(width: 0, height: -2 * scale), blur: 2 * scale,
            color: NSColor(white: 0, alpha: 0.3).cgColor)
        let layerBounds = markup.stampLocalSilhouette.boundingBoxOfPath
            .insetBy(dx: -diameter * 0.16 - 2, dy: -diameter * 0.16 - 2)
        context.beginTransparencyLayer(in: layerBounds, auxiliaryInfo: nil)
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(diameter * 0.055)
        context.addPath(markup.stampLocalSilhouette)
        context.drawPath(using: .fillStroke)
        context.setFillColor(markup.stampColor.cgColor)
        context.addPath(markup.stampLocalSilhouette)
        context.fillPath()
        context.endTransparencyLayer()
        context.restoreGState()
        context.setFillColor(NSColor.white.cgColor)
        let center = circle.insetBy(dx: diameter * 0.15, dy: diameter * 0.15)
        context.fillEllipse(in: center)
        // The raised colored rim casts a small shadow onto the white center too.
        context.saveGState()
        context.addEllipse(in: center.insetBy(dx: diameter * 0.02, dy: diameter * 0.02))
        context.clip()
        context.setShadow(
            offset: CGSize(width: 0, height: -3 * scale), blur: 2 * scale,
            color: NSColor(white: 0, alpha: 0.35).cgColor)
        context.setFillColor(markup.stampColor.cgColor)
        context.addPath(markup.stampLocalSilhouette)
        context.addEllipse(in: center)
        context.drawPath(using: .eoFill)
        context.restoreGState()
        context.saveGState()
        context.translateBy(x: circle.midX, y: circle.midY)
        context.scaleBy(x: diameter, y: diameter)
        context.setStrokeColor(markup.stampColor.cgColor)
        context.setFillColor(markup.stampColor.cgColor)
        Self.drawStampSymbol(stamp: markup.stamp, in: context)
        context.restoreGState()
        if !markup.text.isEmpty {
            let style = StampLabelStyle(diameter: diameter)
            style.drawBackground(in: context, rect: markup.stampLocalLabelBounds)
            drawText(
                markup.text, rect: markup.stampLocalLabelTextBounds, fontSize: style.fontSize,
                color: .palette[6], in: context, outlined: false, isStampLabel: true)
        }
    }

    /// Draws in a unit-diameter, centered, downward-y coordinate space. The caller
    /// chooses the ink color; both the toolbar and canvas share these vector shapes.
    static func drawStampSymbol(stamp: Int, in context: CGContext) {
        context.setLineWidth(0.09)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let symbol = CGMutablePath()
        switch stamp {
        case 0:
            symbol.move(to: CGPoint(x: -0.17, y: 0.02))
            symbol.addLine(to: CGPoint(x: -0.06, y: 0.135))
            symbol.addLine(to: CGPoint(x: 0.16, y: -0.095))
            context.addPath(symbol)
            context.strokePath()
        case 1:
            symbol.move(to: CGPoint(x: -0.135, y: -0.135))
            symbol.addLine(to: CGPoint(x: 0.135, y: 0.135))
            symbol.move(to: CGPoint(x: 0.135, y: -0.135))
            symbol.addLine(to: CGPoint(x: -0.135, y: 0.135))
            context.addPath(symbol)
            context.strokePath()
        case 2:
            context.saveGState()
            context.scaleBy(x: 0.8, y: 0.8)
            symbol.move(to: CGPoint(x: -0.14, y: -0.12))
            symbol.addCurve(
                to: CGPoint(x: 0.15, y: -0.13),
                control1: CGPoint(x: -0.15, y: -0.31), control2: CGPoint(x: 0.15, y: -0.31))
            symbol.addCurve(
                to: CGPoint(x: 0, y: 0.075),
                control1: CGPoint(x: 0.15, y: -0.015), control2: CGPoint(x: 0, y: -0.04))
            context.addPath(symbol)
            context.strokePath()
            context.fillEllipse(in: CGRect(x: -0.05, y: 0.18, width: 0.1, height: 0.1))
            context.restoreGState()
        case 3:
            symbol.move(to: CGPoint(x: 0, y: 0.07))
            symbol.addCurve(
                to: CGPoint(x: -0.05, y: -0.17),
                control1: CGPoint(x: -0.025, y: 0.07), control2: CGPoint(x: -0.05, y: -0.14))
            symbol.addCurve(
                to: CGPoint(x: 0.05, y: -0.17),
                control1: CGPoint(x: -0.05, y: -0.24), control2: CGPoint(x: 0.05, y: -0.24))
            symbol.addCurve(
                to: CGPoint(x: 0, y: 0.07),
                control1: CGPoint(x: 0.05, y: -0.14), control2: CGPoint(x: 0.025, y: 0.07))
            context.addPath(symbol)
            context.fillPath()
            context.fillEllipse(in: CGRect(x: -0.04, y: 0.12, width: 0.08, height: 0.08))
        default:
            symbol.move(to: CGPoint(x: 0.06, y: 0.20))
            symbol.addCurve(
                to: CGPoint(x: -0.21, y: -0.06),
                control1: CGPoint(x: -0.045, y: 0.15), control2: CGPoint(x: -0.21, y: 0.1))
            symbol.addCurve(
                to: CGPoint(x: -0.05, y: -0.095),
                control1: CGPoint(x: -0.21, y: -0.18), control2: CGPoint(x: -0.11, y: -0.20))
            symbol.addCurve(
                to: CGPoint(x: 0.20, y: -0.06),
                control1: CGPoint(x: 0.025, y: -0.26), control2: CGPoint(x: 0.22, y: -0.20))
            symbol.addCurve(
                to: CGPoint(x: 0.06, y: 0.20),
                control1: CGPoint(x: 0.175, y: 0.025), control2: CGPoint(x: 0.075, y: 0.06))
            context.addPath(symbol)
            context.fillPath()
        }
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    private static func drawImage(_ image: CGImage, rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
