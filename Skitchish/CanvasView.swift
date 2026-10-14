import AppKit

@MainActor
final class CanvasView: NSView, NSTextViewDelegate, NSMenuItemValidation {
    let session: EditorSession
    let renderer: EditorRenderer
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onDropImage: ((CGImage) -> Void)?
    var onToolShortcut: ((String) -> Bool)?
    var onZoom: ((CGFloat) -> Void)?
    var onCanvasInteraction: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { isEditingText ? textHistory : session.history }

    private enum Gesture {
        case draw(UUID)
        case stampPointer(UUID)
        case move
        case resize(Int)
        case marquee, crop
    }
    private var gesture: Gesture?
    private var gestureDocument: EditorDocument?
    private var gestureTransform: CanvasTransform?
    private var gestureSelection = Set<UUID>()
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var draggedBeyondClick = false
    private var dragRect: CGRect?
    private var textEditor: NSTextView?
    private var textDocument: EditorDocument?
    private var textMarkup: Markup?
    private var textEditingZoom: CGFloat = 1
    private var textEditingCenter = CGPoint.zero
    private var textEditorPositionOffset = CGPoint.zero
    private struct TextEditingGeometry {
        var mark: Markup
        var frame: CGRect
        var center: CGPoint
        var positionOffset: CGPoint
    }
    private struct TextWidthGesture {
        var original: TextEditingGeometry
        var start: CGPoint
        var mapping: CanvasTransform
        var left: Bool
    }
    private var textWidthGesture: TextWidthGesture?
    private var pendingClick: (before: EditorDocument, after: EditorDocument, selection: Set<UUID>)?
    private var pendingClickCommit: DispatchWorkItem?
    private let textHistory = UndoManager()
    private var interactiveZoom = false
    private var zoomQualityReset: DispatchWorkItem?
    var isEditingText: Bool { textEditor != nil }
    var draftDocument: EditorDocument { textDocument ?? gestureDocument ?? pendingClick?.before ?? session.document }
    var transform: CanvasTransform {
        if let editing = textWidthGesture { return editing.mapping }
        if let frozen = gestureTransform { return frozen }
        let canvas = session.document.canvas
        let zoom = max(0.01, session.zoom)
        return CanvasTransform(
            canvas: canvas, zoom: zoom,
            origin: CGPoint(
                x: max(48, (bounds.width - canvas.width * zoom) / 2),
                y: max(48, (bounds.height - canvas.height * zoom) / 2)))
    }

