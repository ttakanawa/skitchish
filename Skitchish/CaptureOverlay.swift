import AppKit
import ScreenCaptureKit

@MainActor final class CaptureCountdown: NSObject {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        panel = NSPanel(
            contentRect: CGRect(x: visible.maxX - 270, y: visible.maxY - 100, width: 246, height: 72),
            styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "Skitchish Capture"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let stack = NSStackView(views: [label, button])
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }
    }

    func show(seconds: Int) {
        label.stringValue = "Capturing in \(seconds)…"
        panel.orderFrontRegardless()
    }
    func close() {
        panel.orderOut(nil)
        panel.close()
    }
    @objc private func cancel() { onCancel() }
}

enum CaptureSelection {
    case region(CGRect)
    case window(SCWindow)
}

@MainActor final class CaptureSelector {
    private let candidates: [SCWindow]?
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CaptureSelection?, Never>?
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var hovered: SCWindow?

    init(windows: [SCWindow]?) { candidates = windows }

    func select() async -> CaptureSelection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let panel = CapturePanel(
                    contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                panel.title = "Select Capture Area"
                panel.setAccessibilityLabel("Select Capture Area")
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.level = .screenSaver
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.acceptsMouseMovedEvents = true
                let view = CaptureSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.owner = self
                panel.contentView = view
                panels.append(panel)
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(view)
            }
            NSCursor.crosshair.push()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func cancel() { finish(nil) }

    fileprivate func down() {
        anchor = NSEvent.mouseLocation
        current = anchor
        update()
    }

    fileprivate func move() {
        current = NSEvent.mouseLocation
        if let candidates {
            let point = CaptureService.quartzPoint(NSEvent.mouseLocation)
            hovered = candidates.first { $0.frame.contains(point) }
        }
        update()
    }

    fileprivate func up() {
        move()
        if candidates != nil {
            if let hovered { finish(.window(hovered)) }
        } else if let selectionRect, selectionRect.width >= 2, selectionRect.height >= 2 {
            finish(.region(CaptureService.quartzRect(selectionRect)))
        }
    }

    fileprivate var selectionRect: CGRect? {
        if candidates != nil, let hovered {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return CGRect(
                x: hovered.frame.minX, y: top - hovered.frame.maxY,
                width: hovered.frame.width, height: hovered.frame.height)
        }
        guard let anchor, let current else { return nil }
        return CGRect(
            x: min(anchor.x, current.x), y: min(anchor.y, current.y),
            width: abs(anchor.x - current.x), height: abs(anchor.y - current.y))
    }

    fileprivate var prompt: String {
        candidates == nil ? "Drag to capture a region • Esc to cancel" : "Click a window to capture • Esc to cancel"
    }

    private func update() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }

    private func finish(_ result: CaptureSelection?) {
        guard let continuation else { return }
        self.continuation = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        NSCursor.pop()
        continuation.resume(returning: result)
    }
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor private final class CaptureSelectionView: NSView {
    weak var owner: CaptureSelector?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let rect = owner?.selectionRect, let window {
            let local = window.convertFromScreen(rect)
            NSGraphicsContext.current?.cgContext.clear(local)
            // Fully transparent window pixels pass clicks to the application below.
            // Keep the highlighted window almost clear while retaining selection input.
            NSColor.black.withAlphaComponent(0.01).setFill()
            local.fill()
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: local.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let prompt = owner?.prompt ?? ""
        let size = (prompt as NSString).size(withAttributes: attributes)
        (prompt as NSString).draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 80), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { owner?.down() }
    override func mouseDragged(with event: NSEvent) { owner?.move() }
    override func mouseMoved(with event: NSEvent) { owner?.move() }
    override func mouseUp(with event: NSEvent) { owner?.up() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.cancel() }
    }
}
