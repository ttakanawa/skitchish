import AppKit
import CoreText
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Skitchish

struct EditorEngineTests {
    private func fixture(width: Int = 80, height: Int = 40) throws -> EditorDocument {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return EditorDocument(imageData: data as Data, imageSize: CGSize(width: width, height: height), title: "透明画像")
    }

    @Test func losslessModelRoundTripAndNonDestructiveTransforms() throws {
        var document = try fixture()
        let original = document.imageData
        document.annotations = [
            .init(
                tool: .text, points: [.init(x: 4, y: 5), .init(x: 34, y: 25)],
                text: "日本語\nSecond line")
        ]
        let source = document
        for _ in 0..<4 { document.rotateClockwise() }
        #expect(document == source)
        document.flip(horizontal: true)
        document.flip(horizontal: true)
        #expect(document == source)
        document.crop(to: CGRect(x: 10, y: 10, width: 20, height: 20))
        document.resize(to: CGSize(width: 100, height: 50))
        #expect(document.imageData == original)
        #expect(document.outputSize == CGSize(width: 100, height: 50))
        let decoded = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded == document)
        try decoded.validate()
    }

    @Test func renderingPreservesAlphaAndUsesCanvasPixels() throws {
        var document = try fixture()
        let renderer = EditorRenderer()
        let image = try renderer.render(document: document)
        #expect(image.width == 80 && image.height == 40)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(try #require(bitmap.colorAt(x: 10, y: 10)).alphaComponent > 0.99)
        #expect(try #require(bitmap.colorAt(x: 60, y: 10)).alphaComponent < 0.01)
        document.crop(to: CGRect(x: 40, y: 0, width: 40, height: 40))
        let cropped = try renderer.render(document: document)
        #expect(cropped.width == 40 && cropped.height == 40)
        #expect(try #require(NSBitmapImageRep(cgImage: cropped).colorAt(x: 10, y: 10)).alphaComponent < 0.01)
    }

    @Test func transformRenderingAgreesWithGeometry() throws {
        var document = try fixture()
        document.rotateClockwise()
        let image = try EditorRenderer().render(document: document)
        #expect(image.width == 40 && image.height == 80)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(try #require(bitmap.colorAt(x: 20, y: 10)).alphaComponent > 0.99)
        #expect(try #require(bitmap.colorAt(x: 20, y: 60)).alphaComponent < 0.01)
    }

    @Test func selectionGeometryIncludesStrokesButNotEmptyShapeInterior() {
        let rectangle = Markup(tool: .rectangle, points: [.init(x: 10, y: 10), .init(x: 110, y: 110)], size: 6)
        #expect(rectangle.hitTest(CGPoint(x: 12, y: 50)))
        #expect(!rectangle.hitTest(CGPoint(x: 60, y: 60)))
        let moved = rectangle.translated(dx: 10, dy: -5)
        #expect(moved.id == rectangle.id)
        #expect(moved.bounds == CGRect(x: 20, y: 5, width: 100, height: 100))
        let resized = rectangle.resized(from: rectangle.bounds, to: CGRect(x: 0, y: 0, width: 20, height: 50))
        #expect(resized.bounds == CGRect(x: 0, y: 0, width: 20, height: 50))
    }

    @Test func pixelationReplacesPriorContentAndExportsOnlyFlattenedPixels() throws {
        var document = try fixture()
        document.annotations = [
            .init(tool: .rectangle, points: [.init(x: 4, y: 4), .init(x: 36, y: 36)], color: .palette[4], size: 4),
            .init(tool: .pixelate, points: [.zero, .init(x: 40, y: 40)], size: 10),
        ]
        let renderer = EditorRenderer()
        let output = try renderer.render(document: document)
        let bitmap = NSBitmapImageRep(cgImage: output)
        // A 20-pixel mosaic cell is constant despite the outlined shape underneath it.
        let one = try #require(bitmap.colorAt(x: 2, y: 2))
        let two = try #require(bitmap.colorAt(x: 12, y: 12))
        #expect(abs(one.redComponent - two.redComponent) < 0.01)
        #expect(abs(one.blueComponent - two.blueComponent) < 0.01)
        #expect(output.width == 80)
        #expect(document.annotations.count == 2)
    }

    @Test func invalidDimensionsAreRejectedBeforeAllocation() throws {
        var document = try fixture()
        document.canvas.size = CGSize(width: 100_000, height: 100_000)
        #expect(throws: EditorRenderError.self) { try document.validate() }
        #expect(throws: EditorRenderError.self) { try EditorRenderer().render(document: document) }
    }

    @Test func japaneseTextAndEveryAnnotationRenderTogether() throws {
        var document = try fixture(width: 800, height: 600)
        let tools: [EditorTool] = [
            .arrow, .text, .rectangle, .roundedRectangle, .ellipse, .line, .pen, .highlight, .stamp,
        ]
        document.annotations = tools.enumerated().map { index, tool in
            let x = CGFloat(index % 3) * 240 + 20
            let y = CGFloat(index / 3) * 160 + 20
            return Markup(
                tool: tool, points: [CGPoint(x: x, y: y), CGPoint(x: x + 210, y: y + 130)],
                color: .palette[index % RGBA.palette.count], size: 6, text: "日本語の注釈\nSecond line", stamp: 4, tail: true)
        }
        document.annotations[1].points = [CGPoint(x: 450, y: 20), CGPoint(x: 750, y: 150)]
        let renderer = EditorRenderer()
        let image = try renderer.render(document: document)
        #expect(image.width == 800 && image.height == 600)
        // The text box is above a transparent source region; glyphs must produce opaque pixels.
        let bitmap = NSBitmapImageRep(cgImage: image)
        var painted = 0
        for y in 20..<140 {
            for x in 450..<700 where bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.5 { painted += 1 }
        }
        #expect(painted > 20)
    }

    @Test func fourKDrawBenchmark() throws {
        var document = try fixture(width: 3840, height: 2160)
        document.annotations = (0..<100).map { index in
            let x = CGFloat(index % 10) * 360 + 20
            let y = CGFloat(index / 10) * 190 + 20
            return Markup(
                tool: index % 2 == 0 ? .arrow : .rectangle,
                points: [CGPoint(x: x, y: y), CGPoint(x: x + 200, y: y + 120)], size: 8)
        }
        let context = try #require(
            CGContext(
                data: nil, width: 3840, height: 2160, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let renderer = EditorRenderer()
        renderer.draw(document: document, in: context)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 {
            context.clear(document.canvas)
            renderer.draw(document: document, in: context)
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 10_000_000
        print("4K / 100 annotations / cached source: \(String(format: "%.2f", milliseconds)) ms per bitmap draw")
        #expect(context.makeImage() != nil)
    }

    @Test func pixelationCacheReusesSnapshotsAndInvalidatesOnlyDependentContent() throws {
        var document = try fixture(width: 240, height: 160)
        document.annotations = [.init(tool: .line, points: [CGPoint(x: 20, y: 20), CGPoint(x: 200, y: 100)], size: 8)]
        for index in 0..<4 {
            let x = CGFloat(index) * 40
            document.annotations.append(
                .init(
                    tool: .pixelate,
                    points: [CGPoint(x: x, y: 0), CGPoint(x: x + 70, y: 140)], size: 8))
        }
        document.annotations.append(.init(tool: .arrow, points: [CGPoint(x: 20, y: 150), CGPoint(x: 220, y: 150)]))
        let renderer = EditorRenderer()
        _ = try renderer.render(document: document)
        #expect(renderer.pixelationRenderCount == 4)
        for _ in 0..<20 { _ = try renderer.render(document: document) }
        #expect(renderer.pixelationRenderCount == 4)
        document.annotations[5] = document.annotations[5].translated(dx: 1, dy: -2)
        _ = try renderer.render(document: document)
        #expect(renderer.pixelationRenderCount == 4)
        document.annotations[3] = document.annotations[3].translated(dx: 2, dy: 0)
        _ = try renderer.render(document: document)
        #expect(renderer.pixelationRenderCount == 6)
        document.annotations[0].color = .palette[4]
        _ = try renderer.render(document: document)
        #expect(renderer.pixelationRenderCount == 10)
        document.flip(horizontal: true)
        _ = try renderer.render(document: document)
        #expect(renderer.pixelationRenderCount == 14)
        let newSource = try fixture(width: 240, height: 160)
        var opaque = newSource
        opaque.annotations = [
            .init(tool: .highlight, points: [.zero, CGPoint(x: 230, y: 150)], color: .palette[3], size: 20)
        ]
        let sourceImage = try EditorRenderer().render(document: opaque)
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sourceImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        document.imageData = data as Data
        _ = try renderer.render(document: document)
        #expect(renderer.pixelationRenderCount == 18)
    }

    @Test func opaquePixelationShortcutTracksActualSnapshotAlphaAndSourceChanges() throws {
        var document = try fixture()
        // Stay inside the opaque half; downsampling at the transparency boundary must
        // conservatively retain a mask when edge samples have fractional alpha.
        document.annotations = [.init(tool: .pixelate, points: [.zero, CGPoint(x: 32, y: 40)], size: 8)]
        let renderer = EditorRenderer()
        let opaque = NSBitmapImageRep(cgImage: try renderer.render(document: document))
        #expect(renderer.transparencyMaskClipCount == 0)
        #expect(try #require(opaque.colorAt(x: 10, y: 10)).alphaComponent > 0.99)
        document.annotations[0] = document.annotations[0].translated(dx: 40, dy: 0)
        let transparent = NSBitmapImageRep(cgImage: try renderer.render(document: document))
        #expect(renderer.transparencyMaskClipCount > 0)
        #expect(try #require(transparent.colorAt(x: 60, y: 10)).alphaComponent < 0.01)
        let context = try #require(
            CGContext(
                data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        document.imageData = data as Data
        let clips = renderer.transparencyMaskClipCount
        let replaced = NSBitmapImageRep(cgImage: try renderer.render(document: document))
        #expect(renderer.transparencyMaskClipCount == clips)
        #expect(try #require(replaced.colorAt(x: 60, y: 10)).alphaComponent > 0.99)
        #expect(try #require(replaced.colorAt(x: 60, y: 10)).redComponent > 0.99)
    }

    @Test func stampLegacyPackagesDecodeAndLabelsStayIndependentOfCircleGeometry() throws {
        let legacy = Markup(
            tool: .stamp, points: [CGPoint(x: 500, y: 100), CGPoint(x: 680, y: 140)],
            text: "Old label", stamp: 2, tail: true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "tailDirection")
        var decoded = try JSONDecoder().decode(Markup.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.tail && decoded.tailDirection == nil)
        #expect(decoded.stampCircleBounds == CGRect(x: 500, y: 100, width: 40, height: 40))
        #expect(decoded.stampLabelBounds.maxX < decoded.stampCircleBounds.minX)
        let oldCircle = decoded.stampCircleBounds
        let oldTip = try #require(decoded.stampTailTip)
        #expect(oldTip.x > oldCircle.midX && oldTip.y > oldCircle.midY)
        decoded.text = "A much longer label 日本語"
        #expect(decoded.stampCircleBounds == oldCircle)
        #expect(decoded.stampTailTip == oldTip)
        decoded.tailDirection = 6
        #expect(try JSONDecoder().decode(Markup.self, from: JSONEncoder().encode(decoded)) == decoded)
        var document = try fixture(width: 800, height: 400)
        document.annotations = [decoded]
        try document.validate()
        document.annotations[0].tailDirection = 8
        #expect(throws: EditorRenderError.self) { try document.validate() }
    }

    @Test func eightStampPointersRenderAndRemainSelectableThroughImageTransforms() throws {
        var document = try fixture(width: 800, height: 400)
        let renderer = EditorRenderer()
        for direction in 0..<8 {
            let mark = Markup(
                tool: .stamp, points: [CGPoint(x: 600, y: 100), CGPoint(x: 640, y: 140)],
                stamp: 0, tail: true, tailDirection: direction)
            let circle = mark.stampCircleBounds
            let tip = try #require(mark.stampTailTip)
            let angle = CGFloat(direction) * .pi / 4
            #expect(abs(tip.x - circle.midX - cos(angle) * 34) < 0.000_001)
            #expect(abs(tip.y - circle.midY - sin(angle) * 34) < 0.000_001)
            let interior = CGPoint(x: circle.midX + cos(angle) * 28, y: circle.midY + sin(angle) * 28)
            #expect(mark.hitTest(interior, tolerance: 0))
            #expect(mark.visualBounds.contains(tip))
            document.annotations = [mark]
            let image = NSBitmapImageRep(cgImage: try renderer.render(document: document))
            #expect(try #require(image.colorAt(x: Int(interior.x), y: Int(interior.y))).alphaComponent > 0.9)
            document.annotations[0].tail = false
            let without = NSBitmapImageRep(cgImage: try renderer.render(document: document))
            #expect(try #require(without.colorAt(x: Int(interior.x), y: Int(interior.y))).alphaComponent < 0.01)

            var labeled = mark
            labeled.text = "Label"
            let label = labeled.stampLabelBounds
            #expect(label.maxX < circle.minX)
            let pointerBounds = try #require(labeled.stampLocalTailPath).boundingBoxOfPath.applying(
                labeled.stampTransform)
            #expect(label.maxX < pointerBounds.minX)
            let moved = labeled.translated(dx: -31, dy: 17)
            #expect(moved.stampCircleBounds == circle.offsetBy(dx: -31, dy: 17))
            #expect(moved.stampLabelBounds == label.offsetBy(dx: -31, dy: 17))
            document.annotations = [labeled]
            document.rotateClockwise()
            let rotated = document.annotations[0]
            let expectedTip = CGPoint(x: 400 - tip.y, y: tip.x)
            #expect(
                hypot(
                    try #require(rotated.stampTailTip).x - expectedTip.x,
                    try #require(rotated.stampTailTip).y - expectedTip.y) < 0.000_001)
            let rotatedInterior = CGPoint(x: 400 - interior.y, y: interior.x)
            #expect(rotated.hitTest(rotatedInterior, tolerance: 0))
            let expectedLabelCenter = CGPoint(x: 400 - label.midY, y: label.midX)
            #expect(
                hypot(
                    rotated.stampLabelBounds.midX - expectedLabelCenter.x,
                    rotated.stampLabelBounds.midY - expectedLabelCenter.y) < 0.000_001)
            document.flip(horizontal: true)
            #expect(
                document.annotations[0].hitTest(CGPoint(x: 400 - rotatedInterior.x, y: rotatedInterior.y), tolerance: 0)
            )
            // Reset source/canvas orientation for the next octant.
            document = try fixture(width: 800, height: 400)
        }
    }

    @Test func stampLabelRendersOnlyLeftAndDoesNotChangeCirclePixels() throws {
        var document = try fixture(width: 800, height: 240)
        var stamp = Markup(tool: .stamp, points: [CGPoint(x: 600, y: 100), CGPoint(x: 640, y: 140)], stamp: 4)
        document.annotations = [stamp]
        let renderer = EditorRenderer()
        let without = NSBitmapImageRep(cgImage: try renderer.render(document: document))
        stamp.text = "LEFT 日本語"
        document.annotations = [stamp]
        let labeled = NSBitmapImageRep(cgImage: try renderer.render(document: document))
        var labelPixels = 0
        for y in 80..<160 {
            for x in 400..<680 {
                let before = try #require(without.colorAt(x: x, y: y))
                let after = try #require(labeled.colorAt(x: x, y: y))
                if x >= 600 { #expect(before == after) }
                if x < 596 && after.alphaComponent > 0.9 { labelPixels += 1 }
            }
        }
        #expect(labelPixels > 50)
    }

    @Test func multilineStampLabelAlignsBothLinesTowardCircle() throws {
        var document = try fixture(width: 800, height: 240)
        let stamp = Markup(
            tool: .stamp, points: [CGPoint(x: 600, y: 100), CGPoint(x: 640, y: 140)],
            text: "MMMMMMMM\nM", stamp: 4)
        document.annotations = [stamp]
        let image = NSBitmapImageRep(cgImage: try EditorRenderer().render(document: document))
        let label = stamp.stampLocalLabelTextBounds.applying(stamp.stampTransform)
        var topRight = -1
        var bottomRight = -1
        for y in Int(floor(label.minY))..<Int(ceil(label.maxY)) {
            for x in Int(floor(label.minX))..<Int(ceil(label.maxX)) {
                let pixel = try #require(image.colorAt(x: x, y: y))
                guard pixel.alphaComponent > 0.9, pixel.redComponent > 0.9,
                    pixel.greenComponent > 0.9, pixel.blueComponent > 0.9
                else { continue }
                if CGFloat(y) < label.midY { topRight = max(topRight, x) } else { bottomRight = max(bottomRight, x) }
            }
        }
        #expect(topRight > Int(label.maxX) - 5)
        #expect(bottomRight > Int(label.maxX) - 5)
        #expect(abs(topRight - bottomRight) <= 2)
    }

    @Test func stampLabelHasWhiteFrameBlackBackgroundAndWhiteGlyphsForEveryStampAndColor() throws {
        var document = try fixture(width: 800, height: 240)
        let renderer = EditorRenderer()
        var baseline: [NSColor]?
        for kind in 0..<5 {
            for color in RGBA.palette {
                let stamp = Markup(
                    tool: .stamp, points: [CGPoint(x: 600, y: 100), CGPoint(x: 640, y: 140)],
                    color: color, text: "Label 日本語", stamp: kind)
                document.annotations = [stamp]
                let bitmap = NSBitmapImageRep(cgImage: try renderer.render(document: document))
                let frame = stamp.stampLabelBounds
                let text = stamp.stampLocalLabelTextBounds.applying(stamp.stampTransform)
                var frameWhite = 0
                var glyphWhite = 0
                var interiorBlack = 0
                var pixels: [NSColor] = []
                for y in Int(floor(frame.minY))..<Int(ceil(frame.maxY)) {
                    for x in Int(floor(frame.minX))..<Int(ceil(frame.maxX)) {
                        let pixel = try #require(bitmap.colorAt(x: x, y: y))
                        pixels.append(pixel)
                        let inText = text.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                        if pixel.alphaComponent > 0.95 && pixel.redComponent > 0.9 && pixel.greenComponent > 0.9
                            && pixel.blueComponent > 0.9
                        {
                            if inText { glyphWhite += 1 } else { frameWhite += 1 }
                        }
                        if inText && pixel.alphaComponent > 0.99 && pixel.redComponent < 0.01
                            && pixel.greenComponent < 0.01 && pixel.blueComponent < 0.01
                        {
                            interiorBlack += 1
                        }
                    }
                }
                #expect(frameWhite > 40)
                #expect(glyphWhite > 30)
                #expect(interiorBlack > 100)
                if let baseline { #expect(pixels == baseline) } else { baseline = pixels }
            }
        }
        let screen = try #require(
            CGContext(
                data: nil, width: 800, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        screen.translateBy(x: 0, y: 240)
        screen.scaleBy(x: 1, y: -1)
        renderer.draw(document: document, in: screen)
        let displayed = try #require(screen.makeImage())
        let exported = try renderer.render(document: document)
        #expect(try #require(displayed.dataProvider?.data) as Data == #require(exported.dataProvider?.data) as Data)
    }

    @MainActor @Test func stampLabelMetricsFitFallbackGlyphsAndCompleteMultilineFrames() throws {
        for text in ["Label 日本語", "MMMMMMMM\nM", "日本語\nSecond line\n終", "Trailing\n"] {
            for diameter in [CGFloat(28), 40, 84] {
                let style = StampLabelStyle(diameter: diameter)
                let measured = style.textSize(for: text)
                let font = EditorRenderer.stampLabelFont(size: style.fontSize)
                let string = NSAttributedString(string: text, attributes: [.font: font])
                let framesetter = CTFramesetterCreateWithAttributedString(string)
                let frame = CTFramesetterCreateFrame(
                    framesetter, CFRange(),
                    CGPath(rect: CGRect(origin: .zero, size: measured), transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                #expect(visible.location + visible.length == string.length)
                for zoom in [CGFloat(0.75), 1, 2] {
                    let storage = NSTextStorage(
                        string: text,
                        attributes: [.font: EditorRenderer.stampLabelFont(size: style.fontSize * zoom)])
                    let layout = NSLayoutManager()
                    layout.usesFontLeading = false
                    let container = NSTextContainer(size: CGSize(width: measured.width * zoom, height: 10_000))
                    container.lineFragmentPadding = 0
                    storage.addLayoutManager(layout)
                    layout.addTextContainer(container)
                    layout.ensureLayout(for: container)
                    #expect(layout.usedRect(for: container).height <= measured.height * zoom + 1)
                }
            }
        }
    }

    @Test func arrowShaftWidensSmoothlyIntoCrispTriangularHead() throws {
        let arrow = Markup(tool: .arrow, points: [.zero, CGPoint(x: 220, y: 0)], size: 6)
        let path = try #require(arrow.arrowPath)
        #expect(arrow.arrowHeadLength > 48 && arrow.arrowHeadLength < 51)
        var previousWidth: CGFloat = 0
        for x in [CGFloat(8), 30, 60, 100, 140, 170] {
            var first: CGFloat?
            var last: CGFloat?
            for sample in -300...300 {
                let y = CGFloat(sample) / 10
                if path.contains(CGPoint(x: x, y: y)) {
                    if first == nil { first = y }
                    last = y
                }
            }
            let width = try #require(last) - #require(first)
            #expect(width > previousWidth)
            previousWidth = width
        }
        #expect(previousWidth > 15)
        // The outer head has straight sides: these points sit just inside and outside
        // its half-way cross-section, which would differ for the previous leaf contour.
        let x = 220 - arrow.arrowHeadLength * 0.5
        #expect(path.contains(CGPoint(x: x, y: arrow.arrowHeadLength * 0.255)))
        #expect(!path.contains(CGPoint(x: x, y: arrow.arrowHeadLength * 0.265)))
        #expect(path.boundingBoxOfPath.minX >= -0.001)
        #expect(abs(path.boundingBoxOfPath.maxX - 220) < 0.001)
    }

    @Test func stampPointerHasParallelSidesAndAnEightDirectionPointedTip() throws {
        let stamp = Markup(
            tool: .stamp, points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 40)],
            tail: true, tailDirection: 0)
        let path = try #require(stamp.stampLocalTailPath)
        var widths: [CGFloat] = []
        for radial in [CGFloat(0.5), 0.6, 0.65, 0.75, 0.82] {
            var first: CGFloat?
            var last: CGFloat?
            for sample in -150...150 {
                let y = CGFloat(sample) / 10
                if path.contains(CGPoint(x: radial * 40, y: y)) {
                    if first == nil { first = y }
                    last = y
                }
            }
            let width = try #require(last) - #require(first)
            #expect(width > 0)
            widths.append(width)
        }
        #expect(abs(widths[0] - widths[1]) < 0.11)
        #expect(widths[1] > widths[2] && widths[2] > widths[3] && widths[3] > widths[4])
        #expect(abs(path.boundingBoxOfPath.maxX - 34) < 0.001)
        #expect(abs(path.boundingBoxOfPath.height - 22.4) < 0.001)
        for direction in 0..<8 {
            var directed = stamp
            directed.tailDirection = direction
            let tip = try #require(directed.stampLocalTailTip)
            #expect(
                directed.stampLocalSilhouette.boundingBoxOfPath.insetBy(dx: -0.000_001, dy: -0.000_001).contains(tip))
            let angle = CGFloat(direction) * .pi / 4
            let join = CGPoint(x: cos(angle) * 19, y: sin(angle) * 19)
            #expect(directed.stampLocalSilhouette.contains(join))
        }
    }

    @Test func arrowAndStampShadowsStayInsideVisualBoundsAndStampHasWhiteCenter() throws {
        var document = try fixture(width: 800, height: 300)
        let renderer = EditorRenderer()
        let marks = [
            Markup(tool: .arrow, points: [CGPoint(x: 470, y: 70), CGPoint(x: 690, y: 70)], size: 6),
            Markup(
                tool: .stamp, points: [CGPoint(x: 540, y: 160), CGPoint(x: 600, y: 220)], stamp: 1, tail: true,
                tailDirection: 2),
        ]
        for mark in marks {
            document.annotations = [mark]
            let image = NSBitmapImageRep(cgImage: try renderer.render(document: document))
            var shadowPixels = 0
            for y in 0..<300 {
                for x in 410..<800 {
                    let color = try #require(image.colorAt(x: x, y: y))
                    guard color.alphaComponent > 0.01 else { continue }
                    #expect(mark.visualBounds.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)))
                    if color.alphaComponent < 0.5 && color.redComponent < 0.1 && color.greenComponent < 0.1
                        && color.blueComponent < 0.1
                    {
                        shadowPixels += 1
                    }
                }
            }
            #expect(shadowPixels > 20)
            if mark.tool == .stamp {
                let interior = try #require(image.colorAt(x: 570, y: 178))
                #expect(interior.redComponent > 0.95 && interior.greenComponent > 0.95 && interior.blueComponent > 0.95)
                let ring = try #require(image.colorAt(x: 570, y: 164))
                #expect(ring.redComponent > 0.95 && ring.greenComponent < 0.3 && ring.blueComponent < 0.2)
                // A point crossing the circle/tab attachment stays red, without a white seam.
                let attachment = try #require(image.colorAt(x: 570, y: 217))
                #expect(
                    attachment.redComponent > 0.95 && attachment.greenComponent < 0.3 && attachment.blueComponent < 0.2)
            }
        }
    }

    @Test func arrowHeadGrowsWithLengthAndWeightWithoutConsumingShortShaft() throws {
        let lengths: [CGFloat] = [8, 24, 80, 240, 720]
        let weights: [CGFloat] = [2, 4, 6, 8, 10]
        for weight in weights {
            var previous: CGFloat = 0
            for length in lengths {
                let mark = Markup(tool: .arrow, points: [.zero, CGPoint(x: length, y: 0)], size: weight)
                #expect(mark.arrowHeadLength > previous)
                #expect(mark.arrowHeadLength < length * 0.48)
                #expect(mark.arrowHeadLength <= weight * 8.5)
                previous = mark.arrowHeadLength
                let enlarged = Markup(tool: .arrow, points: [.zero, CGPoint(x: length * 3, y: 0)], size: weight * 3)
                #expect(abs(enlarged.arrowHeadLength - mark.arrowHeadLength * 3) < 0.000_001)
            }
        }
        let medium = Markup(tool: .arrow, points: [.zero, CGPoint(x: 220, y: 0)], size: 6)
        let long = Markup(tool: .arrow, points: [.zero, CGPoint(x: 440, y: 0)], size: 6)
        #expect(long.arrowHeadLength / medium.arrowHeadLength < 1.05)
        for length in lengths {
            var previous: CGFloat = 0
            for weight in weights {
                let mark = Markup(tool: .arrow, points: [.zero, CGPoint(x: length, y: 0)], size: weight)
                #expect(mark.arrowHeadLength > previous)
                previous = mark.arrowHeadLength
                // Both broad wings, including rotated/reflected arrows, are selectable.
                for angle in [CGFloat(0), .pi / 4, .pi / 2, .pi] {
                    var rotated = mark
                    rotated.points = [
                        CGPoint(x: 100, y: 100), CGPoint(x: 100 + cos(angle) * length, y: 100 + sin(angle) * length),
                    ]
                    for reflected in [false, true] {
                        rotated.mirrored = reflected
                        let path = try #require(rotated.arrowPath)
                        #expect(rotated.visualBounds.contains(path.boundingBoxOfPath))
                        for side in [CGFloat(-1), 1] {
                            let local = CGPoint(
                                x: length - mark.arrowHeadLength * 0.85, y: side * mark.arrowHeadLength * 0.38)
                            let point = local.applying(CGAffineTransform(translationX: 100, y: 100).rotated(by: angle))
                            #expect(rotated.hitTest(point, tolerance: 0))
                        }
                    }
                }
            }
        }
    }

    @Test func renderedArrowHeadsGrowAndTheirPixelsRemainSelectableInScreenAndExport() throws {
        var document = try fixture(width: 1800, height: 240)
        document.crop(to: CGRect(x: 900, y: 0, width: 900, height: 240))
        let renderer = EditorRenderer()
        var previousHeight = 0
        for length in [CGFloat(60), 240, 720] {
            let arrow = Markup(
                tool: .arrow, points: [CGPoint(x: 940, y: 120), CGPoint(x: 940 + length, y: 120)], size: 6)
            document.annotations = [arrow]
            let exported = try renderer.render(document: document)
            let bitmap = NSBitmapImageRep(cgImage: exported)
            var top = 240
            var bottom = 0
            for y in 0..<240 {
                for x in 0..<900 {
                    guard let pixel = bitmap.colorAt(x: x, y: y), pixel.alphaComponent > 0.9 else { continue }
                    let world = CGPoint(x: CGFloat(x) + 900.5, y: CGFloat(y) + 0.5)
                    #expect(arrow.visualBounds.contains(world))
                    #expect(arrow.hitTest(world, tolerance: 0.5))
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
            #expect(bottom - top >= previousHeight)
            if length <= 240 { #expect(bottom - top > previousHeight) }
            previousHeight = bottom - top
            let screen = try #require(
                CGContext(
                    data: nil, width: 900, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            screen.translateBy(x: 0, y: 240)
            screen.scaleBy(x: 1, y: -1)
            screen.translateBy(x: -900, y: 0)
            renderer.draw(document: document, in: screen)
            let displayed = try #require(screen.makeImage())
            #expect(try #require(displayed.dataProvider?.data) as Data == #require(exported.dataProvider?.data) as Data)
        }
    }

    @MainActor @Test func inlineMediumWeightGlyphsRetainColoredFaceInsideWhiteOutline() throws {
        let storage = NSTextStorage(
            string: "Label 日本語",
            attributes: [
                .font: EditorRenderer.stampLabelFont(size: 16), .foregroundColor: NSColor.red,
            ])
        let original = NSAttributedString(attributedString: storage)
        let layout = OutlinedTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 320, height: 80))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let context = try #require(
            CGContext(
                data: nil, width: 360, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 120)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: CGPoint(x: 20, y: 20))
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        var redPixels = 0
        var whitePixels = 0
        for y in 10..<70 {
            for x in 10..<200 {
                let pixel = try #require(bitmap.colorAt(x: x, y: y))
                guard pixel.alphaComponent > 0.9 else { continue }
                if pixel.redComponent > 0.9 && pixel.greenComponent < 0.1 && pixel.blueComponent < 0.1 {
                    redPixels += 1
                }
                if pixel.redComponent > 0.95 && pixel.greenComponent > 0.95 && pixel.blueComponent > 0.95 {
                    whitePixels += 1
                }
            }
        }
        #expect(redPixels > 40)
        #expect(whitePixels > 40)
        #expect(storage.isEqual(to: original))
    }

    @Test func coloredTextHasWhiteOuterOutlineAndSoftGrayShadowInScreenAndExport() throws {
        var document = try fixture(width: 500, height: 180)
        let renderer = EditorRenderer()
        for color in [RGBA.palette[0], .palette[2], .palette[4]] {
            document.annotations = [
                .init(
                    tool: .text,
                    points: [CGPoint(x: 280, y: 45), CGPoint(x: 490, y: 120)], color: color, size: 6, text: "Skitch")
            ]
            let exported = try renderer.render(document: document)
            let bitmap = NSBitmapImageRep(cgImage: exported)
            var coloredPixels = 0
            var whitePixels = 0
            var grayPixels = 0
            var leftColor = 500
            var leftWhite = 500
            var bottomOpaque = 0
            var bottomGray = 0
            // This half of the source is transparent, so white/gray pixels can only
            // come from the annotation halo and shadow, not from the background.
            for y in 25..<140 {
                for x in 260..<495 {
                    let pixel = try #require(bitmap.colorAt(x: x, y: y))
                    if pixel.alphaComponent > 0.98 {
                        if abs(pixel.redComponent - color.r) < 0.04 && abs(pixel.greenComponent - color.g) < 0.04
                            && abs(pixel.blueComponent - color.b) < 0.04
                        {
                            coloredPixels += 1
                            leftColor = min(leftColor, x)
                            bottomOpaque = max(bottomOpaque, y)
                        }
                        if pixel.redComponent > 0.97 && pixel.greenComponent > 0.97 && pixel.blueComponent > 0.97 {
                            whitePixels += 1
                            leftWhite = min(leftWhite, x)
                            bottomOpaque = max(bottomOpaque, y)
                        }
                    }
                    if pixel.alphaComponent > 0.02 && pixel.alphaComponent < 0.7 && pixel.redComponent > 0.1
                        && pixel.redComponent < 0.6 && abs(pixel.redComponent - pixel.greenComponent) < 0.03
                        && abs(pixel.redComponent - pixel.blueComponent) < 0.03
                    {
                        grayPixels += 1
                        bottomGray = max(bottomGray, y)
                    }
                }
            }
            #expect(coloredPixels > 30)
            #expect(whitePixels > 30)
            #expect(leftWhite < leftColor)
            #expect(grayPixels > 20)
            #expect(bottomGray > bottomOpaque)
            let screen = try #require(
                CGContext(
                    data: nil, width: 500, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            screen.translateBy(x: 0, y: 180)
            screen.scaleBy(x: 1, y: -1)
            renderer.draw(document: document, in: screen)
            let displayed = try #require(screen.makeImage())
            #expect(try #require(displayed.dataProvider?.data) as Data == #require(exported.dataProvider?.data) as Data)
        }
    }
}
