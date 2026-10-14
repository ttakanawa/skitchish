import AppKit
import CoreText

/// Shared screen, export, and native-editor appearance for a stamp's label frame.
struct StampLabelStyle {
    private static let textSizeCache: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 512
        cache.totalCostLimit = 2_000_000
        return cache
    }()
    let fontSize: CGFloat
    let paddingX: CGFloat
    let paddingY: CGFloat
    let borderWidth: CGFloat
    let cornerRadius: CGFloat

    init(diameter: CGFloat) {
        fontSize = max(1, diameter * 0.38)
        paddingX = max(1, diameter * 0.15)
        paddingY = max(1, diameter * 0.08)
        borderWidth = max(0.5, diameter * 0.035)
        cornerRadius = max(1, diameter * 0.1)
    }

    /// Measure shaped fallback-font lines, not NSString's tighter glyph bounding box.
    /// The returned text area must fit the complete Core Text frame used for export.
    func textSize(for text: String) -> CGSize {
        let key = "\(fontSize):\(text)" as NSString
        if let cached = Self.textSizeCache.object(forKey: key) { return cached.sizeValue }
        let font = EditorRenderer.stampLabelFont(size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .right
        let string = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [.font: font, .paragraphStyle: paragraph])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let unlimited = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let natural = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, unlimited, nil)
        let width = max(1, ceil(natural.width))
        let wrapped = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil,
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), nil)
        var height = max(1, ceil(wrapped.height))
        // Reserve a full baseline box for each explicit line, including a trailing
        // empty one. Native stamp editing disables extra fallback-font leading.
        let lineCount = text.components(separatedBy: "\n").count
        let nativeLineHeight = ceil(font.ascender - font.descender + font.leading)
        height = max(height, nativeLineHeight * CGFloat(lineCount))
        // Fractional metrics can still put the final baseline just outside a CTFrame.
        // Check coverage instead of assuming that a rounded suggested height suffices.
        for _ in 0..<Int(max(2, nativeLineHeight * 2)) {
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.location + visible.length >= string.length { break }
            height += 1
        }
        let result = CGSize(width: width, height: height)
        Self.textSizeCache.setObject(NSValue(size: result), forKey: key, cost: text.utf8.count)
        return result
    }

    func drawBackground(in context: CGContext, rect: CGRect) {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(NSColor.black.cgColor)
        context.setStrokeColor(NSColor.white.cgColor)
        let stroke = min(borderWidth, min(rect.width, rect.height))
        context.setLineWidth(stroke)
        let inset = rect.insetBy(dx: stroke / 2, dy: stroke / 2)
        let radius = max(0, cornerRadius - stroke / 2)
        context.addPath(CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.drawPath(using: .fillStroke)
    }
}
