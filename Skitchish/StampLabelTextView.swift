import AppKit

/// Native editing over the same label plate used for the flattened image.
final class StampLabelTextView: NSTextView {
    var labelDiameter: CGFloat = 40
    var labelZoom: CGFloat = 1

    func resizeToFitText(minimumSize: CGSize) {
        minSize = minimumSize
        maxSize = CGSize(width: minimumSize.width, height: 100_000)
        setFrameSize(minimumSize)
        guard let layoutManager, let textContainer else { return }
        // Font fallback and line rounding vary with point size. Measure the actual
        // zoomed editor instead of scaling the saved label's text metrics.
        layoutManager.ensureLayout(for: textContainer)
        let textBottom = max(
            layoutManager.usedRect(for: textContainer).maxY,
            layoutManager.extraLineFragmentRect.maxY)
        let height = max(minimumSize.height, ceil(textContainerOrigin.y + textBottom + textContainerInset.height))
        let fitted = CGSize(width: minimumSize.width, height: height)
        minSize = fitted
        setFrameSize(fitted)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.scaleBy(x: labelZoom, y: labelZoom)
            StampLabelStyle(diameter: labelDiameter).drawBackground(
                in: context,
                rect: CGRect(x: 0, y: 0, width: bounds.width / labelZoom, height: bounds.height / labelZoom))
            context.restoreGState()
        }
        super.draw(dirtyRect)
    }
}
