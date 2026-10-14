import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Skitchish

@MainActor
struct StampInteractionTests {
    private func fixture(_ annotations: [Markup] = []) throws -> EditorDocument {
        let context = try #require(
            CGContext(
                data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        var document = EditorDocument(imageData: data as Data, imageSize: CGSize(width: 600, height: 400))
        document.annotations = annotations
        return document
    }

    private func withDefaultsRestored(_ action: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["editor.tool", "editor.size", "editor.color", "editor.stamp", "editor.stampTail"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        try action()
    }

    private func canvas(_ document: EditorDocument, tool: EditorTool = .stamp) -> CanvasView {
        let session = EditorSession(document: document)
        session.tool = tool
        session.sizeIndex = 2
        session.zoom = 0.75
        let canvas = CanvasView(session: session, renderer: EditorRenderer())
        canvas.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        return canvas
    }

    private func event(
        _ type: NSEvent.EventType, at point: CGPoint, in canvas: CanvasView,
        flags: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) throws -> NSEvent {
        try TestEvent.mouse(
            type, atWindowPoint: canvas.convert(canvas.transform.viewPoint(point), to: nil), modifiers: flags,
            clicks: clickCount)
    }

    private func click(_ point: CGPoint, in canvas: CanvasView, flags: NSEvent.ModifierFlags = []) throws {
        canvas.mouseDown(with: try event(.leftMouseDown, at: point, in: canvas, flags: flags))
        canvas.mouseUp(with: try event(.leftMouseUp, at: point, in: canvas, flags: flags))
    }

    private func doubleClick(_ point: CGPoint, in canvas: CanvasView) throws {
        try click(point, in: canvas)
        canvas.mouseDown(with: try event(.leftMouseDown, at: point, in: canvas, clickCount: 2))
        canvas.mouseUp(with: try event(.leftMouseUp, at: point, in: canvas, clickCount: 2))
    }

    private func editingFrame(for mark: Markup, in canvas: CanvasView) -> CGRect {
        let local = TextAnnotationGeometry.stampEditingRect(mark)
        let center = canvas.transform.viewPoint(
            TextAnnotationGeometry.worldPoint(CGPoint(x: local.midX, y: local.midY), in: mark))
        let size = CGSize(width: local.width * canvas.session.zoom, height: local.height * canvas.session.zoom)
        return CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func stamp(text: String = "", center: CGPoint = CGPoint(x: 300, y: 200)) -> Markup {
        Markup(
            tool: .stamp,
            points: [
                CGPoint(x: center.x - 21, y: center.y - 21),
                CGPoint(x: center.x + 21, y: center.y + 21),
            ], size: 6, text: text, stamp: 2)
    }

    @Test func newStampClickCentersCircleAndNeverAddsDefaultTail() throws {
        try withDefaultsRestored {
            let document = try fixture()
            let canvas = canvas(document)
            canvas.session.stamp = 3
            UserDefaults.standard.set(true, forKey: "editor.stampTail")  // A legacy preference must not add a tail.
            let point = CGPoint(x: 250, y: 170)
            try click(point, in: canvas)
            #expect(!canvas.isEditingText)
            #expect(canvas.finishTextEditing())  // Flush the single-click undo boundary if pending.
            let created = try #require(canvas.session.document.annotations.first)
            #expect(canvas.session.document.annotations.count == 1)
            #expect(created.stamp == 3 && !created.tail && created.text.isEmpty)
            #expect(abs(created.stampCircleBounds.midX - point.x) < 0.001)
            #expect(abs(created.stampCircleBounds.midY - point.y) < 0.001)
            #expect(created.stampCircleBounds.size == CGSize(width: 60, height: 60))
            let final = canvas.session.document
            canvas.undo(nil)
            #expect(canvas.session.document == document && !canvas.session.history.canUndo)
            canvas.redo(nil)
            #expect(canvas.session.document == final)
        }
    }

    @Test func newStampControlsAppearOnlyAfterAnExplicitSelection() throws {
        try withDefaultsRestored {
            for addsPointer in [false, true] {
                let previous = stamp(center: CGPoint(x: 90, y: 90))
                let document = try fixture([previous])
                let canvas = canvas(document)
                canvas.session.stamp = 1
                canvas.session.selection = [previous.id]
                let center = CGPoint(x: 300, y: 230)
                canvas.mouseDown(with: try event(.leftMouseDown, at: center, in: canvas))
                #expect(canvas.session.selection.isEmpty, "Placing a new stamp clears the previous controls")
                #expect(!canvas.isEditingText && canvas.draftDocument == document)
                var endpoint = center
                if addsPointer {
                    for distance: CGFloat in [20, 40, 80] {
                        endpoint = CGPoint(x: center.x + distance, y: center.y)
                        canvas.mouseDragged(with: try event(.leftMouseDragged, at: endpoint, in: canvas))
                        #expect(canvas.session.selection.isEmpty, "Pointer creation must not reveal selection controls")
                    }
                }
                canvas.mouseUp(with: try event(.leftMouseUp, at: endpoint, in: canvas))
                #expect(canvas.session.selection.isEmpty && !canvas.isEditingText)
                #expect(canvas.finishTextEditing())
                #expect(canvas.session.selection.isEmpty, "Committing placement must not select the new stamp")
                let created = try #require(canvas.session.document.annotations.last)
                #expect(created.id != previous.id && created.text.isEmpty && created.tail == addsPointer)
                let placed = canvas.session.document

                try click(center, in: canvas)
                #expect(canvas.session.selection == [created.id] && !canvas.isEditingText)
                #expect(canvas.session.document == placed)
                let chrome = StampSelectionChrome(mark: created, mapping: canvas.transform)
                let tab = try #require(chrome.labelButtonRect)
                try click(canvas.transform.imagePoint(CGPoint(x: tab.midX, y: tab.midY)), in: canvas)
                let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
                #expect(editor.string == "Rejected" && editor.selectedRange() == NSRange(location: 0, length: 8))
                #expect(canvas.draftDocument == placed)
                editor.insertText("Review", replacementRange: editor.selectedRange())
                #expect(canvas.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
                #expect(canvas.session.selection.isEmpty)
                #expect(canvas.session.document.annotations.last?.text == "Review")
                canvas.undo(nil)
                #expect(canvas.session.document == placed)
                canvas.undo(nil)
                #expect(canvas.session.document == document && !canvas.session.history.canUndo)
            }
        }
    }

    @Test func unselectedNewStampStillExpandsCanvasAtTheImageEdge() throws {
        try withDefaultsRestored {
            for addsPointer in [false, true] {
                let document = try fixture()
                let canvas = canvas(document)
                let center = CGPoint(x: 5, y: 5)
                canvas.mouseDown(with: try event(.leftMouseDown, at: center, in: canvas))
                #expect(canvas.session.selection.isEmpty)
                let endpoint = addsPointer ? CGPoint(x: -75, y: -75) : center
                if addsPointer {
                    canvas.mouseDragged(with: try event(.leftMouseDragged, at: endpoint, in: canvas))
                    #expect(canvas.session.selection.isEmpty)
                }
                canvas.mouseUp(with: try event(.leftMouseUp, at: endpoint, in: canvas))
                #expect(canvas.finishTextEditing())
                let created = try #require(canvas.session.document.annotations.first)
                #expect(canvas.session.selection.isEmpty && created.tail == addsPointer)
                #expect(canvas.session.document.canvas.contains(created.visualBounds))
                #expect(canvas.session.document.canvas.minX < 0 && canvas.session.document.canvas.minY < 0)
                canvas.undo(nil)
                #expect(canvas.session.document == document && !canvas.session.history.canUndo)
            }
        }
    }

    @Test func newStampDiameterIsIndependentOfAnnotationWidthAndZoom() throws {
        try withDefaultsRestored {
            let document = try fixture()
            let center = CGPoint(x: 300, y: 200)
            for sizeIndex in EditorSession.widths.indices {
                for zoom: CGFloat in [0.5, 1, 2] {
                    let canvas = canvas(document)
                    canvas.session.sizeIndex = sizeIndex
                    canvas.session.zoom = zoom
                    try click(center, in: canvas)
                    #expect(canvas.finishTextEditing())
                    let created = try #require(canvas.session.document.annotations.first)
                    #expect(
                        created.stampCircleBounds == CGRect(x: 270, y: 170, width: 60, height: 60),
                        "New stamps start at 60 image pixels regardless of the previous annotation width or zoom")
                    #expect(canvas.session.sizeIndex == sizeIndex)
                    #expect(canvas.session.document.canvas == document.canvas)
                    #expect(!created.tail && created.text.isEmpty)
                }
            }
        }
    }

    @Test func newStampDragChoosesEightTailDirectionsWithoutResizingCircle() throws {
        try withDefaultsRestored {
            for direction in 0..<8 {
                let document = try fixture()
                let canvas = canvas(document)
                let center = CGPoint(x: 300, y: 200)
                let angle = CGFloat(direction) * .pi / 4
                canvas.mouseDown(with: try event(.leftMouseDown, at: center, in: canvas))
                let initial = try #require(canvas.session.document.annotations.first)
                #expect(initial.stampCircleBounds == CGRect(x: 270, y: 170, width: 60, height: 60))
                var endpoint = center
                for distance: CGFloat in [20, 40, 60, 80] {
                    endpoint = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                    canvas.mouseDragged(with: try event(.leftMouseDragged, at: endpoint, in: canvas))
                    #expect(canvas.session.document.annotations[0].points == initial.points)
                }
                #expect(canvas.draftDocument == document)
                canvas.mouseUp(with: try event(.leftMouseUp, at: endpoint, in: canvas))
                let created = try #require(canvas.session.document.annotations.first)
                #expect(created.tail && created.tailDirection == direction)
                #expect(created.points == initial.points && created.size == initial.size)
                #expect(!canvas.isEditingText)
                let final = canvas.session.document
                canvas.undo(nil)
                #expect(canvas.session.document == document && !canvas.session.history.canUndo)
                canvas.redo(nil)
                #expect(canvas.session.document == final)
            }
        }
    }

    @Test func existingStampDoubleClickEditsLeftLabelAndOutsideClickCommitsWithoutChangingCircle() throws {
        try withDefaultsRestored {
            for tool in [EditorTool.stamp, .select] {
                var mark = stamp()
                mark.tail = true
                mark.tailDirection = 7
                let document = try fixture([mark])
                let canvas = canvas(document, tool: tool)
                try doubleClick(CGPoint(x: 300, y: 200), in: canvas)
                #expect(canvas.isEditingText)
                let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
                editor.string = "日本語 Review this"
                try click(CGPoint(x: 520, y: 340), in: canvas)
                #expect(!canvas.isEditingText && canvas.session.tool == tool && canvas.session.selection.isEmpty)
                let updated = try #require(canvas.session.document.annotations.first)
                #expect(updated.text == "日本語 Review this")
                #expect(updated.points == mark.points && updated.size == mark.size)
                #expect(updated.tail == mark.tail && updated.tailDirection == mark.tailDirection)
                #expect(updated.stampLabelBounds.maxX < updated.stampCircleBounds.minX)
                let final = canvas.session.document
                canvas.undo(nil)
                #expect(canvas.session.document == document && !canvas.session.history.canUndo)
                canvas.redo(nil)
                #expect(canvas.session.document == final)
            }
        }
    }

    @Test func singleClicksOnStampOrLabelOnlySelectWithoutEditingOrChangingTheDocument() throws {
        try withDefaultsRestored {
            for tool in [EditorTool.stamp, .select, .arrow] {
                for text in ["", "Review"] {
                    let mark = stamp(text: text)
                    let document = try fixture([mark])
                    let canvas = canvas(document, tool: tool)
                    var points = [CGPoint(x: mark.bounds.midX, y: mark.bounds.midY)]
                    if !mark.stampLabelBounds.isNull {
                        points.append(CGPoint(x: mark.stampLabelBounds.midX, y: mark.stampLabelBounds.midY))
                    }
                    for point in points {
                        for _ in 0..<2 {
                            try click(point, in: canvas)
                            #expect(canvas.session.selection == [mark.id])
                            #expect(!canvas.isEditingText)
                            #expect(canvas.session.document == document && canvas.draftDocument == document)
                            #expect(!canvas.session.history.canUndo)
                        }
                    }
                }
            }
        }
    }

    @Test func doubleClickExistingLabelSelectsAllAndEnterCommitsThenDeselects() throws {
        try withDefaultsRestored {
            let mark = stamp(text: "Original")
            let document = try fixture([mark])
            let canvas = canvas(document)
            try doubleClick(CGPoint(x: mark.stampLabelBounds.midX, y: mark.stampLabelBounds.midY), in: canvas)
            let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
            #expect(editor.selectedRange() == NSRange(location: 0, length: (mark.text as NSString).length))
            editor.insertText("Revised", replacementRange: editor.selectedRange())
            #expect(canvas.draftDocument == document && canvas.session.document == document)
            #expect(canvas.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            #expect(!canvas.isEditingText && canvas.session.selection.isEmpty)
            #expect(canvas.session.document.annotations[0].text == "Revised")
            #expect(canvas.session.document.annotations[0].points == mark.points)
            canvas.undo(nil)
            #expect(canvas.session.document == document && !canvas.session.history.canUndo)
        }
    }

    @Test func labelTabStartsSelectedDefaultTextWithoutSavingItBeforeCommit() throws {
        try withDefaultsRestored {
            let titles = ["Approved", "Rejected", "Question", "Attention", "Perfect"]
            for kind in titles.indices {
                var mark = stamp()
                mark.stamp = kind
                let document = try fixture([mark])
                let canvas = canvas(document)
                try click(CGPoint(x: mark.bounds.midX, y: mark.bounds.midY), in: canvas)
                let chrome = StampSelectionChrome(mark: mark, mapping: canvas.transform)
                let tab = try #require(chrome.labelButtonRect)
                let point = canvas.transform.imagePoint(CGPoint(x: tab.midX, y: tab.midY))
                try click(point, in: canvas)
                let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
                #expect(editor.string == titles[kind])
                #expect(editor.selectedRange() == NSRange(location: 0, length: (titles[kind] as NSString).length))
                #expect(canvas.session.document == document && canvas.draftDocument == document)
                #expect(!canvas.session.history.canUndo)
                #expect(canvas.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
                #expect(!canvas.isEditingText && canvas.session.selection.isEmpty)
                #expect(canvas.session.document.annotations[0].text == titles[kind])
                #expect(canvas.session.document.annotations[0].points == mark.points)
                canvas.undo(nil)
                #expect(canvas.session.document == document && !canvas.session.history.canUndo)
            }
        }
    }

    @Test func removeLabelControlDeletesOnlyTheLabelAndCanBeUndone() throws {
        try withDefaultsRestored {
            var mark = stamp(text: "Keep the marker")
            mark.tail = true
            mark.tailDirection = 3
            let document = try fixture([mark])
            let canvas = canvas(document)
            try click(CGPoint(x: mark.bounds.midX, y: mark.bounds.midY), in: canvas)
            let chrome = StampSelectionChrome(mark: mark, mapping: canvas.transform)
            let remove = try #require(chrome.removeLabelCenter)
            try click(canvas.transform.imagePoint(remove), in: canvas)
            var unlabeled = mark
            unlabeled.text = ""
            #expect(canvas.session.document.annotations == [unlabeled])
            #expect(!canvas.isEditingText && canvas.session.selection == [mark.id])
            let final = canvas.session.document
            canvas.undo(nil)
            #expect(canvas.session.document == document && !canvas.session.history.canUndo)
            canvas.redo(nil)
            #expect(canvas.session.document == final)
        }
    }

    @Test func newStampDoubleClickPreservesStampAndEditsItsDefaultLabelWithSeparateUndo() throws {
        try withDefaultsRestored {
            let document = try fixture()
            let canvas = canvas(document)
            canvas.session.stamp = 1
            let point = CGPoint(x: 300, y: 200)
            try click(point, in: canvas)
            #expect(canvas.session.selection.isEmpty && !canvas.isEditingText)
            let placedID = try #require(canvas.session.document.annotations.first?.id)
            canvas.mouseDown(with: try event(.leftMouseDown, at: point, in: canvas, clickCount: 2))
            canvas.mouseUp(with: try event(.leftMouseUp, at: point, in: canvas, clickCount: 2))
            let created = try #require(canvas.session.document.annotations.first)
            let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
            #expect(canvas.session.document.annotations.count == 1 && created.tool == .stamp)
            #expect(created.id == placedID && canvas.session.selection == [placedID])
            #expect(created.text.isEmpty && !created.tail && created.stamp == 1)
            #expect(editor.string == "Rejected" && editor.selectedRange() == NSRange(location: 0, length: 8))
            #expect(canvas.draftDocument.annotations == [created])
            editor.insertText("Needs revision", replacementRange: editor.selectedRange())
            #expect(canvas.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            #expect(!canvas.isEditingText && canvas.session.selection.isEmpty)
            #expect(canvas.session.document.annotations[0].text == "Needs revision")
            #expect(canvas.session.document.annotations[0].id == created.id)
            canvas.undo(nil)
            #expect(canvas.session.document.annotations == [created])
            canvas.undo(nil)
            #expect(canvas.session.document == document && !canvas.session.history.canUndo)
        }
    }

    @Test func stampEditorMinimumWidthKeepsCircleFacingEdgeAndDoesNotEnlargeSavedLabel() {
        for diameter: CGFloat in [30, 60, 120] {
            for text in ["", "OK", "A sufficiently long review label that exceeds the input minimum"] {
                var mark = stamp(text: text)
                mark.points = [.zero, CGPoint(x: diameter, y: diameter)]
                let input = TextAnnotationGeometry.stampEditingRect(mark)
                var preview = mark
                if preview.text.isEmpty { preview.text = " " }
                let plate = preview.stampLocalLabelBounds.offsetBy(dx: diameter / 2, dy: diameter / 2)
                #expect(abs(input.width - max(plate.width, diameter * 190 / 60)) < 0.001)
                #expect(abs(input.maxX - plate.maxX) < 0.001)
                #expect(input.minY == plate.minY && input.height == plate.height)
                #expect(mark.text == text)
                if text.isEmpty { #expect(mark.stampLabelBounds.isNull) }
            }
        }
    }

    @Test func unchangedStampLabelAndMarkedJapaneseCompositionDoNotCreatePrematureDocumentChanges() throws {
        try withDefaultsRestored {
            let mark = stamp(text: "Original")
            let document = try fixture([mark])
            let canvas = canvas(document)
            try doubleClick(CGPoint(x: 300, y: 200), in: canvas)
            #expect(canvas.finishTextEditing())
            #expect(canvas.session.document == document && !canvas.session.history.canUndo)
            try doubleClick(CGPoint(x: 300, y: 200), in: canvas)
            let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
            editor.setMarkedText(
                "にほん", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: 0, length: 8)
            )
            try click(CGPoint(x: 520, y: 340), in: canvas)
            #expect(canvas.isEditingText && editor.hasMarkedText())
            #expect(canvas.draftDocument == document && canvas.session.document == document)
            #expect(!canvas.session.history.canUndo)
            editor.unmarkText()
            try click(CGPoint(x: 520, y: 340), in: canvas)
            #expect(!canvas.isEditingText)
            #expect(canvas.session.document.annotations[0].text == "にほん")
            #expect(canvas.session.document.annotations[0].points == mark.points)
            canvas.undo(nil)
            #expect(canvas.session.document == document)
        }
    }

    @Test func inlineStampLabelsStayWhiteAndMatchEditingPlateForEveryStampAndPaletteColor() throws {
        try withDefaultsRestored {
            func expectWhite(_ color: NSColor?) throws {
                let rgb = try #require(color?.usingColorSpace(.deviceRGB))
                #expect(
                    abs(rgb.redComponent - 1) < 0.001 && abs(rgb.greenComponent - 1) < 0.001
                        && abs(rgb.blueComponent - 1) < 0.001 && abs(rgb.alphaComponent - 1) < 0.001)
            }
            func expectFrame(_ actual: CGRect, _ expected: CGRect) {
                #expect(abs(actual.minX - expected.minX) < 0.001)
                #expect(abs(actual.minY - expected.minY) < 0.001)
                #expect(abs(actual.width - expected.width) < 0.001)
                #expect(abs(actual.height - expected.height) < 0.001)
            }
            for kind in 0..<5 {
                for colorIndex in RGBA.palette.indices {
                    var mark = stamp(text: "Review 日本語")
                    mark.stamp = kind
                    mark.color = RGBA.palette[colorIndex]
                    let document = try fixture([mark])
                    let canvas = canvas(document)
                    canvas.session.colorIndex = colorIndex
                    try doubleClick(CGPoint(x: 300, y: 200), in: canvas)
                    let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
                    try expectWhite(editor.textColor)
                    try expectWhite(editor.insertionPointColor)
                    try expectWhite(editor.typingAttributes[.foregroundColor] as? NSColor)
                    let storage = try #require(editor.textStorage)
                    try expectWhite(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                    #expect(
                        editor.typingAttributes[.strokeColor] == nil && editor.typingAttributes[.strokeWidth] == nil)
                    #expect(storage.attribute(.strokeColor, at: 0, effectiveRange: nil) == nil)
                    #expect(storage.attribute(.strokeWidth, at: 0, effectiveRange: nil) == nil)
                    #expect(!editor.isRichText && editor.allowsUndo)
                    let expectedFrame = editingFrame(for: mark, in: canvas)
                    expectFrame(editor.frame, expectedFrame)
                    #expect(editor.frame.maxX < canvas.transform.viewRect(mark.stampCircleBounds).minX)
                    let style = StampLabelStyle(diameter: mark.stampLocalCircleBounds.width)
                    #expect(abs(editor.textContainerInset.width - style.paddingX * canvas.session.zoom) < 0.001)
                    #expect(abs(editor.textContainerInset.height - style.paddingY * canvas.session.zoom) < 0.001)

                    editor.string += "\n次の行"
                    canvas.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
                    var updated = mark
                    updated.text = editor.string
                    expectFrame(editor.frame, editingFrame(for: updated, in: canvas))
                    #expect(editor.frame.height > expectedFrame.height)
                    #expect(
                        canvas.draftDocument == document, "Typing and multiline layout must not save a partial label")
                    #expect(canvas.finishTextEditing())
                    let committed = try #require(canvas.session.document.annotations.first)
                    #expect(committed.text == "Review 日本語\n次の行")
                    #expect(
                        committed.points == mark.points && committed.size == mark.size && committed.stamp == mark.stamp)
                    canvas.undo(nil)
                    #expect(canvas.session.document == document && !canvas.session.history.canUndo)
                }
            }
        }
    }

    @Test func pointerHandleChangesTailWhileBodyDragMovesWholeStamp() throws {
        try withDefaultsRestored {
            let mark = stamp(text: "Label")
            let document = try fixture([mark])
            let canvas = canvas(document)
            let center = CGPoint(x: 300, y: 200)
            let endpoint = CGPoint(x: 380, y: 200)
            try click(center, in: canvas)
            let chrome = StampSelectionChrome(mark: mark, mapping: canvas.transform)
            let pointer = canvas.transform.imagePoint(chrome.pointerCenter)
            canvas.mouseDown(with: try event(.leftMouseDown, at: pointer, in: canvas))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: endpoint, in: canvas))
            canvas.mouseUp(with: try event(.leftMouseUp, at: endpoint, in: canvas))
            let tailed = canvas.session.document
            #expect(tailed.annotations[0].points == mark.points && tailed.annotations[0].text == mark.text)
            #expect(tailed.annotations[0].tail && tailed.annotations[0].tailDirection == 0)
            #expect(!canvas.isEditingText)
            canvas.undo(nil)
            #expect(canvas.session.document == document)
            canvas.redo(nil)
            #expect(canvas.session.document == tailed)
            canvas.session.tool = .select
            let movedPoint = CGPoint(x: center.x + 40, y: center.y + 20)
            canvas.mouseDown(with: try event(.leftMouseDown, at: center, in: canvas))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: movedPoint, in: canvas))
            canvas.mouseUp(with: try event(.leftMouseUp, at: movedPoint, in: canvas))
            #expect(canvas.session.document.annotations[0] == tailed.annotations[0].translated(dx: 40, dy: 20))
            #expect(!canvas.isEditingText)
            canvas.undo(nil)
            #expect(canvas.session.document == tailed)
            canvas.undo(nil)
            #expect(canvas.session.document == document && !canvas.session.history.canUndo)
        }
    }

    @Test func shiftClickTogglesStampMultiSelectionWithoutEditingLabelsOrAddingTails() throws {
        try withDefaultsRestored {
            let first = stamp(center: CGPoint(x: 200, y: 180))
            let second = stamp(center: CGPoint(x: 400, y: 180))
            let document = try fixture([first, second])
            let canvas = canvas(document)
            canvas.session.selection = [first.id]
            try click(CGPoint(x: 400, y: 180), in: canvas, flags: .shift)
            #expect(canvas.session.selection == [first.id, second.id])
            #expect(!canvas.isEditingText && canvas.session.document == document)
            try click(CGPoint(x: 200, y: 180), in: canvas, flags: .shift)
            #expect(canvas.session.selection == [second.id])
            #expect(!canvas.isEditingText && !canvas.session.history.canUndo)
        }
    }

    @Test func stampMoveKeepsTrackingAfterCrossingDragThresholdAndReturningNearStart() throws {
        try withDefaultsRestored {
            let mark = stamp(text: "Keep moving")
            let document = try fixture([mark])
            let canvas = canvas(document, tool: .select)
            let start = CGPoint(x: 300, y: 200)
            canvas.mouseDown(with: try event(.leftMouseDown, at: start, in: canvas))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 310, y: 200), in: canvas))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 302, y: 200), in: canvas))
            canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 302, y: 200), in: canvas))
            #expect(canvas.session.document.annotations[0] == mark.translated(dx: 2, dy: 0))
            #expect(!canvas.isEditingText)
            let final = canvas.session.document
            canvas.undo(nil)
            #expect(canvas.session.document == document && !canvas.session.history.canUndo)
            canvas.redo(nil)
            #expect(canvas.session.document == final)
        }
    }

    @Test func pointerDragTracksWorldDirectionForRotatedAndMirroredStamp() throws {
        try withDefaultsRestored {
            for mirrored in [false, true] {
                for turns in 0..<4 {
                    var document = try fixture([stamp(text: "Label")])
                    if mirrored { document.flip(horizontal: true) }
                    for _ in 0..<turns { document.rotateClockwise() }
                    let mark = document.annotations[0]
                    let canvas = canvas(document)
                    let center = CGPoint(x: mark.stampCircleBounds.midX, y: mark.stampCircleBounds.midY)
                    let endpoint = CGPoint(x: center.x + 80, y: center.y)
                    try click(center, in: canvas)
                    let chrome = StampSelectionChrome(mark: mark, mapping: canvas.transform)
                    let pointer = canvas.transform.imagePoint(chrome.pointerCenter)
                    canvas.mouseDown(with: try event(.leftMouseDown, at: pointer, in: canvas))
                    canvas.mouseDragged(with: try event(.leftMouseDragged, at: endpoint, in: canvas))
                    canvas.mouseUp(with: try event(.leftMouseUp, at: endpoint, in: canvas))
                    let updated = canvas.session.document.annotations[0]
                    let tip = try #require(updated.stampTailTip)
                    #expect(tip.x > center.x && abs(tip.y - center.y) < 0.001)
                    #expect(
                        updated.points == mark.points && updated.quarterTurns == mark.quarterTurns
                            && updated.mirrored == mark.mirrored)
                    #expect(updated.text == mark.text)
                    canvas.undo(nil)
                    #expect(canvas.session.document == document && !canvas.session.history.canUndo)
                }
            }
        }
    }
}
