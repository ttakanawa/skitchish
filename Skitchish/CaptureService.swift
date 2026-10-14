import AppKit
import ScreenCaptureKit

enum CaptureMode: String, CaseIterable {
    case region, fullScreen, window, previousRegion, timed, menu
    var title: String {
        switch self {
        case .region: return "Region"
        case .fullScreen: return "Full Screen"
        case .window: return "Window"
        case .previousRegion: return "Previous Region"
        case .timed: return "Timed Region"
        case .menu: return "Menu Capture"
        }
    }
}

@MainActor final class CaptureService {
    private var selector: CaptureSelector?
    private var activeTask: Task<CGImage?, Error>?
    private(set) var isCapturing = false
    private var previousRegion: CGRect? {
        get {
            guard let string = UserDefaults.standard.string(forKey: "capture.previousRegion") else { return nil }
            let rect = NSRectFromString(string)
            return rect.isEmpty ? nil : rect
        }
        set { UserDefaults.standard.set(newValue.map(NSStringFromRect), forKey: "capture.previousRegion") }
    }

    func capture(mode: CaptureMode, delay: Double = 5) async throws -> CGImage? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer {
            isCapturing = false
            activeTask = nil
        }
        let task = Task { try await performCapture(mode: mode, delay: delay) }
        activeTask = task
        do {
            return try await withTaskCancellationHandler {
                let image = try await task.value
                try Task.checkCancellation()
                return task.isCancelled ? nil : image
            } onCancel: {
                task.cancel()
                Task { @MainActor in self.selector?.cancel() }
            }
        } catch is CancellationError { return nil }
    }

    private func performCapture(mode: CaptureMode, delay: Double) async throws -> CGImage? {
        try Task.checkCancellation()
        // Let the capture API request and verify its own authorization. A legacy
        // Core Graphics preflight can report unavailable access without prompting.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let captureError = error as NSError
            if captureError.domain == SCStreamErrorDomain,
                captureError.code == SCStreamError.Code.userDeclined.rawValue
            {
                throw EditorServiceError.capturePermission
            }
            throw error
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        for window in hiddenWindows { window.orderOut(nil) }
        defer {
            selector?.cancel()
            selector = nil
            NSApp.unhide(nil)
            for window in hiddenWindows { window.orderFront(nil) }
            NSApp.activate(ignoringOtherApps: true)
        }
        let target: CaptureSelection
        switch mode {
        case .fullScreen:
            let point = Self.quartzPoint(NSEvent.mouseLocation)
            guard let display = content.displays.first(where: { $0.frame.contains(point) }) ?? content.displays.first
            else {
                throw EditorServiceError.captureUnavailable
            }
            target = .region(display.frame)
        case .previousRegion:
            guard let previousRegion else { throw EditorServiceError.noPreviousRegion }
            target = .region(previousRegion)
        case .region, .timed, .menu, .window:
            let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let frontToBack = windowList.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            let order = Dictionary(frontToBack.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            let candidates = content.windows.filter {
                $0.owningApplication?.processID != ownPID && $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 1
                    && $0.frame.height > 1
            }.sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
            let selector = CaptureSelector(windows: mode == .window ? candidates : nil)
            self.selector = selector
            guard let selection = await selector.select() else { return nil }
            target = selection
            self.selector = nil
            if case .region(let region) = target { previousRegion = region }
        }
        // Restore the previous application's menu bar after our selection panels close.
        // Excluding Skitchish windows alone does not replace the foreground app's menu bar.
        NSApp.hide(nil)
        if mode == .timed || mode == .menu {
            NSApp.unhideWithoutActivation()
            let countdown = CaptureCountdown { [weak self] in self?.cancel() }
            defer { countdown.close() }
            let seconds = delay.isFinite ? max(0, min(delay, 60)) : 5
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                countdown.show(seconds: Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
                try await Task.sleep(for: .milliseconds(100))
            }
        } else {
            // Let WindowServer finish removing the selection overlay before requesting a frame.
            try await Task.sleep(for: .milliseconds(150))
        }
        try Task.checkCancellation()
        switch target {
        case .window(let window):
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
            config.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
            guard Double(config.width) * Double(config.height) <= ImageService.maximumPixelCount else {
                throw EditorServiceError.captureUnavailable
            }
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        case .region(let region):
            return try await capture(region: region, content: content, ownPID: ownPID)
        }
    }

    /// Cancels selection, the countdown, or delivery of an in-flight screenshot.
    func cancel() {
        activeTask?.cancel()
        selector?.cancel()
    }

    /// Quartz global coordinates have their origin at the primary display's top left.
    static func quartzPoint(_ appKitPoint: CGPoint) -> CGPoint {
        CaptureLayout.quartzPoint(appKitPoint, primaryDisplayTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    static func quartzRect(_ appKitRect: CGRect) -> CGRect {
        CaptureLayout.quartzRect(appKitRect, primaryDisplayTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    private func capture(region: CGRect, content: SCShareableContent, ownPID: pid_t) async throws -> CGImage {
        let displays = content.displays.filter { !$0.frame.intersection(region).isEmpty }
        guard !displays.isEmpty else { throw EditorServiceError.captureUnavailable }
        let excludedApps = content.applications.filter { $0.processID == ownPID }
        let regions = displays.map {
            display -> (display: SCDisplay, rect: CGRect, filter: SCContentFilter, scale: CGFloat) in
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            filter.includeMenuBar = true
            return (display, display.frame.intersection(region), filter, CGFloat(filter.pointPixelScale))
        }
        let layout = try CaptureLayout(regions: regions.map { ($0.rect, $0.scale) })
        var pieces: [(rect: CGRect, image: CGImage)] = []
        for region in regions {
            let config = SCStreamConfiguration()
            config.sourceRect = CaptureLayout.sourceRect(for: region.rect, on: region.display.frame)
            config.width = max(1, Int((region.rect.width * region.scale).rounded()))
            config.height = max(1, Int((region.rect.height * region.scale).rounded()))
            config.showsCursor = false
            config.shouldBeOpaque = true
            config.scalesToFit = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: region.filter, configuration: config)
            pieces.append((region.rect, image))
        }
        // A bitmap has one pixel scale. Preserve the densest display and resample lower-density parts.
        if pieces.count == 1 { return pieces[0].image }
        guard
            let context = CGContext(
                data: nil, width: layout.pixelWidth, height: layout.pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw EditorServiceError.captureUnavailable
        }
        context.interpolationQuality = .high
        for piece in pieces {
            context.draw(piece.image, in: layout.destinationRect(for: piece.rect))
        }
        guard let image = context.makeImage() else { throw EditorServiceError.captureUnavailable }
        return image
    }
}
