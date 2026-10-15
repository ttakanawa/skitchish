import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Skitchish

@MainActor
struct EditorInteractionTests {
    private let preferences = TestPreferences()

    private func fixture(width: Int = 400, height: Int = 300) throws -> EditorDocument {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return EditorDocument(imageData: data as Data, imageSize: CGSize(width: width, height: height))
    }

    @Test func coordinateMappingIsIndependentOfZoomWindowAndNegativeCanvasOrigin() throws {
        let document = try fixture()
        for canvas in [document.canvas, CGRect(x: -60, y: -40, width: 800, height: 600)] {
            for zoom: CGFloat in [0.1, 0.5, 1, 2, 4] {
                for origin in [CGPoint(x: 48, y: 48), CGPoint(x: 400, y: 230)] {
                    let mapping = CanvasTransform(canvas: canvas, zoom: zoom, origin: origin)
                    for point in [canvas.origin, CGPoint(x: 123.5, y: 84.25), CGPoint(x: canvas.maxX, y: canvas.maxY)] {
                        let restored = mapping.imagePoint(mapping.viewPoint(point))
                        #expect(abs(restored.x - point.x) < 0.000_001)
                        #expect(abs(restored.y - point.y) < 0.000_001)
                    }
                    #expect(
                        mapping.viewRect(canvas).size
                            == CGSize(width: canvas.width * zoom, height: canvas.height * zoom))
                }
            }
        }
        #expect(document.outputSize == CGSize(width: 400, height: 300))
    }

    @Test func manyGestureUpdatesProduceOneUndoAndRedo() throws {
        let session = preferences.session(document: try fixture())
        let before = session.document
        var commits = 0
        session.onCommit = { commits += 1 }
        let mark = Markup(tool: .arrow, points: [CGPoint(x: 20, y: 20), CGPoint(x: 50, y: 50)])
        session.document.annotations.append(mark)
        for i in 0..<40 { session.document.annotations[0].points[1] = CGPoint(x: 100 + i, y: 150) }
        session.commit(from: before, name: "Draw Annotation")
        let drawn = session.document
        #expect(commits == 1)
        #expect(session.history.undoActionName == "Draw Annotation")
        session.history.undo()
        #expect(session.document == before)
        #expect(!session.history.canUndo)
        #expect(session.history.canRedo)
        session.history.redo()
        #expect(session.document == drawn)
        #expect(commits == 3)
    }

    @Test func arrowAndLineSelectionFollowSilhouetteWithVisibleEndpointHandles() throws {
        for tool: EditorTool in [.arrow, .line] {
            for zoom: CGFloat in [0.5, 1, 2] {
                var document = try fixture()
                let mark = Markup(tool: tool, points: [CGPoint(x: 50, y: 60), CGPoint(x: 260, y: 180)], size: 6)
                document.annotations = [mark]
                let session = preferences.session(document: document)
                session.tool = .select
                session.zoom = zoom
                let canvas = CanvasView(session: session, renderer: EditorRenderer())
                canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
                let mapping = canvas.transform
                func snapshot(selected: Bool, clippedTo rect: CGRect) throws -> Data {
                    session.selection = selected ? [mark.id] : []
                    let context = try #require(
                        CGContext(
                            data: nil, width: 800, height: 600, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.translateBy(x: 0, y: 600)
                    context.scaleBy(x: 1, y: -1)
                    context.clip(to: rect)
                    NSGraphicsContext.saveGraphicsState()
                    defer { NSGraphicsContext.restoreGraphicsState() }
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    canvas.draw(canvas.bounds)
                    return try #require(context.makeImage()?.dataProvider?.data) as Data
                }
                let box = mapping.viewRect(mark.bounds).insetBy(dx: -3, dy: -3)
                let emptyTop = CGRect(x: box.midX - 15, y: box.minY - 2, width: 30, height: 4)
                let emptyLeft = CGRect(x: box.minX - 2, y: box.midY - 15, width: 4, height: 30)
                for region in [emptyTop, emptyLeft] {
                    #expect(
                        try snapshot(selected: true, clippedTo: region) == snapshot(selected: false, clippedTo: region),
                        "A single \(tool.rawValue) has no rectangular selection border at zoom \(zoom)")
                }
                for point in mark.points {
                    let p = mapping.viewPoint(point)
                    let handle = CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)
                    #expect(
                        try snapshot(selected: true, clippedTo: handle) != snapshot(selected: false, clippedTo: handle),
                        "Both endpoints remain visible at zoom \(zoom)")
                }
                let middle = CGRect(x: box.midX - 12, y: box.minY + 8, width: 24, height: box.height - 16)
                #expect(
                    try snapshot(selected: true, clippedTo: middle) != snapshot(selected: false, clippedTo: middle),
                    "The selection traces the \(tool.rawValue) silhouette between its handles")
            }
        }
    }

    @Test func arrowAndLineEndpointsResizeIndependentlyWithOneUndo() throws {
        for tool: EditorTool in [.arrow, .line] {
            for endpoint in 0..<2 {
                var document = try fixture()
                let mark = Markup(tool: tool, points: [CGPoint(x: 60, y: 80), CGPoint(x: 230, y: 160)], size: 6)
                document.annotations = [mark]
                let session = preferences.session(document: document)
                session.tool = .select
                session.selection = [mark.id]
                session.zoom = 0.75
                let canvas = CanvasView(session: session, renderer: EditorRenderer())
                canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
                let mapping = canvas.transform
                func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
                    let location = canvas.convert(mapping.viewPoint(point), to: nil)
                    return try TestEvent.mouse(type, atWindowPoint: location)
                }
                let destination = CGPoint(x: mark.points[endpoint].x + 25, y: mark.points[endpoint].y + 35)
                canvas.mouseDown(with: try event(.leftMouseDown, at: mark.points[endpoint]))
                for fraction: CGFloat in [0.25, 0.5, 0.75, 1] {
                    let point = CGPoint(
                        x: mark.points[endpoint].x + 25 * fraction, y: mark.points[endpoint].y + 35 * fraction)
                    canvas.mouseDragged(with: try event(.leftMouseDragged, at: point))
                    #expect(canvas.draftDocument == document)
                }
                canvas.mouseUp(with: try event(.leftMouseUp, at: destination))
                let resized = session.document
                #expect(resized.annotations[0].points[endpoint] == destination)
                #expect(resized.annotations[0].points[1 - endpoint] == mark.points[1 - endpoint])
                #expect(resized.annotations[0].size == mark.size)
                #expect(session.history.undoActionName == "Resize Annotations")
                session.history.undo()
                #expect(session.document == document && !session.history.canUndo)
                session.history.redo()
                #expect(session.document == resized)
            }
        }
    }

    @Test func blankDoubleClickStartsTextForNonStampToolsWithoutStrayMarksOrUndoEntries() throws {
        // The stamp tool keeps its first-click marker and edits its label instead;
        // StampInteractionTests covers that separate creation/label undo boundary.
        for tool in EditorTool.allCases where tool != .stamp {
            let original = try fixture()
            let session = preferences.session(document: original)
            session.tool = tool
            let canvas = CanvasView(session: session, renderer: EditorRenderer())
            canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let location = canvas.convert(canvas.transform.viewPoint(CGPoint(x: 40, y: 40)), to: nil)
            func event(_ type: NSEvent.EventType, count: Int) throws -> NSEvent {
                try TestEvent.mouse(type, atWindowPoint: location, clicks: count)
            }
            canvas.mouseDown(with: try event(.leftMouseDown, count: 1))
            canvas.mouseUp(with: try event(.leftMouseUp, count: 1))
            canvas.mouseDown(with: try event(.leftMouseDown, count: 2))
            #expect(canvas.isEditingText, "Double-click with \(tool.rawValue)")
            #expect(session.tool == .text)
            #expect(session.document == original)
            #expect(!session.history.canUndo && !session.history.canRedo)
            let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
            editor.string = "日本語 text"
            #expect(canvas.finishTextEditing())
            #expect(session.document.annotations.count == 1)
            #expect(session.document.annotations.first?.tool == .text)
            session.history.undo()
            #expect(session.document == original)
            #expect(!session.history.canUndo)
            session.history.redo()
            #expect(session.document.annotations.first?.text == "日本語 text")
        }
    }

    @Test func outsideTextClickCommitsThenSelectsAndDragsObjectOrSelectsBlank() throws {
        var original = try fixture()
        let shape = Markup(tool: .rectangle, points: [CGPoint(x: 310, y: 120), CGPoint(x: 370, y: 220)])
        original.annotations = [shape]
        let session = preferences.session(document: original)
        session.tool = .text
        let canvas = CanvasView(session: session, renderer: EditorRenderer())
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        func event(_ type: NSEvent.EventType, _ point: CGPoint, count: Int = 1) throws -> NSEvent {
            try TestEvent.mouse(
                type, atWindowPoint: canvas.convert(canvas.transform.viewPoint(point), to: nil), clicks: count)
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 30, y: 30)))
        let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "Edited text"
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 310, y: 170)))
        #expect(!canvas.isEditingText && session.tool == .select)
        #expect(session.selection == [shape.id])
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 320, y: 185)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 320, y: 185)))
        #expect(session.document.annotations.first == shape.translated(dx: 10, dy: 15))
        #expect(session.document.annotations.count == 2)
        session.history.undo()
        #expect(session.document.annotations.first == shape)
        #expect(session.document.annotations.last?.text == "Edited text")
        let text = try #require(session.document.annotations.last)
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: text.bounds.midX, y: text.bounds.midY), count: 2))
        #expect(canvas.isEditingText && session.tool == .text)
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 30, y: 270)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 30, y: 270)))
        #expect(!canvas.isEditingText && session.tool == .select && session.selection.isEmpty)
        #expect(session.document.annotations.count == 2)
        session.history.undo()
        #expect(session.document == original)
    }

    @Test func singleClickDotAndStampCommitBeforeUndoAndKeepOneHistoryEntry() throws {
        for tool in [EditorTool.pen, .highlight, .stamp] {
            let original = try fixture()
            let session = preferences.session(document: original)
            session.tool = tool
            let canvas = CanvasView(session: session, renderer: EditorRenderer())
            canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let location = canvas.convert(canvas.transform.viewPoint(CGPoint(x: 80, y: 80)), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try TestEvent.mouse(type, atWindowPoint: location)
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
            let drawn = session.document
            #expect(drawn.annotations.count == 1)
            #expect(canvas.draftDocument == original)
            canvas.undo(nil)
            #expect(session.document == original && !session.history.canUndo)
            canvas.redo(nil)
            #expect(session.document == drawn)
        }
    }

    @Test func consecutiveCommandsHaveIndependentUndoBoundariesAndDocumentReplacementClearsHistory() throws {
        let session = preferences.session(document: try fixture())
        let first = Markup(tool: .rectangle, points: [CGPoint(x: 60, y: 60), CGPoint(x: 160, y: 160)])
        var states = [session.document]
        session.append([first], name: "Paste Annotations")
        states.append(session.document)
        session.duplicateSelection()
        states.append(session.document)
        #expect(Set(session.document.annotations.map(\.id)).count == 2)
        session.moveSelection(dx: 4, dy: -3)
        states.append(session.document)
        session.deleteSelection()
        states.append(session.document)
        for state in states.dropLast().reversed() {
            session.history.undo()
            #expect(session.document == state)
        }
        #expect(!session.history.canUndo)
        for state in states.dropFirst() {
            session.history.redo()
            #expect(session.document == state)
        }
        session.replace(with: try fixture(width: 20, height: 30))
        #expect(!session.history.canUndo && !session.history.canRedo)
        #expect(session.selection.isEmpty)
        #expect(session.fitsWindow)
    }

    @Test func canvasGestureUsesFrozenCoordinateMappingAndCancellationRestoresDraft() throws {
        let session = preferences.session(document: try fixture())
        session.tool = .rectangle
        session.zoom = 0.5
        let canvas = CanvasView(session: session, renderer: EditorRenderer())
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let before = session.document
        let mapping = canvas.transform
        func event(_ type: NSEvent.EventType, _ pixel: CGPoint) throws -> NSEvent {
            let location = canvas.convert(mapping.viewPoint(pixel), to: nil)
            return try TestEvent.mouse(type, atWindowPoint: location)
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 40, y: 50)))
        canvas.frame.size = CGSize(width: 1200, height: 900)
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 160, y: 180)))
        #expect(canvas.draftDocument == before)
        #expect(session.document.annotations[0].points == [CGPoint(x: 40, y: 50), CGPoint(x: 160, y: 180)])
        canvas.cancelOperation(nil)
        #expect(session.document == before)
        #expect(!session.history.canUndo)
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 40, y: 50)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 160, y: 180)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 160, y: 180)))
        #expect(session.history.canUndo)
        session.history.undo()
        #expect(session.document == before)
    }

    @Test func malformedAnnotationPayloadsAreRejected() throws {
        let document = try fixture()
        var invalid = document
        invalid.annotations = [.init(tool: .arrow)]
        #expect(throws: EditorRenderError.self) { try invalid.validate() }
        invalid.annotations = [.init(tool: .crop, points: [.zero, CGPoint(x: 10, y: 10)])]
        #expect(throws: EditorRenderError.self) { try invalid.validate() }
        let mark = Markup(tool: .pen, points: [.zero])
        invalid.annotations = [mark, mark]
        #expect(throws: EditorRenderError.self) { try invalid.validate() }
        invalid.annotations = [
            .init(tool: .text, points: [.zero, CGPoint(x: 10, y: 10)], text: String(repeating: "a", count: 1_000_001))
        ]
        #expect(throws: EditorRenderError.self) { try invalid.validate() }
        invalid = document
        invalid.imageSize = CGSize(width: 20, height: 20)
        #expect(throws: EditorRenderError.self) { try EditorRenderer().render(document: invalid) }
    }

    @Test func textSideHandlesReflowWithoutScalingFontAndPreserveOppositeEdgeThroughRotationAndUndo() throws {
        for mirrored in [false, true] {
            for turns in 0..<4 {
                for leftEdge in [false, true] {
                    var document = try fixture(width: 600, height: 500)
                    document.annotations = [
                        .init(
                            tool: .text,
                            points: [CGPoint(x: 120, y: 100), CGPoint(x: 360, y: 160)], size: 6,
                            text: "日本語の折り返しを確認します。 Same font size with several wrapped lines.")
                    ]
                    if mirrored { document.flip(horizontal: true) }
                    for _ in 0..<turns { document.rotateClockwise() }
                    let mark = document.annotations[0]
                    let session = preferences.session(document: document)
                    session.tool = .select
                    session.zoom = 0.75
                    session.selection = [mark.id]
                    let canvas = CanvasView(session: session, renderer: EditorRenderer())
                    canvas.frame = CGRect(x: 0, y: 0, width: 900, height: 800)
                    let mapping = canvas.transform
                    func world(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                        let delta = CGPoint(x: mark.mirrored ? -x : x, y: y)
                            .applying(CGAffineTransform(rotationAngle: CGFloat(mark.quarterTurns) * .pi / 2))
                        return CGPoint(x: mark.points[0].x + delta.x, y: mark.points[0].y + delta.y)
                    }
                    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                        try TestEvent.mouse(type, atWindowPoint: canvas.convert(mapping.viewPoint(point), to: nil))
                    }
                    canvas.mouseDown(with: try event(.leftMouseDown, world(leftEdge ? 0 : 240, 30)))
                    for step in 1...12 {
                        let width = CGFloat(240 - step * 10)
                        canvas.mouseDragged(
                            with: try event(.leftMouseDragged, world(leftEdge ? 240 - width : width, 30)))
                    }
                    let live = try #require(session.document.annotations.first)
                    #expect(live.size == mark.size && live.text == mark.text)
                    #expect(canvas.draftDocument == document, "The whole resize remains one uncommitted gesture")
                    canvas.mouseUp(with: try event(.leftMouseUp, world(120, 30)))
                    let resized = try #require(session.document.annotations.first)
                    let width = resized.quarterTurns % 2 == 0 ? resized.bounds.width : resized.bounds.height
                    let height = resized.quarterTurns % 2 == 0 ? resized.bounds.height : resized.bounds.width
                    #expect(abs(width - 120) < 0.001)
                    #expect(height > 60, "Narrowing must grow wrapped text height immediately")
                    #expect(resized.size == 6 && resized.text == mark.text)
                    #expect(resized.quarterTurns == mark.quarterTurns && resized.mirrored == mark.mirrored)
                    let expectedOrigin = world(leftEdge ? 120 : 0, 0)
                    #expect(abs(resized.points[0].x - expectedOrigin.x) < 0.001)
                    #expect(abs(resized.points[0].y - expectedOrigin.y) < 0.001)
                    #expect(session.history.undoActionName == "Resize Annotations")
                    let final = session.document
                    session.history.undo()
                    #expect(session.document == document && !session.history.canUndo)
                    session.history.redo()
                    #expect(session.document == final)
                }
            }
        }
    }

    @Test func textSideResizeStopsAtReadableMinimumWidthAndCanBeCancelled() throws {
        var document = try fixture()
        document.annotations = [
            .init(tool: .text, points: [CGPoint(x: 60, y: 60), CGPoint(x: 300, y: 120)], size: 6, text: "Wrap me")
        ]
        let session = preferences.session(document: document)
        session.tool = .select
        session.selection = [document.annotations[0].id]
        let canvas = CanvasView(session: session, renderer: EditorRenderer())
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let mapping = canvas.transform
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try TestEvent.mouse(type, atWindowPoint: canvas.convert(mapping.viewPoint(point), to: nil))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 300, y: 90)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 20, y: 90)))
        #expect(session.document.annotations[0].bounds.width == 24)
        #expect(session.document.annotations[0].size == 6)
        canvas.cancelOperation(nil)
        #expect(session.document == document && !session.history.canUndo)
    }

    @Test func textCornersScaleFontAndBoxTogetherAcrossAllCornersRotationsAndMirrors() throws {
        for mirrored in [false, true] {
            for turns in 0..<4 {
                for corner in 0..<4 {
                    var document = try fixture(width: 600, height: 500)
                    document.annotations = [
                        .init(
                            tool: .text,
                            points: [CGPoint(x: 120, y: 100), CGPoint(x: 360, y: 160)], size: 6, text: "日本語 ABC")
                    ]
                    if mirrored { document.flip(horizontal: true) }
                    for _ in 0..<turns { document.rotateClockwise() }
                    let mark = document.annotations[0]
                    let bounds = mark.bounds
                    let corners = [
                        CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                        CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY),
                    ]
                    let anchor = corners[(corner + 2) % 4]
                    let session = preferences.session(document: document)
                    session.tool = .select
                    session.zoom = 0.75
                    session.selection = [mark.id]
                    let canvas = CanvasView(session: session, renderer: EditorRenderer())
                    canvas.frame = CGRect(x: 0, y: 0, width: 900, height: 800)
                    let mapping = canvas.transform
                    func event(_ type: NSEvent.EventType, scale: CGFloat) throws -> NSEvent {
                        let point = CGPoint(
                            x: anchor.x + (corners[corner].x - anchor.x) * scale,
                            y: anchor.y + (corners[corner].y - anchor.y) * scale)
                        return try TestEvent.mouse(
                            type, atWindowPoint: canvas.convert(mapping.viewPoint(point), to: nil))
                    }
                    canvas.mouseDown(with: try event(.leftMouseDown, scale: 1))
                    for step in 1...10 {
                        canvas.mouseDragged(with: try event(.leftMouseDragged, scale: 1 + CGFloat(step) / 20))
                    }
                    #expect(canvas.draftDocument == document)
                    canvas.mouseUp(with: try event(.leftMouseUp, scale: 1.5))
                    let scaled = try #require(session.document.annotations.first)
                    #expect(abs(scaled.size - 9) < 0.001, "The 24px font must become36px")
                    #expect(abs(scaled.bounds.width - bounds.width * 1.5) < 0.001)
                    #expect(abs(scaled.bounds.height - bounds.height * 1.5) < 0.001)
                    #expect(
                        scaled.text == mark.text && scaled.quarterTurns == mark.quarterTurns
                            && scaled.mirrored == mark.mirrored)
                    let target = scaled.bounds
                    let newCorners = [
                        CGPoint(x: target.minX, y: target.minY), CGPoint(x: target.maxX, y: target.minY),
                        CGPoint(x: target.maxX, y: target.maxY), CGPoint(x: target.minX, y: target.maxY),
                    ]
                    #expect(
                        hypot(newCorners[(corner + 2) % 4].x - anchor.x, newCorners[(corner + 2) % 4].y - anchor.y)
                            < 0.001)
                    let final = session.document
                    session.history.undo()
                    #expect(session.document == document && !session.history.canUndo)
                    session.history.redo()
                    #expect(session.document == final)
                }
            }
        }
    }

    @Test func textCornerScalingClampsTinyAndExtremeDragsWithoutInvalidDocument() throws {
        for scale: CGFloat in [-1, 100_000] {
            var document = try fixture()
            document.annotations = [
                .init(tool: .text, points: [CGPoint(x: 60, y: 60), CGPoint(x: 300, y: 120)], size: 6, text: "Resize")
            ]
            let session = preferences.session(document: document)
            session.tool = .select
            session.selection = [document.annotations[0].id]
            let canvas = CanvasView(session: session, renderer: EditorRenderer())
            canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let mapping = canvas.transform
            func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try TestEvent.mouse(type, atWindowPoint: canvas.convert(mapping.viewPoint(point), to: nil))
            }
            let end = CGPoint(x: 60 + 240 * scale, y: 60 + 60 * scale)
            canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 300, y: 120)))
            canvas.mouseDragged(with: try event(.leftMouseDragged, end))
            canvas.mouseUp(with: try event(.leftMouseUp, end))
            let resized = session.document.annotations[0]
            #expect(resized.size * 4 >= 1 && resized.size * 4 <= 4096)
            #expect(abs(resized.bounds.width / resized.bounds.height - 4) < 0.001)
            try session.document.validate()
            session.history.undo()
            #expect(session.document == document)
        }
    }

    @Test func pixelatedTransparencyCompositesOverBackgroundWithoutOriginalDetail() throws {
        var document = try fixture(width: 40, height: 40)
        document.annotations = [
            .init(tool: .line, points: [CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 40)], color: .palette[0], size: 2),
            .init(tool: .pixelate, points: [.zero, CGPoint(x: 40, y: 40)], size: 10),
        ]
        let renderer = EditorRenderer()
        let flattened = try renderer.render(document: document)
        let context = try #require(
            CGContext(
                data: nil, width: 40, height: 40, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.translateBy(x: 0, y: 40)
        context.scaleBy(x: 1, y: -1)
        renderer.draw(document: document, in: context)
        let onscreen = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let clearPixel = try #require(onscreen.colorAt(x: 30, y: 10))
        #expect(clearPixel.alphaComponent > 0.99)
        #expect(clearPixel.greenComponent > 0.99)
        let redacted = NSBitmapImageRep(cgImage: flattened)
        let one = try #require(redacted.colorAt(x: 5, y: 10))
        let two = try #require(redacted.colorAt(x: 15, y: 10))
        #expect(abs(one.alphaComponent - two.alphaComponent) < 0.01)
        #expect(abs(one.redComponent - two.redComponent) < 0.01)
    }

    @Test func textStampAndArrowOrientationMatchesRasterRotationAndReflection() throws {
        var original = try fixture(width: 300, height: 240)
        original.annotations = [
            .init(tool: .text, points: [CGPoint(x: 20, y: 20), CGPoint(x: 230, y: 65)], size: 6, text: "日本語 ABC"),
            .init(
                tool: .stamp, points: [CGPoint(x: 30, y: 90), CGPoint(x: 230, y: 150)], text: "OK", stamp: 0, tail: true
            ),
            .init(tool: .arrow, points: [CGPoint(x: 20, y: 190), CGPoint(x: 270, y: 210)], size: 8),
        ]
        let renderer = EditorRenderer()
        let source = try renderer.render(document: original)
        for reflected in [false, true] {
            for turns in 0..<4 {
                var document = original
                if reflected { document.flip(horizontal: true) }
                for _ in 0..<turns { document.rotateClockwise() }
                let actual = NSBitmapImageRep(cgImage: try renderer.render(document: document))
                let expected = try #require(
                    CGContext(
                        data: nil, width: actual.pixelsWide, height: actual.pixelsHigh,
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                expected.translateBy(x: 0, y: CGFloat(actual.pixelsHigh))
                expected.scaleBy(x: 1, y: -1)
                expected.concatenate(document.imageTransform.cgAffineTransform)
                expected.translateBy(x: 0, y: original.canvas.height)
                expected.scaleBy(x: 1, y: -1)
                expected.draw(source, in: original.canvas)
                let target = NSBitmapImageRep(cgImage: try #require(expected.makeImage()))
                var difference: CGFloat = 0
                for y in 0..<actual.pixelsHigh {
                    for x in 0..<actual.pixelsWide {
                        let a = actual.colorAt(x: x, y: y)!
                        let b = target.colorAt(x: x, y: y)!
                        difference += abs(a.alphaComponent - b.alphaComponent)
                    }
                }
                #expect(difference / CGFloat(actual.pixelsWide * actual.pixelsHigh) < 0.012)
                #expect(document.imageData == original.imageData)
            }
        }
    }

    @Test func inlineEditsPreserveRotatedAndMirroredTextGeometryAndUndo() throws {
        for tool in [EditorTool.text, .stamp] {
            for mirrored in [false, true] {
                for turns in 0..<4 {
                    var document = try fixture()
                    document.annotations = [
                        .init(
                            tool: tool,
                            points: [CGPoint(x: 50, y: 60), CGPoint(x: 290, y: 120)], size: 6,
                            text: "日本語 ABC", stamp: 2, tail: true)
                    ]
                    if mirrored { document.flip(horizontal: true) }
                    for _ in 0..<turns { document.rotateClockwise() }
                    let session = preferences.session(document: document)
                    session.zoom = 0.75
                    let renderer = EditorRenderer()
                    let canvas = CanvasView(session: session, renderer: renderer)
                    canvas.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
                    let mark = document.annotations[0]
                    let hitBounds = tool == .stamp ? mark.stampCircleBounds : mark.bounds
                    let location = canvas.convert(
                        canvas.transform.viewPoint(CGPoint(x: hitBounds.midX, y: hitBounds.midY)), to: nil)
                    let click = try TestEvent.mouse(.leftMouseDown, atWindowPoint: location, clicks: 2)
                    let beforePixels = try renderer.render(document: document).dataProvider!.data! as Data
                    canvas.mouseDown(with: click)
                    let unchangedEditor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
                    if tool == .text {
                        #expect(abs((unchangedEditor.frame.width - 6) / session.zoom - 240) < 0.001)
                        #expect(unchangedEditor.font?.pointSize == 18)
                    }
                    #expect(canvas.finishTextEditing())
                    #expect(session.document == document)
                    #expect(!session.history.canUndo)
                    #expect(try renderer.render(document: session.document).dataProvider!.data! as Data == beforePixels)
                    canvas.mouseDown(with: click)
                    let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
                    editor.string = tool == .text ? "新しい日本語の文章を編集します。\nSecond line" : "新しいラベル"
                    #expect(canvas.finishTextEditing())
                    let edited = try #require(session.document.annotations.first)
                    #expect(edited.quarterTurns == mark.quarterTurns && edited.mirrored == mark.mirrored)
                    #expect(abs(edited.points[0].x - mark.points[0].x) < 0.001)
                    #expect(abs(edited.points[0].y - mark.points[0].y) < 0.001)
                    if tool == .text {
                        let width = edited.quarterTurns % 2 == 0 ? edited.bounds.width : edited.bounds.height
                        #expect(abs(width - 240) < 0.001)
                    }
                    #expect(session.history.canUndo)
                    session.history.undo()
                    #expect(session.document == document)
                }
            }
        }
    }

    @Test func japaneseMarkedTextCannotEnterSavedDraftUntilCommitted() throws {
        var document = try fixture()
        document.annotations = [
            .init(tool: .text, points: [CGPoint(x: 20, y: 20), CGPoint(x: 280, y: 100)], text: "Original")
        ]
        let session = preferences.session(document: document)
        let canvas = CanvasView(session: session, renderer: EditorRenderer())
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let location = canvas.convert(canvas.transform.viewPoint(CGPoint(x: 60, y: 40)), to: nil)
        canvas.mouseDown(
            with: try TestEvent.mouse(.leftMouseDown, atWindowPoint: location, clicks: 2))
        let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.setMarkedText(
            "にほん", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: 0, length: 8))
        #expect(editor.hasMarkedText())
        #expect(!canvas.finishTextEditing())
        let originalTool = session.tool
        let outside = canvas.convert(canvas.transform.viewPoint(CGPoint(x: 340, y: 250)), to: nil)
        canvas.mouseDown(
            with: try TestEvent.mouse(.leftMouseDown, atWindowPoint: outside))
        #expect(canvas.isEditingText && editor.hasMarkedText())
        #expect(session.tool == originalTool)
        #expect(canvas.draftDocument == document)
        #expect(session.document == document)
        editor.unmarkText()
        #expect(canvas.finishTextEditing())
        #expect(session.document.annotations[0].text == "にほん")
        session.history.undo()
        #expect(session.document == document)
    }

    @Test func highlighterFollowsFreehandPathWithBroadTranslucentStrokeAndUndo() throws {
        let document = try fixture(width: 140, height: 140)
        let session = preferences.session(document: document)
        session.tool = .highlight
        session.sizeIndex = 1
        let canvas = CanvasView(session: session, renderer: EditorRenderer())
        canvas.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            let location = canvas.convert(canvas.transform.viewPoint(point), to: nil)
            return try TestEvent.mouse(type, atWindowPoint: location)
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 20)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100, y: 20)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100, y: 100)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100, y: 100)))
        let mark = try #require(session.document.annotations.first)
        #expect(mark.points == [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 100)])
        #expect(mark.strokeExtent == 16)
        #expect(mark.visualBounds.contains(CGPoint(x: 60, y: 12)))
        #expect(mark.hitTest(CGPoint(x: 95, y: 60), tolerance: 1))
        #expect(!mark.hitTest(CGPoint(x: 60, y: 60), tolerance: 1))
        let image = NSBitmapImageRep(cgImage: try EditorRenderer().render(document: session.document))
        let stroke = try #require(image.colorAt(x: 60, y: 20))
        #expect(abs(stroke.alphaComponent - 0.33) < 0.01)
        #expect(try #require(image.colorAt(x: 60, y: 60)).alphaComponent < 0.01)
        session.history.undo()
        #expect(session.document == document)
        session.history.redo()
        #expect(session.document.annotations == [mark])
        session.history.undo()
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 60, y: 60)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 60, y: 60)))
        let dot = try #require(session.document.annotations.first)
        #expect(dot.hitTest(CGPoint(x: 64, y: 60), tolerance: 1))
        let dotted = NSBitmapImageRep(cgImage: try EditorRenderer().render(document: session.document))
        #expect(try #require(dotted.colorAt(x: 60, y: 60)).alphaComponent > 0.3)
    }

    @Test func scaledDownInlineTextAndStampFontsMatchRendererSizes() throws {
        for tool in [EditorTool.text, .stamp] {
            var document = try fixture()
            document.annotations = [
                .init(tool: tool, points: [CGPoint(x: 20, y: 20), CGPoint(x: 260, y: 80)], size: 6, text: "ABC")
            ]
            document.resize(to: CGSize(width: 40, height: 30))
            let session = preferences.session(document: document)
            let canvas = CanvasView(session: session, renderer: EditorRenderer())
            canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
            let mark = document.annotations[0]
            let hitBounds = tool == .stamp ? mark.stampCircleBounds : mark.bounds
            let location = canvas.convert(
                canvas.transform.viewPoint(CGPoint(x: hitBounds.midX, y: hitBounds.midY)), to: nil)
            canvas.mouseDown(
                with: try TestEvent.mouse(.leftMouseDown, atWindowPoint: location, clicks: 2))
            let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
            let expected: CGFloat = tool == .text ? 2.4 : 2.28
            #expect(abs(try #require(editor.font).pointSize - expected) < 0.001)
            #expect(canvas.finishTextEditing())
            #expect(session.document == document)
            #expect(try EditorRenderer().render(document: document).width == 40)
        }
    }

    @Test func cropGestureAtSelectedHandleCropsCanvasInsteadOfResizingAnnotation() throws {
        var document = try fixture()
        let mark = Markup(tool: .rectangle, points: [CGPoint(x: 80, y: 70), CGPoint(x: 240, y: 210)], size: 6)
        document.annotations = [mark]
        let session = preferences.session(document: document)
        session.selection = [mark.id]
        session.tool = .crop
        let canvas = CanvasView(session: session, renderer: EditorRenderer())
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let mapping = canvas.transform
        func event(_ type: NSEvent.EventType, _ pixel: CGPoint) throws -> NSEvent {
            let location = canvas.convert(mapping.viewPoint(pixel), to: nil)
            return try TestEvent.mouse(type, atWindowPoint: location)
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 80, y: 70)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 280, y: 240)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 280, y: 240)))
        #expect(session.document.canvas == CGRect(x: 80, y: 70, width: 200, height: 170))
        #expect(session.document.annotations == [mark])
        #expect(session.history.undoActionName == "Crop Image")
        session.history.undo()
        #expect(session.document == document)
        #expect(!session.history.canUndo)
        session.history.redo()
        #expect(session.document.canvas == CGRect(x: 80, y: 70, width: 200, height: 170))
        #expect(session.document.annotations == [mark])
    }

    @Test func everyAnnotationToolSupportsCanvasCreationSelectionMoveDeleteAndUndo() throws {
        let tools: [EditorTool] = [
            .arrow, .text, .rectangle, .roundedRectangle, .ellipse, .line, .pen, .highlight, .pixelate, .stamp,
        ]
        for tool in tools {
            let document = try fixture()
            let session = preferences.session(document: document)
            session.tool = tool
            let canvas = CanvasView(session: session, renderer: EditorRenderer())
            canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            func event(_ type: NSEvent.EventType, _ pixel: CGPoint) throws -> NSEvent {
                let location = canvas.convert(canvas.transform.viewPoint(pixel), to: nil)
                return try TestEvent.mouse(type, atWindowPoint: location)
            }
            canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 50, y: 50)))
            if tool == .text {
                let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
                editor.string = "Test annotation"
                #expect(canvas.finishTextEditing())
            } else {
                if [.pen, .highlight].contains(tool) {
                    canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100, y: 50)))
                }
                canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 150, y: 120)))
                canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 150, y: 120)))
            }
            #expect(session.document.annotations.count == 1, "Created \(tool.rawValue)")
            let created = try #require(session.document.annotations.first)
            #expect(created.tool == tool)
            let hit: CGPoint
            switch tool {
            case .rectangle, .roundedRectangle, .ellipse:
                hit = CGPoint(x: created.bounds.minX, y: created.bounds.midY)
            case .pen, .highlight:
                hit = CGPoint(x: 100, y: 50)
            default:
                hit = CGPoint(x: created.bounds.midX, y: created.bounds.midY)
            }
            session.selection.removeAll()
            session.tool = .select
            canvas.mouseDown(with: try event(.leftMouseDown, hit))
            #expect(session.selection == [created.id], "Selected \(tool.rawValue)")
            let movedHit = CGPoint(x: hit.x + 10, y: hit.y + 15)
            canvas.mouseDragged(with: try event(.leftMouseDragged, movedHit))
            canvas.mouseUp(with: try event(.leftMouseUp, movedHit))
            let moved = created.translated(dx: 10, dy: 15)
            #expect(session.document.annotations == [moved], "Moved \(tool.rawValue)")
            canvas.delete(nil)
            #expect(session.document.annotations.isEmpty, "Deleted \(tool.rawValue)")
            session.history.undo()
            #expect(session.document.annotations == [moved])
            session.history.undo()
            #expect(session.document.annotations == [created])
            session.history.undo()
            #expect(session.document == document)
            #expect(!session.history.canUndo)
            session.history.redo()
            session.history.redo()
            session.history.redo()
            #expect(session.document.annotations.isEmpty)
        }
    }

    @Test func textCommitUsesEditingZoomWhenSessionZoomChangesMidEdit() throws {
        var document = try fixture()
        document.annotations = [
            .init(
                tool: .text, points: [CGPoint(x: 30, y: 30), CGPoint(x: 270, y: 100)],
                size: 6, text: "Original")
        ]
        func edit(finalZoom: CGFloat) throws -> EditorDocument {
            let session = preferences.session(document: document)
            session.zoom = 0.75
            let canvas = CanvasView(session: session, renderer: EditorRenderer())
            canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let location = canvas.convert(canvas.transform.viewPoint(CGPoint(x: 80, y: 50)), to: nil)
            canvas.mouseDown(
                with: try TestEvent.mouse(.leftMouseDown, atWindowPoint: location, clicks: 2))
            let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
            editor.string = "日本語の長い文章を同じ幅で折り返して編集します。\nSecond line with wrapping."
            session.zoom = finalZoom
            #expect(canvas.finishTextEditing())
            return session.document
        }
        let unchangedZoom = try edit(finalZoom: 0.75)
        let increasedZoom = try edit(finalZoom: 3)
        let decreasedZoom = try edit(finalZoom: 0.2)
        #expect(increasedZoom == unchangedZoom)
        #expect(decreasedZoom == unchangedZoom)
        #expect(unchangedZoom.annotations[0].bounds.width == 240)
    }

    @Test func pinchDisplayRestoresFinalQualityWithoutChangingExport() throws {
        let source = try #require(
            CGContext(
                data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(NSColor.white.cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        source.setFillColor(NSColor.black.cgColor)
        for x in stride(from: 0, to: 1024, by: 2) { source.fill(CGRect(x: x, y: 0, width: 1, height: 512)) }
        let data = try ImageService.pngData(#require(source.makeImage()))
        let document = EditorDocument(imageData: data, imageSize: CGSize(width: 1024, height: 512))
        let session = preferences.session(document: document)
        session.zoom = 0.17
        let renderer = EditorRenderer()
        let clock = ManualScheduler()
        let canvas = CanvasView(session: session, renderer: EditorRenderer(), scheduler: clock.scheduler)
        canvas.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        canvas.onZoom = { session.zoom = $0 }
        func snapshot() throws -> Data {
            let context = try #require(
                CGContext(
                    data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: 240)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            canvas.draw(canvas.bounds)
            return try #require(context.makeImage()?.dataProvider?.data) as Data
        }
        let baseline = try snapshot()
        let export = try renderer.render(document: document).dataProvider!.data! as Data
        canvas.handleMagnification(0, phase: .began)
        let duringPinch = try snapshot()
        #expect(duringPinch != baseline)
        #expect(try renderer.render(document: session.document).dataProvider!.data! as Data == export)
        canvas.handleMagnification(0, phase: .ended)
        #expect(try snapshot() == baseline)
        canvas.handleMagnification(0, phase: .changed)
        canvas.handleMagnification(0, phase: .cancelled)
        #expect(try snapshot() == baseline)
        canvas.handleMagnification(0, phase: [])
        #expect(try snapshot() != baseline)
        clock.advance(by: 0.179)
        #expect(try snapshot() != baseline, "Interactive quality lasts until the fallback deadline")
        clock.advance(by: 0.002)
        #expect(try snapshot() == baseline)

        canvas.handleMagnification(0, phase: [])
        clock.advance(by: 0.1)
        canvas.handleMagnification(0, phase: [])
        clock.advance(by: 0.081)
        #expect(try snapshot() != baseline, "Another magnification renews the fallback deadline")
        clock.advance(by: 0.1)
        #expect(try snapshot() == baseline)

        canvas.handleMagnification(0, phase: [])
        clock.advance(by: 0.1)
        canvas.handleMagnification(0, phase: .began)
        clock.advance(by: 1)
        #expect(try snapshot() != baseline, "A phased gesture cancels the previous fallback")
        canvas.handleMagnification(0, phase: .ended)
        #expect(try snapshot() == baseline)
        #expect(session.document == document)
        #expect(try renderer.render(document: session.document).dataProvider!.data! as Data == export)
    }
}