    init(session: EditorSession, renderer: EditorRenderer) {
        self.session = session
        self.renderer = renderer
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")])
        setAccessibilityLabel("Image annotation canvas")
        setAccessibilityIdentifier("editor.canvas")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshCursor() {
        window?.invalidateCursorRects(for: self)
        if let textEditor { window?.invalidateCursorRects(for: textEditor) }
    }

    private var textSelectionChrome: TextSelectionChrome? {
        if let editor = textEditor, textMarkup?.tool == .text {
            return TextSelectionChrome(editorFrame: editor.frame)
        }
        guard textEditor == nil, selectedMarks.count == 1, let mark = selectedMarks.first,
            mark.tool == .text
        else { return nil }
        return TextSelectionChrome(mark: mark, mapping: transform)
    }

    private var stampSelectionChrome: StampSelectionChrome? {
        guard textEditor == nil, selectedMarks.count == 1, let mark = selectedMarks.first, mark.tool == .stamp else {
            return nil
        }
        return StampSelectionChrome(mark: mark, mapping: transform)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if textEditor != nil, textSelectionChrome?.widthHandle(at: local) != nil, visibleRect.contains(local) {
            return self
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch session.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        case .pixelate: cursor = CanvasCursors.pixelate
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
        if session.tool != .crop, let chrome = stampSelectionChrome, let mark = selectedMarks.first {
            for body in [mark.stampCircleBounds, mark.stampLabelBounds] where !body.isNull {
                let rect = transform.viewRect(body).intersection(visibleRect)
                if !rect.isEmpty { addCursorRect(rect, cursor: .openHand) }
            }
            for region in chrome.cursorRegions {
                let rect = region.intersection(visibleRect)
                if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
            }
            return
        }
        if session.tool != .crop, let chrome = textSelectionChrome {
            for region in chrome.resizeRegions(editing: isEditingText) {
                let rect = region.rect.intersection(visibleRect)
                if !rect.isEmpty {
                    addCursorRect(rect, cursor: isEditingText ? .resizeLeftRight : resizeCursor(for: region.index))
                }
            }
            return
        }
        guard !isEditingText, session.tool != .crop else { return }
        for (index, point) in handles().enumerated() {
            let center = transform.viewPoint(point)
            let rect = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16).intersection(visibleRect)
            if !rect.isEmpty { addCursorRect(rect, cursor: resizeCursor(for: index)) }
        }
    }

    private func resizeCursor(for index: Int) -> NSCursor {
        if index >= 4, let text = selectedMarks.first, text.tool == .text {
            return text.quarterTurns % 2 == 0 ? .resizeLeftRight : .resizeUpDown
        }
        if selectedMarks.count == 1, let mark = selectedMarks.first, [.arrow, .line].contains(mark.tool) {
            return mark.bounds.width >= mark.bounds.height ? .resizeLeftRight : .resizeUpDown
        }
        return index % 2 == 0 ? CanvasCursors.diagonalResize : CanvasCursors.reverseDiagonalResize
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
        dirtyRect.fill()
        let mapping = transform
        drawPaper(mapping.viewRect(session.document.canvas), dirtyRect: dirtyRect, in: context)
        drawDocument(in: context, mapping: mapping)
        drawSelection(in: context, mapping: mapping)
    }

    private func drawPaper(_ paper: CGRect, dirtyRect: CGRect, in context: CGContext) {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 2), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(paper)
        context.restoreGState()

        // Limit the checkerboard work to the visible part of the canvas.
        let visible = paper.intersection(dirtyRect)
        guard !visible.isNull else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: paper)
        context.setFillColor(NSColor(calibratedWhite: 0.91, alpha: 1).cgColor)
        let cell: CGFloat = 12
        let rows = Int(floor((visible.minY - paper.minY) / cell))...Int(ceil((visible.maxY - paper.minY) / cell))
        let columns = Int(floor((visible.minX - paper.minX) / cell))...Int(ceil((visible.maxX - paper.minX) / cell))
        for row in rows {
            for column in columns where (row + column) % 2 == 0 {
                context.fill(
                    CGRect(
                        x: paper.minX + CGFloat(column) * cell,
                        y: paper.minY + CGFloat(row) * cell,
                        width: cell, height: cell))
            }
        }
    }

    private func drawDocument(in context: CGContext, mapping: CanvasTransform) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: mapping.origin.x, y: mapping.origin.y)
        context.scaleBy(x: mapping.zoom, y: mapping.zoom)
        context.translateBy(x: -mapping.canvas.minX, y: -mapping.canvas.minY)

        // Keep full quality at rest and in the independent export renderer. During a
        // pinch, bilinear source resampling avoids repeatedly doing expensive filtering.
        context.interpolationQuality = interactiveZoom ? .low : .default
        renderer.draw(document: displayedDocument, in: context)
    }

    private var displayedDocument: EditorDocument {
        var displayed = session.document
        if let edited = textMarkup {
            if edited.tool == .stamp, let index = displayed.annotations.firstIndex(where: { $0.id == edited.id }) {
                // The label is native editable text; keep its marker and pointer visible.
                displayed.annotations[index].text = ""
            } else {
                displayed.annotations.removeAll { $0.id == edited.id }
            }
        }
        return displayed
    }

    private var selectedMarks: [Markup] { session.document.annotations.filter { session.selection.contains($0.id) } }
    private var selectionBounds: CGRect? {
        selectedMarks.reduce(nil as CGRect?) { $0?.union($1.bounds) ?? $1.bounds }
    }
    private func handles() -> [CGPoint] {
        if selectedMarks.count == 1, selectedMarks[0].tool == .stamp { return [] }
        if selectedMarks.count == 1, let item = selectedMarks.first, [.arrow, .line].contains(item.tool),
            item.points.count >= 2
        {
            return [item.points[0], item.points[item.points.count - 1]]
        }
        guard let rect = selectionBounds else { return [] }
        var points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
        if selectedMarks.count == 1, let text = selectedMarks.first, text.tool == .text {
            let size = text.localSize
            points += [
                TextAnnotationGeometry.worldPoint(CGPoint(x: 0, y: size.height / 2), in: text),
                TextAnnotationGeometry.worldPoint(CGPoint(x: size.width, y: size.height / 2), in: text),
            ]
        }
        return points
    }
    private func drawSelection(in context: CGContext, mapping: CanvasTransform) {
        context.saveGState()
        defer { context.restoreGState() }
        let blue = NSColor.controlAccentColor.cgColor
        context.setStrokeColor(blue)
        context.setLineWidth(1)
        if let chrome = textSelectionChrome {
            chrome.draw(in: context, editing: isEditingText)
        } else if let chrome = stampSelectionChrome {
            chrome.draw(in: context)
        } else if textEditor == nil, let rect = selectionBounds {
            let isText = selectedMarks.count == 1 && selectedMarks[0].tool == .text
            let hasEndpointHandles = selectedMarks.count == 1 && [.arrow, .line].contains(selectedMarks[0].tool)
            let endpointColor = NSColor(srgbRed: 0.08, green: 0.73, blue: 0.9, alpha: 1)
            // Arrows and lines are adjusted directly at their two endpoints.
            // Follow the annotation silhouette rather than implying corner handles.
            if hasEndpointHandles {
                let mark = selectedMarks[0]
                let path: CGPath?
                if mark.tool == .arrow {
                    path = mark.arrowPath
                } else if let first = mark.points.first {
                    let line = CGMutablePath()
                    line.move(to: first)
                    for point in mark.points.dropFirst() { line.addLine(to: point) }
                    path = line.copy(strokingWithWidth: mark.size, lineCap: .round, lineJoin: .round, miterLimit: 1)
                } else {
                    path = nil
                }
                var transform = CGAffineTransform(
                    a: mapping.zoom, b: 0, c: 0, d: mapping.zoom,
                    tx: mapping.origin.x - mapping.canvas.minX * mapping.zoom,
                    ty: mapping.origin.y - mapping.canvas.minY * mapping.zoom)
                if let displayedPath = path?.copy(using: &transform) {
                    context.setStrokeColor(endpointColor.withAlphaComponent(0.5).cgColor)
                    context.setLineWidth(2)
                    context.setLineJoin(.round)
                    context.addPath(displayedPath)
                    context.strokePath()
                }
            } else {
                context.setLineDash(phase: 0, lengths: isText ? [] : [4, 3])
                context.stroke(mapping.viewRect(rect).insetBy(dx: -3, dy: -3))
                context.setLineDash(phase: 0, lengths: [])
            }
            for (index, point) in handles().enumerated() {
                let p = mapping.viewPoint(point)
                let radius: CGFloat = hasEndpointHandles ? 6 : 4
                let handle = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                context.setFillColor(hasEndpointHandles ? endpointColor.cgColor : NSColor.white.cgColor)
                context.setStrokeColor(hasEndpointHandles ? NSColor.white.cgColor : blue)
                context.setLineWidth(1)
                if index >= 4 {
                    context.fill(handle)
                    context.stroke(handle)
                } else {
                    context.fillEllipse(in: handle)
                    context.strokeEllipse(in: handle)
                }
            }
        }
        context.setStrokeColor(blue)
        context.setLineWidth(1)
        if let rect = dragRect {
            let viewRect = mapping.viewRect(rect)
            if case .crop? = gesture {
                let mask = CGMutablePath()
                mask.addRect(mapping.viewRect(session.document.canvas))
                mask.addRect(viewRect)
                context.addPath(mask)
                context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                context.fillPath(using: .evenOdd)
            } else {
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
                context.fill(viewRect)
            }
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.stroke(viewRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onCanvasInteraction?()
        defer { refreshCursor() }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let editor = textEditor, let mark = textMarkup, mark.tool == .text,
            let side = textSelectionChrome?.widthHandle(at: viewPoint)
        {
            editor.breakUndoCoalescing()
            textWidthGesture = TextWidthGesture(
                original: TextEditingGeometry(
                    mark: mark, frame: editor.frame, center: textEditingCenter,
                    positionOffset: textEditorPositionOffset),
                start: viewPoint, mapping: transform, left: side == 4)
            return
        }
        if event.clickCount == 2, let pendingClick, session.document == pendingClick.after,
            !pendingClick.after.annotations.contains(where: { mark in
                mark.tool == .stamp && !pendingClick.before.annotations.contains(where: { $0.id == mark.id })
            })
        {
            // A pen dot from the first click belongs to this double-click. A new
            // stamp stays in place so the second click can edit its label.
            session.document = pendingClick.before
            session.selection = pendingClick.selection
            clearPendingClick()
        } else {
            finishPendingClick()
        }
        let wasEditingText = isEditingText
        let wasEditingStamp = textMarkup?.tool == .stamp
        guard finishTextEditing() else { return }
        if wasEditingStamp {
            session.selection.removeAll()
            session.onChange?()
            needsDisplay = true
            return
        }
        if wasEditingText { session.tool = .select }
        window?.makeFirstResponder(self)
        let mapping = transform
        let point = mapping.imagePoint(convert(event.locationInWindow, from: nil))
        startPoint = point
        lastPoint = point
        draggedBeyondClick = false
        gestureDocument = session.document
        gestureTransform = mapping
        gestureSelection = session.selection
        if session.tool != .crop, !event.modifierFlags.contains(.shift),
            let chrome = stampSelectionChrome, let action = chrome.action(at: viewPoint), let mark = selectedMarks.first
        {
            switch action {
            case .addLabel:
                clearGesture()
                beginTextEditing(mark)
            case .removeLabel:
                clearGesture()
                session.change("Remove Stamp Label") { document in
                    if let index = document.annotations.firstIndex(where: { $0.id == mark.id }) {
                        document.annotations[index].text = ""
                    }
                }
            case .pointer:
                gesture = .stampPointer(mark.id)
            }
            needsDisplay = true
            return
        }
        let hit = session.document.annotations.reversed().first { $0.hitTest(point, tolerance: 7 / mapping.zoom) }
        if event.clickCount == 2, beginDoubleClickEditing(hit: hit, at: point) {
            return
        }
        if session.tool != .crop, let index = resizeHandle(at: mapping.viewPoint(point)) {
            gesture = .resize(index)
            return
        }
        if let hit, hit.tool == .stamp, session.tool != .crop, !event.modifierFlags.contains(.shift) {
            if !session.selection.contains(hit.id) { session.selection = [hit.id] }
            // Stamp bodies and labels select on click and move on drag. Pointer
            // creation is reserved for the selected stamp's dedicated handle.
            gesture = .move
            needsDisplay = true
            return
        }
        if session.tool == .select || (hit != nil && session.tool != .crop) {
            beginSelectionGesture(hit: hit, extending: event.modifierFlags.contains(.shift))
            return
        }

        beginDrawing(at: point)
    }

    private func resizeHandle(at viewPoint: CGPoint) -> Int? {
        if let chrome = textSelectionChrome {
            return chrome.resizeRegions(editing: isEditingText).filter { $0.rect.contains(viewPoint) }.min {
                hypot($0.center.x - viewPoint.x, $0.center.y - viewPoint.y)
                    < hypot($1.center.x - viewPoint.x, $1.center.y - viewPoint.y)
            }?.index
        }
        return handles().firstIndex {
            let p = transform.viewPoint($0)
            return hypot(p.x - viewPoint.x, p.y - viewPoint.y) <= 8
        }
    }

    private func beginDoubleClickEditing(hit: Markup?, at point: CGPoint) -> Bool {
        if let hit, [.text, .stamp].contains(hit.tool) {
            clearGesture()
            beginTextEditing(hit)
            return true
        }
        guard hit == nil else { return false }
        let mark = Markup(
            tool: .text,
            points: [point, CGPoint(x: point.x + 260, y: point.y + max(40, session.strokeWidth * 5))],
            color: session.color, size: session.strokeWidth)
        clearGesture()
        beginTextEditing(mark)
        return true
    }

    private func beginSelectionGesture(hit: Markup?, extending: Bool) {
        if let hit {
            if extending {
                if session.selection.contains(hit.id) {
                    session.selection.remove(hit.id)
                } else {
                    session.selection.insert(hit.id)
                }
            } else if !session.selection.contains(hit.id) {
                session.selection = [hit.id]
            }
            gesture = .move
        } else {
            if !extending { session.selection.removeAll() }
            gestureSelection = session.selection
            gesture = .marquee
        }
        needsDisplay = true
    }

    private func beginDrawing(at point: CGPoint) {
        session.selection.removeAll()
        if session.tool == .crop {
            gesture = .crop
            needsDisplay = true
            return
        }
        var mark = Markup(
            tool: session.tool, points: [point, point], color: session.color,
            size: session.strokeWidth, stamp: session.stamp)
        if mark.tool == .text {
            mark.points[1] = CGPoint(x: point.x + 260, y: point.y + max(40, mark.size * 5))
            clearGesture()
            beginTextEditing(mark)
            return
        }
        if mark.tool == .stamp {
            let diameter: CGFloat = 60
            mark.points = [
                CGPoint(x: point.x - diameter / 2, y: point.y - diameter / 2),
                CGPoint(x: point.x + diameter / 2, y: point.y + diameter / 2),
            ]
        }
        if [.pen, .highlight].contains(mark.tool) { mark.points = [point] }
        session.document.annotations.append(mark)
        // A new stamp stays unselected until the user clicks it again. Its
        // label and pointer controls belong to selection, not placement.
        if mark.tool != .stamp { session.selection = [mark.id] }
        gesture = .draw(mark.id)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if textWidthGesture != nil {
            resizeEditingText(to: convert(event.locationInWindow, from: nil))
            NSCursor.resizeLeftRight.set()
            autoscroll(with: event)
            return
        }
        guard let gesture, let original = gestureDocument else { return }
        let point = transform.imagePoint(convert(event.locationInWindow, from: nil))
        lastPoint = point
        if hypot(point.x - startPoint.x, point.y - startPoint.y) * transform.zoom >= 4 {
            draggedBeyondClick = true
        }

        switch gesture {
        case .draw(let id):
            guard updateDrawing(id: id, to: point, modifiers: event.modifierFlags) else { return }
        case .stampPointer(let id):
            guard updateStampPointer(id: id, to: point, in: original) else { return }
        case .move:
            moveSelection(to: point, in: original)
        case .resize(let handle):
            resizeSelection(using: handle, to: point, in: original, modifiers: event.modifierFlags)
        case .marquee:
            let selectionRect = rect(between: startPoint, and: point)
            dragRect = selectionRect
            session.selection = gestureSelection.union(
                original.annotations.filter { selectionRect.intersects($0.visualBounds) }.map(\.id)
            )
        case .crop:
            dragRect = rect(between: startPoint, and: point).intersection(original.canvas)
        }

        if case .resize(let index) = gesture { resizeCursor(for: index).set() }
        if case .move = gesture, selectedMarks.contains(where: { $0.tool == .stamp }) { NSCursor.closedHand.set() }
        needsDisplay = true
        autoscroll(with: event)
    }

    private func updateDrawing(id: UUID, to pointer: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let index = session.document.annotations.firstIndex(where: { $0.id == id }) else { return false }
        let tool = session.document.annotations[index].tool
        var point = pointer
        if modifiers.contains(.shift), tool != .stamp {
            point = constrained(point, from: startPoint, angular: [.arrow, .line].contains(tool))
        }

        switch tool {
        case .pen, .highlight:
            let previous = session.document.annotations[index].points.last ?? point
            if hypot(point.x - previous.x, point.y - previous.y) * transform.zoom >= 1 {
                session.document.annotations[index].points.append(point)
            }
        case .stamp:
            if draggedBeyondClick {
                session.document.annotations[index] = stampWithPointer(
                    session.document.annotations[index], toward: point)
            }
        default:
            session.document.annotations[index].points[1] = point
        }
        return true
    }

    private func updateStampPointer(id: UUID, to point: CGPoint, in original: EditorDocument) -> Bool {
        guard draggedBeyondClick,
            let mark = original.annotations.first(where: { $0.id == id }),
            let index = session.document.annotations.firstIndex(where: { $0.id == id })
        else { return false }
        session.document.annotations[index] = stampWithPointer(mark, toward: point)
        return true
    }

    private func moveSelection(to point: CGPoint, in original: EditorDocument) {
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        session.document.annotations = original.annotations.map {
            session.selection.contains($0.id) ? $0.translated(dx: dx, dy: dy) : $0
        }
    }

    private func resizeSelection(
        using handle: Int, to pointer: CGPoint, in original: EditorDocument,
        modifiers: NSEvent.ModifierFlags
    ) {
        let items = original.annotations.filter { session.selection.contains($0.id) }
        if items.count == 1, let item = items.first {
            if [.arrow, .line].contains(item.tool) {
                resizeEndpoint(of: item, handle: handle, to: pointer, modifiers: modifiers)
                return
            }
            if item.tool == .text {
                let originalHandle: CGPoint
                if handle >= 4 {
                    let size = item.localSize
                    originalHandle = TextAnnotationGeometry.worldPoint(
                        CGPoint(x: handle == 4 ? 0 : size.width, y: size.height / 2), in: item)
                } else {
                    let box = item.bounds
                    originalHandle =
                        [
                            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
                        ][handle]
                }
                let adjusted = CGPoint(
                    x: originalHandle.x + pointer.x - startPoint.x,
                    y: originalHandle.y + pointer.y - startPoint.y)
                let updated =
                    handle >= 4
                    ? TextAnnotationGeometry.reflowed(
                        item, draggingLeftEdge: handle == 4, to: adjusted, canvas: original.canvas)
                    : TextAnnotationGeometry.scaled(item, corner: handle, to: adjusted, canvas: original.canvas)
                replaceAnnotation(updated)
                return
            }
        }

        guard let source = items.reduce(nil as CGRect?, { $0?.union($1.bounds) ?? $1.bounds }) else { return }
        let corners = [
            CGPoint(x: source.minX, y: source.minY), CGPoint(x: source.maxX, y: source.minY),
            CGPoint(x: source.maxX, y: source.maxY), CGPoint(x: source.minX, y: source.maxY),
        ]
        let opposite = corners[(handle + 2) % 4]
        let point =
            modifiers.contains(.shift)
            ? constrained(pointer, from: opposite, angular: false)
            : pointer
        var target = rect(between: opposite, and: point)
        target.size.width = max(1, target.width)
        target.size.height = max(1, target.height)
        session.document.annotations = original.annotations.map {
            session.selection.contains($0.id) ? $0.resized(from: source, to: target) : $0
        }
    }

    private func resizeEndpoint(
        of item: Markup, handle: Int, to pointer: CGPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        let endpoint = handle == 0 ? 0 : item.points.count - 1
        let anchor = item.points[endpoint == 0 ? item.points.count - 1 : 0]
        let point = modifiers.contains(.shift) ? constrained(pointer, from: anchor, angular: true) : pointer
        var updated = item
        updated.points[endpoint] = point
        replaceAnnotation(updated)
    }

    private func replaceAnnotation(_ annotation: Markup) {
        guard let index = session.document.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        session.document.annotations[index] = annotation
    }

    override func mouseUp(with event: NSEvent) {
        defer { refreshCursor() }
        if let editing = textWidthGesture {
            textWidthGesture = nil
            if let mark = textMarkup, mark.points != editing.original.mark.points {
                textHistory.beginUndoGrouping()
                registerTextGeometryUndo(editing.original)
                textHistory.endUndoGrouping()
            }
            synchronizeTextEditorPosition()
            if let editor = textEditor, window?.firstResponder !== editor { window?.makeFirstResponder(editor) }
            return
        }
        guard let gesture, let old = gestureDocument else { return }
        var name = "Draw Annotation"
        switch gesture {
        case .draw(let id):
            if let index = session.document.annotations.firstIndex(where: { $0.id == id }) {
                let mark = session.document.annotations[index]
                if [.pen, .highlight].contains(mark.tool) && mark.points.count == 1 {
                    session.document.annotations[index].points.append(mark.points[0])
                } else if mark.tool != .stamp && hypot(mark.bounds.width, mark.bounds.height) < 1 {
                    session.document.annotations.remove(at: index)
                }
            }
        case .move: name = "Move Annotations"
        case .stampPointer: name = "Change Stamp Pointer"
        case .resize: name = "Resize Annotations"
        case .crop:
            name = "Crop Image"
            if let dragRect, dragRect.width >= 2 && dragRect.height >= 2 { session.document.crop(to: dragRect) }
        case .marquee:
            clearGesture()
            session.onChange?()
            return
        }
        if case .crop = gesture {
        } else if old != session.document {
            if case .draw(let id) = gesture,
                let created = session.document.annotations.first(where: { $0.id == id })
            {
                session.document.expandCanvas(toInclude: created.visualBounds)
            } else {
                for item in selectedMarks { session.document.expandCanvas(toInclude: item.visualBounds) }
            }
        }
        let isSingleClickDrawing: Bool
        if case .draw = gesture {
            isSingleClickDrawing = startPoint == lastPoint && old != session.document
        } else {
            isSingleClickDrawing = false
        }
        let oldSelection = gestureSelection
        clearGesture()
        if isSingleClickDrawing {
            // Wait through the system double-click interval before recording a dot/stamp.
            // The next command flushes this boundary immediately; double-click can discard it.
            pendingClick = (old, session.document, oldSelection)
            let work = DispatchWorkItem { [weak self] in self?.finishPendingClick() }
            pendingClickCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.05, execute: work)
            session.onChange?()
        } else {
            session.commit(from: old, name: name)
        }
    }
    private func clearPendingClick() {
        pendingClickCommit?.cancel()
        pendingClickCommit = nil
        pendingClick = nil
    }
    private func finishPendingClick() {
        guard let pendingClick else { return }
        clearPendingClick()
        if session.document == pendingClick.after { session.commit(from: pendingClick.before, name: "Draw Annotation") }
    }
    private func clearGesture() {
        gesture = nil
        gestureDocument = nil
        gestureTransform = nil
        dragRect = nil
        needsDisplay = true
    }
    private func stampWithPointer(_ mark: Markup, toward point: CGPoint) -> Markup {
        let local = point.applying(mark.stampTransform.inverted())
        let circle = mark.stampLocalCircleBounds
        if hypot(local.x - circle.midX, local.y - circle.midY) < circle.width * 0.25 {
            var result = mark
            result.tail = false
            result.tailDirection = nil
            return result
        }
        let octant = Int((atan2(local.y - circle.midY, local.x - circle.midX) / (.pi / 4)).rounded())
        var result = mark
        result.tail = true
        result.tailDirection = (octant + 8) % 8
        return result
    }
    private func rect(between a: CGPoint, and b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    private func constrained(_ p: CGPoint, from anchor: CGPoint, angular: Bool) -> CGPoint {
        let dx = p.x - anchor.x
        let dy = p.y - anchor.y
        if angular {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
    }

    private func beginTextEditing(_ mark: Markup) {
        textHistory.removeAllActions()
        textDocument = session.document
        textMarkup = mark
        textWidthGesture = nil
        textEditorPositionOffset = .zero
        session.selection = [mark.id]
        let initialText =
            mark.tool == .stamp && mark.text.isEmpty
            ? ["Approved", "Rejected", "Question", "Attention", "Perfect"][max(0, min(4, mark.stamp))]
            : mark.text
        let localSize = mark.localSize
        var localRect = CGRect(origin: .zero, size: localSize)
        if mark.tool == .stamp {
            var preview = mark
            preview.text = initialText
            localRect = TextAnnotationGeometry.stampEditingRect(preview)
        }
        // Keep the local wrapping width after rotation/reflection. An upright editing
        // surface centered over the transformed text region supports native IME behavior.
        let center = transform.viewPoint(
            TextAnnotationGeometry.worldPoint(CGPoint(x: localRect.midX, y: localRect.midY), in: mark))
        let zoom = max(0.01, session.zoom)
        textEditingZoom = zoom
        textEditingCenter = CGPoint(x: localRect.midX, y: localRect.midY)
        let width = max(1, localRect.width * zoom)
        let height = (mark.tool == .stamp ? localRect.height : max(20, localRect.height)) * zoom
        let extra: CGFloat = mark.tool == .stamp ? 0 : 3
        let frame = CGRect(
            x: center.x - width / 2 - extra, y: center.y - height / 2 - extra,
            width: width + extra * 2, height: height + extra * 2)
        let editor = AnnotationTextEditor.make(
            for: mark, frame: frame, zoom: zoom, text: initialText, delegate: self
        ) { [weak self] editor in
            guard let self, let chrome = self.textSelectionChrome else { return [] }
            return chrome.widthHitRects.map { editor.convert($0, from: self) }
        }
        addSubview(editor)
        textEditor = editor
        if mark.tool != .stamp { session.tool = mark.tool }
        window?.makeFirstResponder(editor)
        let length = (initialText as NSString).length
        editor.setSelectedRange(
            mark.tool == .stamp ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0))
        needsDisplay = true
        refreshCursor()
    }

    private func resizeEditingText(to point: CGPoint) {
        guard let editing = textWidthGesture, let editor = textEditor, let current = textMarkup else { return }
        let originalSize = editing.original.mark.localSize
        let delta = (point.x - editing.start.x) / textEditingZoom
        let localX = editing.left ? delta : originalSize.width + delta
        var preview = editing.original.mark
        // This copy is only used for measuring the native text. In particular, an
        // IME's marked string must not become part of textMarkup or the document.
        preview.text = editor.string
        let target = TextAnnotationGeometry.worldPoint(CGPoint(x: localX, y: originalSize.height / 2), in: preview)
        var resized = TextAnnotationGeometry.reflowed(
            preview, draggingLeftEdge: editing.left, to: target, canvas: textDocument?.canvas)
        resized.text = current.text
        let size = resized.localSize
        if abs(size.width - originalSize.width) < 0.000_001 {
            applyTextEditingGeometry(editing.original)
            return
        }
        textMarkup = resized
        let width = size.width * textEditingZoom + 6
        let origin = CGPoint(
            x: editing.left ? editing.original.frame.maxX - width : editing.original.frame.minX,
            y: editing.original.frame.minY)
        layoutEditingText(at: origin)
    }

    private func registerTextGeometryUndo(_ geometry: TextEditingGeometry) {
        textHistory.registerUndo(withTarget: self) { target in
            guard let editor = target.textEditor, let mark = target.textMarkup, mark.id == geometry.mark.id else {
                return
            }
            let inverse = TextEditingGeometry(
                mark: mark, frame: editor.frame, center: target.textEditingCenter,
                positionOffset: target.textEditorPositionOffset)
            target.registerTextGeometryUndo(inverse)
            target.applyTextEditingGeometry(geometry)
        }
        textHistory.setActionName("Resize Text")
    }

    private func applyTextEditingGeometry(_ geometry: TextEditingGeometry) {
        guard let editor = textEditor else { return }
        textMarkup = geometry.mark
        textEditingCenter = geometry.center
        textEditorPositionOffset = geometry.positionOffset
        editor.minSize = CGSize(width: geometry.frame.width, height: 0)
        editor.maxSize = CGSize(width: geometry.frame.width, height: max(100_000, geometry.frame.height))
        editor.textContainer?.containerSize = CGSize(width: max(1, geometry.frame.width - 6), height: 100_000)
        editor.frame = geometry.frame
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        synchronizeTextEditorPosition()
        editor.needsDisplay = true
        needsDisplay = true
        refreshCursor()
    }

    private func layoutEditingText(at origin: CGPoint? = nil) {
        guard let editor = textEditor, let mark = textMarkup, mark.tool == .text,
            let container = editor.textContainer
        else { return }
        let local = mark.localSize
        guard
            let measured = TextAnnotationGeometry.measuredHeight(
                text: editor.string, width: local.width, fontSize: max(1, mark.size * 4))
        else { return }
        let frameWidth = max(1, local.width * textEditingZoom) + 6
        let frameOrigin = origin ?? editor.frame.origin
        editor.minSize = CGSize(width: frameWidth, height: 0)
        editor.maxSize = CGSize(width: frameWidth, height: 1_000_000)
        editor.setFrameSize(CGSize(width: frameWidth, height: editor.frame.height))
        container.containerSize = CGSize(width: frameWidth - 6, height: 1_000_000)
        editor.layoutManager?.ensureLayout(for: container)
        let nativeHeight = (editor.layoutManager?.usedRect(for: container).height ?? 0) / textEditingZoom + 8
        let height = min(65_536, max(measured, nativeHeight))
        editor.frame = CGRect(
            origin: frameOrigin, size: CGSize(width: frameWidth, height: height * textEditingZoom + 6))
        textEditingCenter = CGPoint(x: local.width / 2, y: height / 2)
        let center = transform.viewPoint(TextAnnotationGeometry.worldPoint(textEditingCenter, in: mark))
        textEditorPositionOffset = CGPoint(x: editor.frame.midX - center.x, y: editor.frame.midY - center.y)
        editor.needsDisplay = true
        needsDisplay = true
        refreshCursor()
    }

    /// A marked Japanese composition must stay in NSTextView until the input method commits it.
    @discardableResult func finishTextEditing() -> Bool {
        finishPendingClick()
        guard let editor = textEditor, var mark = textMarkup, let old = textDocument else { return true }
        guard !editor.hasMarkedText() else { return false }
        let unchanged = mark.text == editor.string && old.annotations.first(where: { $0.id == mark.id }) == mark
        mark.text = editor.string
        if !unchanged && mark.tool == .text {
            let localSize = mark.localSize
            guard let container = editor.textContainer,
                let measured = TextAnnotationGeometry.measuredHeight(
                    text: mark.text, width: localSize.width, fontSize: max(1, mark.size * 4))
            else {
                NSSound.beep()
                return false
            }
            editor.layoutManager?.ensureLayout(for: container)
            let nativeHeight = (editor.layoutManager?.usedRect(for: container).height ?? 0) / textEditingZoom + 8
            let height = max(measured, nativeHeight)
            guard height.isFinite, height <= 65_536 else {
                NSSound.beep()
                return false
            }
            mark = TextAnnotationGeometry.resized(
                mark, to: CGSize(width: localSize.width, height: height))
        }
        var candidate = session.document
        if !unchanged {
            if !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mark.tool == .stamp {
                if let index = candidate.annotations.firstIndex(where: { $0.id == mark.id }) {
                    candidate.annotations[index] = mark
                } else {
                    candidate.annotations.append(mark)
                }
                candidate.expandCanvas(toInclude: mark.visualBounds)
            } else {
                candidate.annotations.removeAll { $0.id == mark.id }
            }
            // Validate before removing the native editor so oversized input stays
            // editable and its last safe document remains available to autosave.
            guard candidate.canvas.width <= 65_536, candidate.canvas.height <= 65_536 else {
                NSSound.beep()
                return false
            }
            do {
                try candidate.validate()
            } catch {
                NSSound.beep()
                return false
            }
        }
        editor.delegate = nil
        editor.removeFromSuperview()
        textEditor = nil
        textMarkup = nil
        textDocument = nil
        textWidthGesture = nil
        textEditorPositionOffset = .zero
        if unchanged {
            window?.makeFirstResponder(self)
            needsDisplay = true
            refreshCursor()
            return true
        }
        session.document = candidate
        window?.makeFirstResponder(self)
        session.commit(from: old, name: mark.tool == .stamp ? "Edit Stamp Label" : "Edit Text")
        needsDisplay = true
        refreshCursor()
        return true
    }
    func synchronizeTextEditorPosition() {
        guard let editor = textEditor, let mark = textMarkup else { return }
        let center = transform.viewPoint(TextAnnotationGeometry.worldPoint(textEditingCenter, in: mark))
        editor.setFrameOrigin(
            CGPoint(
                x: center.x + textEditorPositionOffset.x - editor.frame.width / 2,
                y: center.y + textEditorPositionOffset.y - editor.frame.height / 2))
    }
    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor, var mark = textMarkup else { return }
        if mark.tool == .text {
            layoutEditingText()
            return
        }
        // Grow only the transient editor to the left. Marked IME text stays out of
        // the document, and the circle remains fixed as the label gets longer.
        mark.text = editor.string
        let label = TextAnnotationGeometry.stampEditingRect(mark)
        textEditingCenter = CGPoint(x: label.midX, y: label.midY)
        let size = CGSize(width: label.width * textEditingZoom, height: label.height * textEditingZoom)
        editor.minSize = size
        editor.maxSize = CGSize(width: size.width, height: 100_000)
        editor.setFrameSize(size)
        synchronizeTextEditorPosition()
        editor.needsDisplay = true
        needsDisplay = true
        refreshCursor()
    }
    func undoManager(for view: NSTextView) -> UndoManager? { textHistory }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textMarkup?.tool == .stamp,
            commandSelector == #selector(insertNewline(_:)) || commandSelector == #selector(cancelOperation(_:))
        {
            if commandSelector == #selector(insertNewline(_:)),
                NSApp.currentEvent?.modifierFlags.contains(.option) == true
            {
                return false
            }
            guard !textView.hasMarkedText() else { return false }
            return finishStampLabelEditing()
        }
        if commandSelector == #selector(cancelOperation(_:)) { return finishTextEditing() }
        return false
    }

    private func finishStampLabelEditing() -> Bool {
        guard finishTextEditing() else { return false }
        session.selection.removeAll()
        session.onChange?()
        needsDisplay = true
        refreshCursor()
        return true
    }

    override func keyDown(with event: NSEvent) {
        finishPendingClick()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains([.command, .option]), let key = event.charactersIgnoringModifiers?.lowercased(),
            onToolShortcut?(key) == true
        {
            return
        }
        let amount: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: session.deleteSelection()
        case 123: session.moveSelection(dx: -amount, dy: 0)
        case 124: session.moveSelection(dx: amount, dy: 0)
        case 125: session.moveSelection(dx: 0, dy: amount)
        case 126: session.moveSelection(dx: 0, dy: -amount)
        case 53: cancelOperation(nil)
        case 36, 76:
            if selectedMarks.count == 1, let mark = selectedMarks.first, [.text, .stamp].contains(mark.tool) {
                beginTextEditing(mark)
            }
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if let editing = textWidthGesture {
            textWidthGesture = nil
            applyTextEditingGeometry(editing.original)
            return
        }
        if isEditingText {
            _ = textMarkup?.tool == .stamp ? finishStampLabelEditing() : finishTextEditing()
            return
        }
        if let pendingClick {
            session.document = pendingClick.before
            session.selection = pendingClick.selection
            clearPendingClick()
            needsDisplay = true
            session.onChange?()
            return
        }
        if let old = gestureDocument {
            session.document = old
            session.selection = gestureSelection
            clearGesture()
            session.onChange?()
        } else {
            session.selection.removeAll()
            session.onChange?()
        }
    }
    @objc func copy(_ sender: Any?) {
        finishPendingClick()
        onCopy?()
    }
    @objc func paste(_ sender: Any?) {
        finishPendingClick()
        onPaste?()
    }
    @objc func cut(_ sender: Any?) {
        finishPendingClick()
        onCopy?()
        session.deleteSelection()
    }
    override func selectAll(_ sender: Any?) {
        finishPendingClick()
        session.selection = Set(session.document.annotations.map(\.id))
        session.onChange?()
    }
    @objc func delete(_ sender: Any?) {
        finishPendingClick()
        session.deleteSelection()
    }
    @objc func undo(_ sender: Any?) {
        finishPendingClick()
        if let editor = textEditor {
            editor.breakUndoCoalescing()
            textHistory.undo()
        } else {
            session.history.undo()
        }
    }
    @objc func redo(_ sender: Any?) {
        finishPendingClick()
        if let editor = textEditor {
            editor.breakUndoCoalescing()
            textHistory.redo()
        } else {
            session.history.redo()
        }
    }
    @objc func duplicate(_ sender: Any?) {
        finishPendingClick()
        session.duplicateSelection()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(delete(_:)), #selector(cut(_:)), #selector(duplicate(_:))].contains(menuItem.action) {
            return !session.selection.isEmpty
        }
        if menuItem.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if menuItem.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        return true
    }
    override func magnify(with event: NSEvent) {
        handleMagnification(event.magnification, phase: event.phase)
    }
    func handleMagnification(_ magnification: CGFloat, phase: NSEvent.Phase) {
        guard finishTextEditing(), gesture == nil else { return }
        zoomQualityReset?.cancel()
        zoomQualityReset = nil
        interactiveZoom = !phase.contains(.ended) && !phase.contains(.cancelled)
        if phase.isEmpty {
            let reset = DispatchWorkItem { [weak self] in
                self?.interactiveZoom = false
                self?.needsDisplay = true
            }
            zoomQualityReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: reset)
        }
        onZoom?(session.zoom * (1 + magnification))
        needsDisplay = true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard finishTextEditing() else { return false }
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            let url = urls.first
        {
            onOpenURL?(url)
            return onOpenURL != nil
        }
        do {
            if let image = try ImageService.image(from: board) {
                onDropImage?(image)
                return onDropImage != nil
            }
        } catch { NSApp.presentError(error) }
        return false
    }
}
