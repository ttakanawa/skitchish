import AppKit

struct ExportPayload {
    let image: CGImage
    let title: String
    let format: ExportFormat
}

/// Every representation comes from one rendered snapshot, never from the editable document.
struct ExportDragSnapshot {
    let fileURL: URL
    let fileData: Data
    let pngData: Data
    let tiffData: Data
    let format: ExportFormat

    init(payload: ExportPayload, temporaryRoot: URL? = nil) throws {
        format = payload.format
        pngData = try ImageService.data(payload.image, format: .png)
        tiffData = try ImageService.data(payload.image, format: .tiff)
        switch payload.format {
        case .png: fileData = pngData
        case .tiff: fileData = tiffData
        case .jpeg: fileData = try ImageService.data(payload.image, format: .jpeg)
        }
        let root =
            temporaryRoot
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Skitchish-DragExports", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent(Self.filename(title: payload.title, format: payload.format))
        do { try fileData.write(to: fileURL, options: .atomic) } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        // Do not delete this file when the drag ends or the writer is released: browser/chat
        // receivers can open its URL asynchronously. The OS manages this temporary directory.
    }

    static func filename(title: String, format: ExportFormat) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var base = title.precomposedStringWithCanonicalMapping.components(separatedBy: unsafe).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if ["png", "jpg", "jpeg", "tif", "tiff"].contains((base as NSString).pathExtension.lowercased()) {
            base = (base as NSString).deletingPathExtension
        }
        while base.utf8.count > 180 { base.removeLast() }
        if base.isEmpty { base = "Image" }
        return base + "." + format.fileExtension
    }

    func write(to url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try fileData.write(to: url, options: .atomic)
    }
}

/// One item offers both a file promise for Finder and ready-to-read content for chat/browser drops.
final class ExportImageDragProvider: NSFilePromiseProvider {
    let snapshot: ExportDragSnapshot
    private let retainedDelegate: ExportImagePromiseDelegate

    init(snapshot: ExportDragSnapshot) {
        self.snapshot = snapshot
        retainedDelegate = ExportImagePromiseDelegate(snapshot: snapshot)
        super.init()
        fileType = snapshot.format.contentType.identifier
        delegate = retainedDelegate
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        for type in [NSPasteboard.PasteboardType.fileURL, .png, .tiff] where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL: return (snapshot.fileURL as NSURL).pasteboardPropertyList(forType: type)
        case .png: return snapshot.pngData
        case .tiff: return snapshot.tiffData
        default: return super.pasteboardPropertyList(forType: type)
        }
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard)
        -> NSPasteboard.WritingOptions
    {
        if [.fileURL, .png, .tiff].contains(type) { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

private final class ExportImagePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let snapshot: ExportDragSnapshot
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Skitchish promised image exports"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(snapshot: ExportDragSnapshot) { self.snapshot = snapshot }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        snapshot.fileURL.lastPathComponent
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try snapshot.write(to: url)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}

@MainActor
final class ExportDragView: NSView, NSDraggingSource {
    var makePayload: (() -> ExportPayload?)?
    var onError: ((Error) -> Void)?
    var formatLabel = "PNG" { didSet { needsDisplay = true } }
    private var startEvent: NSEvent?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 158, height: 40))
        widthAnchor.constraint(equalToConstant: 158).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
        toolTip = "Drag the finished image to Finder, a chat, or another app"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag Me")
        setAccessibilityElement(true)
        setAccessibilityIdentifier("export.drag")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 1, y: 39))
        path.curve(
            to: NSPoint(x: 20, y: 21), controlPoint1: NSPoint(x: 12, y: 39), controlPoint2: NSPoint(x: 13, y: 30))
        path.curve(to: NSPoint(x: 39, y: 2), controlPoint1: NSPoint(x: 27, y: 8), controlPoint2: NSPoint(x: 29, y: 2))
        path.line(to: NSPoint(x: bounds.width - 39, y: 2))
        path.curve(
            to: NSPoint(x: bounds.width - 20, y: 21), controlPoint1: NSPoint(x: bounds.width - 29, y: 2),
            controlPoint2: NSPoint(x: bounds.width - 27, y: 8))
        path.curve(
            to: NSPoint(x: bounds.width - 1, y: 39), controlPoint1: NSPoint(x: bounds.width - 13, y: 30),
            controlPoint2: NSPoint(x: bounds.width - 12, y: 39))
        path.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.set()
        NSColor(white: 0.85, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(white: 0.77, alpha: 1), ending: NSColor(white: 0.95, alpha: 1))?.draw(
            in: path, angle: 90)
        NSColor(white: 0.55, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let grips = NSBezierPath()
        for (index, y) in [14.0, 21.0, 28.0].enumerated() {
            grips.move(to: NSPoint(x: 45 - Double(index) * 3, y: y))
            grips.line(to: NSPoint(x: 63, y: y))
            grips.move(to: NSPoint(x: bounds.width - 63, y: y))
            grips.line(to: NSPoint(x: bounds.width - 45 + Double(index) * 3, y: y))
        }
        NSColor(white: 0.59, alpha: 1).setStroke()
        grips.stroke()
        let page = NSBezierPath()
        let x = bounds.midX - 8
        page.move(to: NSPoint(x: x, y: 9))
        page.line(to: NSPoint(x: x + 16, y: 9))
        page.line(to: NSPoint(x: x + 16, y: 26))
        page.line(to: NSPoint(x: x + 10, y: 32))
        page.line(to: NSPoint(x: x, y: 32))
        page.close()
        NSColor.white.setFill()
        page.fill()
        NSColor(white: 0.65, alpha: 1).setStroke()
        page.lineWidth = 0.8
        page.stroke()
        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: x + 10, y: 32))
        fold.line(to: NSPoint(x: x + 10, y: 26))
        fold.line(to: NSPoint(x: x + 16, y: 26))
        fold.stroke()
        NSColor(calibratedRed: 0.94, green: 0.08, blue: 0.48, alpha: 1).setFill()
        NSRect(x: x - 1, y: 13, width: 18, height: 9).fill()
        let title = formatLabel as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "HelveticaNeue-Bold", size: 6) ?? NSFont.boldSystemFont(ofSize: 6),
            .foregroundColor: NSColor.white,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: 13), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) { startEvent = event }
    override func mouseUp(with event: NSEvent) { startEvent = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let startEvent, let value = makePayload?() else { return }
        self.startEvent = nil
        do {
            let provider = ExportImageDragProvider(snapshot: try ExportDragSnapshot(payload: value))
            let item = NSDraggingItem(pasteboardWriter: provider)
            let scale = min(140 / CGFloat(value.image.width), 140 / CGFloat(value.image.height))
            let size = CGSize(width: CGFloat(value.image.width) * scale, height: CGFloat(value.image.height) * scale)
            item.setDraggingFrame(
                CGRect(origin: .zero, size: size), contents: NSImage(cgImage: value.image, size: size))
            beginDraggingSession(with: [item], event: startEvent, source: self)
        } catch {
            if let onError { onError(error) } else { NSApp.presentError(error) }
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    { .copy }
}
