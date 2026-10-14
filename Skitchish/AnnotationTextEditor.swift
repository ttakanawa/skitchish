import AppKit

/// Builds native editors with the same text and label styling as the renderer.
@MainActor
enum AnnotationTextEditor {
    static func make(
        for mark: Markup, frame: CGRect, zoom: CGFloat, text: String,
        delegate: NSTextViewDelegate, widthCursorRects: @escaping (NSTextView) -> [CGRect]
    ) -> NSTextView {
        let localSize = mark.localSize
        let diameter = min(localSize.width, localSize.height)
        let editor: NSTextView
        if mark.tool == .stamp {
            let label = StampLabelTextView(frame: frame)
            label.labelDiameter = diameter
            label.labelZoom = zoom
            label.layoutManager?.usesFontLeading = false
            editor = label
        } else {
            let inline = InlineAnnotationTextView(frame: frame)
            inline.widthCursorRects = widthCursorRects
            inline.textContainer?.replaceLayoutManager(OutlinedTextLayoutManager())
            editor = inline
        }
        editor.setAccessibilityIdentifier("annotation.text")
        editor.setAccessibilityLabel(mark.tool == .stamp ? "Stamp label" : "Annotation text")
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.font =
            mark.tool == .stamp
            ? EditorRenderer.stampLabelFont(size: max(1, diameter * 0.38) * zoom)
            : EditorRenderer.annotationFont(size: max(1, mark.size * 4) * zoom)
        let textColor = mark.tool == .stamp ? NSColor.white : mark.color.nsColor
        editor.textColor = textColor
        editor.backgroundColor = .clear
        editor.drawsBackground = false
        editor.insertionPointColor = mark.tool == .stamp ? .white : .controlAccentColor
        let labelStyle = StampLabelStyle(diameter: diameter)
        editor.textContainerInset =
            mark.tool == .stamp
            ? NSSize(width: labelStyle.paddingX * zoom, height: labelStyle.paddingY * zoom)
            : NSSize(width: 3, height: 3)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        if mark.tool == .stamp { paragraph.alignment = .right }
        editor.defaultParagraphStyle = paragraph
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.textContainer?.heightTracksTextView = false
        editor.minSize = NSSize(width: editor.frame.width, height: editor.frame.height)
        editor.maxSize = NSSize(width: editor.frame.width, height: 100_000)
        editor.autoresizingMask = []
        editor.string = text
        editor.delegate = delegate
        if let font = editor.font {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ]
            editor.textStorage?.setAttributes(
                attributes, range: NSRange(location: 0, length: (text as NSString).length))
            editor.typingAttributes = attributes
        }
        return editor
    }
}

/// Let the native field keep its I-beam and caret while the small portions of
/// its bounds shared with the width handles use the canvas's resize cursor.
private final class InlineAnnotationTextView: NSTextView {
    var widthCursorRects: ((NSTextView) -> [CGRect])?

    override func resetCursorRects() {
        super.resetCursorRects()
        for region in widthCursorRects?(self) ?? [] {
            let clipped = region.intersection(visibleRect)
            if !clipped.isEmpty { addCursorRect(clipped, cursor: .resizeLeftRight) }
        }
    }
}
