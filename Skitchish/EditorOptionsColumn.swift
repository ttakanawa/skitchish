import AppKit

/// The secondary toolbar stays in the same column as the annotation tools.
/// Track the adjacent 40 points too, so crossing the edge does not dismiss it.
final class EditorOptionsColumn: NSStackView {
    static let exitDelay: TimeInterval = 0.4
    static let choiceDelay: TimeInterval = 0.11
    static let transitionDuration: TimeInterval = 0.24
    static let trackingMargin: CGFloat = 40

    var onClose: (() -> Void)?
    var onEscape: (() -> Void)?
    var isPinned = false {
        didSet { if isPinned { cancelPendingClose() } }
    }
    private(set) var isPresented = false
    private weak var trackingHost: NSView?
    private weak var sidebar: NSView?
    private var sidebarTrackingArea: NSTrackingArea?
    private let scheduler: DelayedActionScheduler
    private var cancelExitClose: DelayedActionScheduler.Cancellation?
    private var cancelChoiceClose: DelayedActionScheduler.Cancellation?

    override var acceptsFirstResponder: Bool { true }

    init(scheduler: DelayedActionScheduler = .mainRunLoop) {
        self.scheduler = scheduler
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        scheduler = .mainRunLoop
        super.init(coder: coder)
    }

    func configureTracking(in host: NSView, sidebar: NSView) {
        trackingHost = host
        self.sidebar = sidebar
    }

    func setPresented(_ presented: Bool) {
        isPresented = presented
        cancelPendingClose()
        updateTrackingAreas()
        if presented, let host = trackingHost, let window = host.window {
            let point = host.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if !trackingRect.contains(point) { pointerExited() }
        }
    }

    private var trackingRect: NSRect {
        guard let host = trackingHost, let sidebar else { return .zero }
        var rect = sidebar.convert(sidebar.bounds, to: host)
        rect.size.width += Self.trackingMargin
        return rect
    }

    override func updateTrackingAreas() {
        if let area = sidebarTrackingArea { trackingHost?.removeTrackingArea(area) }
        sidebarTrackingArea = nil
        if isPresented, let host = trackingHost {
            let area = NSTrackingArea(
                rect: trackingRect, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
            host.addTrackingArea(area)
            sidebarTrackingArea = area
        }
        super.updateTrackingAreas()
    }

    func pointerEntered() {
        cancelExitClose?()
        cancelExitClose = nil
    }

    func pointerExited() {
        cancelExitClose?()
        cancelExitClose = nil
        guard isPresented, !isPinned else { return }
        cancelExitClose = scheduler.schedule(Self.exitDelay) { [weak self] in
            self?.requestClose()
        }
    }

    func closeAfterChoice() {
        cancelPendingClose()
        guard isPresented, !isPinned else { return }
        cancelChoiceClose = scheduler.schedule(Self.choiceDelay) { [weak self] in
            self?.requestClose()
        }
    }

    func cancelPendingClose() {
        cancelExitClose?()
        cancelExitClose = nil
        cancelChoiceClose?()
        cancelChoiceClose = nil
    }

    private func requestClose() {
        guard isPresented, !isPinned else { return }
        onClose?()
    }

    override func mouseEntered(with event: NSEvent) { pointerEntered() }
    override func mouseExited(with event: NSEvent) { pointerExited() }
    override func mouseDown(with event: NSEvent) { requestClose() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
