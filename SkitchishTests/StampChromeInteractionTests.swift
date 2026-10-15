import AppKit
import Testing

@testable import Skitchish

@MainActor
struct StampChromeInteractionTests {
    private let preferences = TestPreferences()

    private func canvas(mark: Markup, tool: EditorTool, zoom: CGFloat = 1) throws -> CanvasView {
        let bitmap = try #require(
            CGContext(
                data: nil, width: 800, height: 600,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var document = EditorDocument(
            imageData: try ImageService.pngData(#require(bitmap.makeImage())),
            imageSize: CGSize(width: 800, height: 600))
        document.annotations = [mark]
        let session = preferences.session(document: document)
        session.tool = tool
        session.zoom = zoom
        let canvas = CanvasView(session: session, renderer: EditorRenderer())
        canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 1000)
        return canvas
    }

    private func event(_ type: NSEvent.EventType, _ point: CGPoint, in canvas: CanvasView) throws -> NSEvent {
        try TestEvent.mouse(type, atWindowPoint: canvas.convert(point, to: nil))
    }

    private func drag(_ start: CGPoint, to end: CGPoint, in canvas: CanvasView) throws {
        canvas.mouseDown(with: try event(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: try event(.leftMouseDragged, end, in: canvas))
        canvas.mouseUp(with: try event(.leftMouseUp, end, in: canvas))
    }

    @Test func bodyDragMovesInsteadOfEditingOrChangingPointerInEveryDrawingTool() throws {
        for tool in EditorTool.allCases where tool != .crop {
            let mark = Markup(
                tool: .stamp, points: [CGPoint(x: 300, y: 200), CGPoint(x: 360, y: 260)],
                size: 6, text: "確認", stamp: 1, tail: true, tailDirection: 2)
            let canvas = try canvas(mark: mark, tool: tool)
            let before = canvas.session.document
            let start = canvas.transform.viewPoint(
                CGPoint(x: mark.stampCircleBounds.midX, y: mark.stampCircleBounds.midY))
            try drag(start, to: CGPoint(x: start.x + 40, y: start.y + 25), in: canvas)
            let result = try #require(canvas.session.document.annotations.first)
            #expect(result.points == mark.points.map { CGPoint(x: $0.x + 40, y: $0.y + 25) })
            #expect(result.text == mark.text && result.tail == mark.tail && result.tailDirection == mark.tailDirection)
            #expect(!canvas.isEditingText && canvas.session.document.annotations.count == 1)
            canvas.session.history.undo()
            #expect(canvas.session.document == before)
        }
    }

    @Test func pointerHandleChangesEightDirectionsThroughRotationMirrorAndZoomWithoutMovingMarker() throws {
        for mirrored in [false, true] {
            for turns in 0..<4 {
                for direction in 0..<8 {
                    var mark = Markup(
                        tool: .stamp, points: [CGPoint(x: 320, y: 230), CGPoint(x: 380, y: 290)],
                        size: 6, stamp: 1)
                    mark.quarterTurns = turns
                    mark.mirrored = mirrored
                    let canvas = try canvas(mark: mark, tool: .rectangle, zoom: 0.75)
                    canvas.session.selection = [mark.id]
                    let before = canvas.session.document
                    let start = StampSelectionChrome(mark: mark, mapping: canvas.transform).pointerCenter
                    let angle = CGFloat(direction) * .pi / 4
                    let local = CGPoint(x: cos(angle) * 170, y: sin(angle) * 170)
                    let end = canvas.transform.viewPoint(local.applying(mark.stampTransform))
                    try drag(start, to: end, in: canvas)
                    let result = try #require(canvas.session.document.annotations.first)
                    #expect(result.tail && result.tailDirection == direction)
                    #expect(result.points == mark.points && result.text == mark.text)
                    #expect(!canvas.isEditingText)
                    canvas.session.history.undo()
                    #expect(canvas.session.document == before && !canvas.session.history.canUndo)
                }
            }
        }
    }

    @Test func pointerCanReturnToCircleWithoutRemovingLabelAndEveryControlCenterRemainsReachable() throws {
        for text in ["", "a", "確認中"] {
            for zoom: CGFloat in [0.1, 0.75, 2] {
                let mark = Markup(
                    tool: .stamp, points: [CGPoint(x: 320, y: 230), CGPoint(x: 380, y: 290)],
                    size: 6, text: text, stamp: 1, tail: true, tailDirection: 4)
                let canvas = try canvas(mark: mark, tool: .text, zoom: zoom)
                canvas.session.selection = [mark.id]
                let before = canvas.session.document
                let chrome = StampSelectionChrome(mark: mark, mapping: canvas.transform)
                #expect(chrome.action(at: chrome.pointerCenter) == .pointer)
                if let label = chrome.labelButtonRect {
                    #expect(chrome.action(at: CGPoint(x: label.midX, y: label.midY)) == .addLabel)
                }
                if let remove = chrome.removeLabelCenter { #expect(chrome.action(at: remove) == .removeLabel) }
                let center = canvas.transform.viewPoint(
                    CGPoint(x: mark.stampCircleBounds.midX, y: mark.stampCircleBounds.midY))
                try drag(chrome.pointerCenter, to: center, in: canvas)
                let result = canvas.session.document.annotations[0]
                #expect(!result.tail && result.points == mark.points && result.text == mark.text)
                #expect(!canvas.isEditingText)
                canvas.session.history.undo()
                #expect(canvas.session.document == before)
            }
        }
    }

    @Test func pointerControlsNeverCoverFixedLeftLabelsIncludingRotatedAndMirroredMarkers() throws {
        for diameter: CGFloat in [60, 120] {
            for zoom: CGFloat in [0.1, 0.75, 2] {
                for turns in 0..<4 {
                    for mirrored in [false, true] {
                        for text in ["a", "確認中", "確認\n次の行"] {
                            var mark = Markup(
                                tool: .stamp,
                                points: [CGPoint(x: 300, y: 200), CGPoint(x: 300 + diameter, y: 200 + diameter)],
                                size: 6, text: text, stamp: 1, tail: true, tailDirection: 4)
                            mark.quarterTurns = turns
                            mark.mirrored = mirrored
                            let mapping = CanvasTransform(
                                canvas: CGRect(x: 0, y: 0, width: 800, height: 600),
                                zoom: zoom, origin: CGPoint(x: 80, y: 80))
                            let chrome = StampSelectionChrome(mark: mark, mapping: mapping)
                            let pointerCircle = CGRect(
                                x: chrome.pointerCenter.x - 6.625,
                                y: chrome.pointerCenter.y - 6.625,
                                width: 13.25, height: 13.25)
                            #expect(
                                !pointerCircle.intersects(mapping.viewRect(mark.stampLabelBounds)),
                                "A pointer handle must never obscure the label's text")
                            #expect(chrome.action(at: chrome.pointerCenter) == .pointer)
                            let remove = try #require(chrome.removeLabelCenter)
                            #expect(chrome.action(at: remove) == .removeLabel)
                        }
                    }
                }
            }
        }
    }
}
