import AppKit

/// Decorates native glyph drawing without changing text storage, shaping, or IME layout.
final class OutlinedTextLayoutManager: NSLayoutManager {
    override func showCGGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>,
        count glyphCount: Int, font: NSFont, textMatrix: CGAffineTransform,
        attributes: [NSAttributedString.Key: Any], in context: CGContext
    ) {
        guard glyphCount > 0 else { return }
        context.saveGState()
        let shadow = EditorRenderer.annotationTextShadow(fontSize: font.pointSize)
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(font.pointSize * EditorRenderer.textOutlinePercent / 100)
        context.setLineJoin(.round)
        context.setTextDrawingMode(.fillStroke)
        context.setShadow(
            offset: shadow.shadowOffset, blur: shadow.shadowBlurRadius,
            color: shadow.shadowColor?.cgColor)
        var halo = attributes
        halo[.foregroundColor] = NSColor.white
        halo[.strokeColor] = NSColor.white
        halo[.strokeWidth] = -EditorRenderer.textOutlinePercent
        super.showCGGlyphs(
            glyphs, positions: positions, count: glyphCount, font: font,
            textMatrix: textMatrix, attributes: halo, in: context)
        context.restoreGState()

        // Fill again over the inward half of the white stroke. A single native
        // fill+stroke pass otherwise erases thin label stems at small font sizes.
        context.saveGState()
        context.setTextDrawingMode(.fill)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.textMatrix = textMatrix
        var face = attributes
        face.removeValue(forKey: .strokeColor)
        face.removeValue(forKey: .strokeWidth)
        face.removeValue(forKey: .shadow)
        super.showCGGlyphs(
            glyphs, positions: positions, count: glyphCount, font: font,
            textMatrix: textMatrix, attributes: face, in: context)
        context.restoreGState()
    }
}
