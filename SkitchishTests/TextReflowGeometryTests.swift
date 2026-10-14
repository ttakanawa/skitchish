import AppKit
import CoreText
import Testing

@testable import Skitchish

struct TextReflowGeometryTests {
    @Test func reflowKeepsTheFinalJapaneseLineVisibleAtNarrowAndFractionalWidths() throws {
        let text = "日本語の折り返しを確認します。 English words wrap too.\n最後の日本語まで表示"
        for fontSize: CGFloat in [12, 24, 56] {
            for requestedWidth: CGFloat in [24, 48, 123.5, 300] {
                let width = max(fontSize, requestedWidth)
                let height = try #require(
                    TextAnnotationGeometry.measuredHeight(text: text, width: width, fontSize: fontSize))
                let frame = textFrame(text, fontSize: fontSize, width: width, height: height)
                let visible = CTFrameGetVisibleStringRange(frame)
                #expect(visible.location + visible.length == (text as NSString).length)
                #expect(CFArrayGetCount(CTFrameGetLines(frame)) > 1)
            }
        }
    }

    @Test func aTrailingReturnReservesAnEditableEmptyLineWithoutChangingTheText() throws {
        let mark = Markup(
            tool: .text, points: [CGPoint(x: 20, y: 30), CGPoint(x: 260, y: 90)],
            size: 6, text: "日本語の入力")
        let plainHeight = try #require(TextAnnotationGeometry.measuredHeight(text: mark.text, width: 240, fontSize: 24))
        for ending in ["\n", "\r\n", "\u{2028}", "\u{2029}"] {
            var withReturn = mark
            withReturn.text += ending
            let updated = TextAnnotationGeometry.reflowed(
                withReturn, draggingLeftEdge: false,
                to: CGPoint(x: 260, y: 50))
            #expect(updated.text == withReturn.text)
            #expect(updated.size == mark.size)
            #expect(updated.bounds.height > plainHeight + 15)
            // A newly typed glyph on the reserved final line must already fit.
            let withNextGlyph = withReturn.text + "M"
            let visible = CTFrameGetVisibleStringRange(
                textFrame(
                    withNextGlyph, fontSize: 24, width: 240,
                    height: updated.bounds.height))
            #expect(visible.location + visible.length == (withNextGlyph as NSString).length)
        }
    }

    @Test func narrowingLongTextStopsBeforeExpandedCanvasExceedsItsPixelBudget() throws {
        let canvas = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        let mark = Markup(
            tool: .text, points: [CGPoint(x: 9000, y: 9000), CGPoint(x: 9600, y: 9600)],
            size: 6, text: String(repeating: "あ", count: 600))
        let updated = TextAnnotationGeometry.reflowed(
            mark, draggingLeftEdge: false,
            to: CGPoint(x: 9024, y: 9300), canvas: canvas)
        #expect(updated.bounds.width > 24 && updated.bounds.width < mark.bounds.width)
        #expect(updated.bounds.minX == mark.bounds.minX && updated.bounds.minY == mark.bounds.minY)
        #expect(updated.text == mark.text && updated.size == mark.size)
        let expanded = try validatedExpandedDocument(canvas: canvas, mark: updated)
        #expect(expanded.canvas.width * expanded.canvas.height <= 150_000_000)
        let visible = CTFrameGetVisibleStringRange(
            textFrame(
                updated.text, fontSize: 24,
                width: updated.bounds.width, height: updated.bounds.height))
        #expect(visible.length == (mark.text as NSString).length)
    }

    @Test func wideningEitherEdgePreservesTheAnchorAtTheCanvasAreaLimit() throws {
        let canvas = CGRect(x: 0, y: 0, width: 12_000, height: 12_000)
        for leftEdge in [false, true] {
            let mark = Markup(
                tool: .text, points: [CGPoint(x: 11_900, y: 50), CGPoint(x: 11_980, y: 110)],
                size: 6, text: "Text")
            let pointer = CGPoint(x: leftEdge ? -1_000_000 : 1_000_000, y: 80)
            let updated = TextAnnotationGeometry.reflowed(mark, draggingLeftEdge: leftEdge, to: pointer, canvas: canvas)
            #expect(updated.bounds.width > mark.bounds.width && updated.bounds.width < 65_536)
            #expect(updated.bounds.minY == mark.bounds.minY)
            #expect(leftEdge ? updated.bounds.maxX == mark.bounds.maxX : updated.bounds.minX == mark.bounds.minX)
            _ = try validatedExpandedDocument(canvas: canvas, mark: updated)
        }
    }

    @Test func excessiveReflowHeightIsRejectedWithoutClippingOrScalingTheFont() throws {
        let text = String(repeating: "あ", count: 3000)
        #expect(TextAnnotationGeometry.measuredHeight(text: text, width: 24, fontSize: 24) == nil)
        let mark = Markup(
            tool: .text, points: [CGPoint(x: 20, y: 30), CGPoint(x: 620, y: 5030)],
            size: 6, text: text)
        let updated = TextAnnotationGeometry.reflowed(mark, draggingLeftEdge: false, to: CGPoint(x: 44, y: 40))
        #expect(updated.bounds.width > 24)
        #expect(updated.bounds.height <= 65_536)
        #expect(updated.text == text && updated.size == mark.size)
        _ = try validatedExpandedDocument(canvas: mark.bounds, mark: updated)
        #expect(
            TextAnnotationGeometry.reflowed(
                mark, draggingLeftEdge: false,
                to: CGPoint(x: CGFloat.infinity, y: 0)) == mark)
        #expect(TextAnnotationGeometry.measuredHeight(text: text, width: .nan, fontSize: 24) == nil)
    }

    private func textFrame(_ text: String, fontSize: CGFloat, width: CGFloat, height: CGFloat) -> CTFrame {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(
            string: text,
            attributes: [
                .font: EditorRenderer.annotationFont(size: fontSize), .paragraphStyle: paragraph,
            ])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        return CTFramesetterCreateFrame(
            framesetter, CFRange(),
            CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
    }

    private func validatedExpandedDocument(canvas: CGRect, mark: Markup) throws -> EditorDocument {
        // Geometry validation does not require decoding a bitmap; keep limit tests
        // small in memory even when the document's legal dimensions are very large.
        var document = EditorDocument(imageData: Data(), imageSize: CGSize(width: 1, height: 1))
        document.canvas = canvas
        document.annotations = [mark]
        document.expandCanvas(toInclude: mark.visualBounds)
        try document.validate()
        return document
    }
}
