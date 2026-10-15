import AppKit
import Testing

@testable import Skitchish

@MainActor
struct TextSelectionInteractionTests {
    private let preferences = TestPreferences()

    private func fixture(zoom: CGFloat = 1) throws -> (EditorSession, CanvasView, Markup) {
        let bitmap = try #require(
            CGContext(
                data: nil, width: 1000, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(bitmap.makeImage())
        var document = EditorDocument(
            imageData: try ImageService.pngData(image), imageSize: CGSize(width: 1000, height: 800))
        let mark = Markup(
            tool: .text, points: [CGPoint(x: 120, y: 100), CGPoint(x: 440, y: 200)], size: 6,
            text: "日本語の幅を調整します。 Keep the same font size while wrapping this text.")
        document.annotations = [mark]
        let session = preferences.session(document: document)
        session.tool = .select
        session.zoom = zoom
        session.selection = [mark.id]
        let canvas = CanvasView(session: session, renderer: EditorRenderer())
        canvas.frame = CGRect(x: 0, y: 0, width: 2400, height: 1900)
        return (session, canvas, mark)
    }

    private func event(
        _ type: NSEvent.EventType, at point: CGPoint, on canvas: CanvasView,
        clicks: Int = 1
    ) throws -> NSEvent {
        try TestEvent.mouse(type, atWindowPoint: canvas.convert(point, to: nil), clicks: clicks)
    }

    private func beginEditing(_ canvas: CanvasView, mark: Markup) throws -> NSTextView {
        let point = canvas.transform.viewPoint(CGPoint(x: mark.bounds.minX + 30, y: mark.bounds.minY + 15))
        canvas.mouseDown(with: try event(.leftMouseDown, at: point, on: canvas, clicks: 2))
        return try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
    }

    @Test func widthGripsRespectGrabOffsetAtEveryZoomAndBothEdges() throws {
        for zoom: CGFloat in [0.5, 1, 2] {
            for left in [false, true] {
                let (session, canvas, mark) = try fixture(zoom: zoom)
                let before = session.document
                let chrome = TextSelectionChrome(mark: mark, mapping: canvas.transform)
                let center = chrome.sideCenters[left ? 0 : 1]
                // Grab the curved outer rim, away from the exact edge and midpoint.
                let start = CGPoint(x: center.x + (left ? -5 : 5), y: center.y + 3)
                #expect(chrome.widthHandle(at: start) == (left ? 4 : 5))
                canvas.mouseDown(with: try event(.leftMouseDown, at: start, on: canvas))
                canvas.mouseDragged(with: try event(.leftMouseDragged, at: start, on: canvas))
                #expect(
                    abs(session.document.annotations[0].bounds.width - 320) < 0.001,
                    "Grabbing the outer rim must not jump to the pointer's coordinate")
                let end = CGPoint(x: start.x + (left ? 130 : -130) * zoom, y: start.y)
                canvas.mouseDragged(with: try event(.leftMouseDragged, at: end, on: canvas))
                #expect(canvas.draftDocument == before)
                canvas.mouseUp(with: try event(.leftMouseUp, at: end, on: canvas))
                let changed = session.document.annotations[0]
                #expect(abs(changed.bounds.width - 190) < 0.001)
                #expect(changed.size == mark.size && changed.text == mark.text)
                #expect(
                    abs(
                        (left ? changed.bounds.maxX : changed.bounds.minX)
                            - (left ? mark.bounds.maxX : mark.bounds.minX)) < 0.001)
                #expect(changed.bounds.minY == mark.bounds.minY)
                let after = session.document
                session.history.undo()
                #expect(session.document == before && !session.history.canUndo)
                session.history.redo()
                #expect(session.document == after)
            }
        }
    }

    @Test func inlineWidthDragKeepsEditorCaretAndOneUndoStepThenSavesGeometry() throws {
        for left in [false, true] {
            let (session, canvas, mark) = try fixture()
            let before = session.document
            let editor = try beginEditing(canvas, mark: mark)
            let initialFrame = editor.frame
            let initialFont = editor.font?.pointSize
            let caret = NSRange(location: 5, length: 2)
            editor.setSelectedRange(caret)
            let chrome = TextSelectionChrome(editorFrame: editor.frame)
            let center = chrome.sideCenters[left ? 0 : 1]
            let start = CGPoint(x: center.x + (left ? -5 : 5), y: center.y + 2)
            #expect(
                canvas.hitTest(canvas.convert(start, to: canvas.superview)) === canvas,
                "The text view must not swallow its outside width grip")
            canvas.mouseDown(with: try event(.leftMouseDown, at: start, on: canvas))
            for delta in [20.0, 60, 100, 130] {
                let point = CGPoint(x: start.x + (left ? delta : -delta), y: start.y)
                canvas.mouseDragged(with: try event(.leftMouseDragged, at: point, on: canvas))
            }
            let end = CGPoint(x: start.x + (left ? 130 : -130), y: start.y)
            canvas.mouseUp(with: try event(.leftMouseUp, at: end, on: canvas))
            #expect(canvas.isEditingText && editor.superview === canvas)
            #expect(editor.selectedRange() == caret && editor.string == mark.text)
            #expect(editor.font?.pointSize == initialFont)
            #expect(abs(editor.frame.width - initialFrame.width + 130) < 0.001)
            #expect(
                abs(
                    (left ? editor.frame.maxX : editor.frame.minX)
                        - (left ? initialFrame.maxX : initialFrame.minX)) < 0.001)
            #expect(session.document == before && canvas.draftDocument == before)
            let resizedFrame = editor.frame
            canvas.undo(nil)
            #expect(abs(editor.frame.width - initialFrame.width) < 0.001)
            #expect(editor.superview === canvas && editor.string == mark.text)
            #expect(canvas.undoManager?.canUndo == false)
            canvas.redo(nil)
            #expect(editor.frame == resizedFrame)
            #expect(canvas.finishTextEditing())
            #expect(
                abs(session.document.annotations[0].bounds.width - 190) < 0.001,
                "A width-only edit must save even when the string has not changed")
            #expect(session.document.annotations[0].size == mark.size)
            session.history.undo()
            #expect(session.document == before)
        }
    }

    @Test func inlineWidthDragDoesNotCommitJapaneseCompositionToDocumentOrDraft() throws {
        let (session, canvas, mark) = try fixture()
        let before = session.document
        let editor = try beginEditing(canvas, mark: mark)
        editor.setMarkedText(
            "にほんごのへんかんちゅう", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: 0, length: (mark.text as NSString).length))
        let candidate = editor.string
        let markedRange = editor.markedRange()
        let center = TextSelectionChrome(editorFrame: editor.frame).sideCenters[1]
        let start = CGPoint(x: center.x + 5, y: center.y)
        let end = CGPoint(x: start.x - 100, y: start.y)
        canvas.mouseDown(with: try event(.leftMouseDown, at: start, on: canvas))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: end, on: canvas))
        canvas.mouseUp(with: try event(.leftMouseUp, at: end, on: canvas))
        #expect(editor.superview === canvas && editor.hasMarkedText())
        #expect(editor.string == candidate && editor.markedRange() == markedRange)
        #expect(session.document == before && canvas.draftDocument == before)
        #expect(!canvas.finishTextEditing())
        editor.unmarkText()
        #expect(canvas.finishTextEditing())
        #expect(session.document.annotations[0].text == candidate)
        #expect(abs(session.document.annotations[0].bounds.width - 220) < 0.001)
        session.history.undo()
        #expect(session.document == before)
    }

    @Test func visibleWidthGripsStayUsableAtEveryZoomRotationAndMirror() throws {
        let (_, canvas, original) = try fixture()
        for zoom: CGFloat in [0.1, 0.5, 1, 4] {
            for turn in 0..<4 {
                for mirror in [false, true] {
                    var mark = original
                    mark.quarterTurns = turn
                    mark.mirrored = mirror
                    let mapping = CanvasTransform(
                        canvas: canvas.session.document.canvas, zoom: zoom,
                        origin: CGPoint(x: 48, y: 48))
                    let chrome = TextSelectionChrome(mark: mark, mapping: mapping)
                    for index in 0..<2 {
                        let center = chrome.sideCenters[index]
                        let direction = chrome.sideDirections[index]
                        let rim = CGPoint(x: center.x + direction.x * 7, y: center.y + direction.y * 7)
                        #expect(chrome.widthHandle(at: rim) == index + 4)
                        #expect(chrome.widthHitRects[index].contains(rim))
                        #expect(
                            abs(chrome.widthHitRects[index].width * chrome.widthHitRects[index].height - 418) < 0.01)
                    }
                }
            }
        }
    }

    @Test func tinyZoomKeepsCornerScalingSeparateFromWidthAndTextInput() throws {
        let (session, canvas, mark) = try fixture(zoom: 0.05)
        let chrome = TextSelectionChrome(mark: mark, mapping: canvas.transform)
        let corner = chrome.cornerCenters[2]
        let end = CGPoint(
            x: corner.x + mark.bounds.width * session.zoom,
            y: corner.y + mark.bounds.height * session.zoom)
        canvas.mouseDown(with: try event(.leftMouseDown, at: corner, on: canvas))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: end, on: canvas))
        canvas.mouseUp(with: try event(.leftMouseUp, at: end, on: canvas))
        #expect(
            abs(session.document.annotations[0].size - mark.size * 2) < 0.001,
            "Even at tiny zoom a visible corner must scale the font, not wrap the text")
        session.history.undo()
        var narrow = mark
        narrow.points[1].x = narrow.points[0].x + 12
        narrow.size = 1
        narrow.text = "a"
        session.document.annotations = [narrow]
        let point = canvas.transform.viewPoint(CGPoint(x: narrow.bounds.midX, y: narrow.bounds.midY))
        canvas.mouseDown(with: try event(.leftMouseDown, at: point, on: canvas, clicks: 2))
        let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        let inputPoint = CGPoint(x: editor.frame.midX, y: editor.frame.midY)
        #expect(
            canvas.hitTest(canvas.convert(inputPoint, to: canvas.superview)) === editor,
            "Outside width grips must leave native text input clickable at minimum width")
        #expect(canvas.finishTextEditing())
    }

    @Test func oversizedTextStaysEditableInsteadOfLosingThePreviousDocument() throws {
        let (session, canvas, mark) = try fixture()
        let before = session.document
        let editor = try beginEditing(canvas, mark: mark)
        editor.string = String(repeating: "日本語\n", count: 3000)
        #expect(!canvas.finishTextEditing())
        #expect(editor.superview === canvas && canvas.isEditingText)
        #expect(session.document == before && canvas.draftDocument == before)
        #expect(editor.string.hasPrefix("日本語\n日本語"))
        editor.string = mark.text
        #expect(canvas.finishTextEditing())
        #expect(session.document == before)
    }
}
