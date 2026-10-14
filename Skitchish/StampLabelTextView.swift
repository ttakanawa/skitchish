import AppKit

/// Native editing over the same label plate used for the flattened image.
final class StampLabelTextView: NSTextView {
    var labelDiameter: CGFloat = 40
    var labelZoom: CGFloat = 1

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
