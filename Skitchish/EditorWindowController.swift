import AppKit
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    let session: EditorSession
    let renderer = EditorRenderer()
    let store: DocumentStore
    let captureService = CaptureService()
    lazy var settings = CaptureSettingsController { [weak self] mode in self?.capture(mode) }
    let scroll = NSScrollView()
    let canvas: CanvasView
    private let nameField = NSTextField(string: "Untitled")
    private let dimensions = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let formatPicker = NSPopUpButton()
    private let capturePicker = NSPopUpButton()
    private lazy var sidebarController = EditorSidebarController(session: session, canvas: canvas)
    private weak var dragView: ExportDragView?
    private var autosaveTimer: Timer?
    private var captureInProgress = false
    private var draftErrorShown = false
    private var approvedClosingDocument: EditorDocument?
    private var discardedDocument: EditorDocument?
    private var isTesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    static let annotationType = NSPasteboard.PasteboardType("com.skitchish.annotations.v1")
    let toolItems = EditorToolCatalog.items

    init(restoringDraft: Bool = true, store: DocumentStore = DocumentStore()) throws {
        self.store = store
        session = EditorSession(document: try Self.blankDocument())
        canvas = CanvasView(session: session, renderer: renderer)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Skitchish"
        window.minSize = NSSize(width: 880, height: 600)
        window.center()
        window.setFrameAutosaveName("SkitchishEditor")
        buildInterface()
        // Restoring the window frame can send resize callbacks immediately.
        // Install the delegate after the controls used by refresh() exist.
        window.delegate = self
        session.onChange = { [weak self] in self?.refresh() }
        session.onCommit = { [weak self] in self?.scheduleAutosave() }
        canvas.onPaste = { [weak self] in self?.paste(nil) }
        canvas.onCopy = { [weak self] in self?.copySelection(nil) }
        canvas.onOpenURL = { [weak self] url in self?.open(url) }
        canvas.onDropImage = { [weak self] image in
            guard let self else { return }
            do { self.replace(try Self.document(for: image, title: "Dropped Image")) } catch { self.present(error) }
        }
        canvas.onToolShortcut = { [weak self] key in self?.sidebarController.selectShortcut(key) ?? false }
        canvas.onZoom = { [weak self] zoom in self?.setZoom(zoom) }
        canvas.onCanvasInteraction = { [weak self] in self?.sidebarController.closeOptions() }
        if !isTesting && restoringDraft {
            do { if let latest = try store.latestDraft() { session.replace(with: latest) } } catch {
                DispatchQueue.main.async { [weak self] in self?.present(error) }
            }
            _ = settings
        }
        refresh()
        window.makeFirstResponder(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        approvedClosingDocument = nil
        super.showWindow(sender)
        window?.contentView?.layoutSubtreeIfNeeded()
        refresh()
    }
    static func blankDocument(width: Int = 1000, height: Int = 700) throws -> EditorDocument {
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw EditorRenderError.allocationFailed }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw EditorRenderError.allocationFailed }
        return try document(for: image, title: "Untitled")
    }
    static func document(for image: CGImage, title: String) throws -> EditorDocument {
        EditorDocument(
            imageData: try ImageService.pngData(image), imageSize: CGSize(width: image.width, height: image.height),
            title: title)
    }
    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.font = NSFont(name: "HelveticaNeue", size: 12) ?? .systemFont(ofSize: 12)
        b.contentTintColor = NSColor(white: 0.32, alpha: 1)
        if let symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageLeading
        }
        b.setAccessibilityIdentifier(title)
        return b
    }
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        // Pin the four chrome regions independently. An NSStackView root can detach
        // or compress an entire toolbar after an NSSavePanel changes window layout.
        let header = EditorChromeView()
        header.bottomBorder = true
        let sidebar = EditorChromeView()
        sidebar.isSidebar = true
        sidebar.wantsLayer = true
        sidebar.layer?.masksToBounds = true
        sidebar.onBackgroundClick = { [weak self] in self?.sidebarController.closeOptions() }
        let footer = EditorChromeView()
        footer.topBorder = true
        for view in [header, sidebar, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: footer.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 56),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])
        configureHeader(header)
        sidebarController.configure(in: sidebar, content: content)
        configureCanvas()
        configureFooter(footer)
    }

    private func configureHeader(_ header: NSView) {
        func horizontalStack(in parent: NSView, inset: CGFloat = 12) -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 7
            stack.detachesHiddenViews = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
                stack.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
                stack.centerYAnchor.constraint(equalTo: parent.centerYAnchor),
            ])
            return stack
        }
        let top = horizontalStack(in: header)
        top.addArrangedSubview(button("Open", #selector(openFile(_:)), symbol: "folder"))
        top.addArrangedSubview(button("New", #selector(newDocument(_:)), symbol: "doc.badge.plus"))
        top.addArrangedSubview(spacer())
        top.addArrangedSubview(button("Copy Image", #selector(copyImage(_:)), symbol: "doc.on.doc"))
        // Keep capture and export centered in the window, independent of side controls.
        let capture = NSStackView()
        capture.spacing = 0
        capture.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(capture)
        capture.addArrangedSubview(button("Screen Snap", #selector(snapRegion(_:)), symbol: "viewfinder"))
        capturePicker.addItems(withTitles: ["", "Full Screen", "Window", "Previous Area", "Timed Area…", "Menu…"])
        capturePicker.setAccessibilityLabel("More Capture")
        capturePicker.widthAnchor.constraint(equalToConstant: 28).isActive = true
        capturePicker.font = NSFont(name: "HelveticaNeue", size: 12)
        capturePicker.target = self
        capturePicker.action = #selector(pickCapture(_:))
        capture.addArrangedSubview(capturePicker)
        NSLayoutConstraint.activate([
            capture.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            capture.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
    }

    private func configureCanvas() {
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        scroll.documentView = canvas
    }

    private func configureFooter(_ footer: NSView) {
        let bottom = NSStackView()
        bottom.spacing = 5
        bottom.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(bottom)
        NSLayoutConstraint.activate([
            bottom.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 9),
            bottom.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        bottom.addArrangedSubview(button("−", #selector(zoomOut(_:))))
        zoomLabel.font = NSFont(name: "HelveticaNeue", size: 11)
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        bottom.addArrangedSubview(zoomLabel)
        bottom.addArrangedSubview(button("+", #selector(zoomIn(_:))))
        bottom.addArrangedSubview(button("Fit", #selector(fit(_:))))
        dimensions.font = NSFont(name: "HelveticaNeue", size: 10)
        dimensions.textColor = .secondaryLabelColor
        nameField.delegate = self
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.font = NSFont(name: "HelveticaNeue-Bold", size: 11)
        nameField.alignment = .left
        nameField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        nameField.setAccessibilityIdentifier("document.title")
        bottom.addArrangedSubview(nameField)
        let right = NSStackView()
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(right)
        NSLayoutConstraint.activate([
            right.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -9),
            right.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        formatPicker.addItems(withTitles: ["PNG", "JPEG", "TIFF"])
        formatPicker.font = NSFont(name: "HelveticaNeue", size: 11)
        formatPicker.widthAnchor.constraint(equalToConstant: 64).isActive = true
        formatPicker.target = self
        formatPicker.action = #selector(changeExportFormat(_:))
        right.addArrangedSubview(formatPicker)
        right.addArrangedSubview(button("Export", #selector(exportImage(_:))))
        right.addArrangedSubview(dimensions)
        let drag = ExportDragView()
        drag.makePayload = { [weak self] in
            guard let self, self.canvas.finishTextEditing() else { return nil }
            do {
                return ExportPayload(
                    image: try self.renderer.render(document: self.session.document),
                    title: self.session.document.title, format: self.exportFormat)
            } catch {
                self.present(error)
                return nil
            }
        }
        drag.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(drag)
        dragView = drag
        NSLayoutConstraint.activate([
            drag.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            drag.topAnchor.constraint(equalTo: footer.topAnchor),
            bottom.trailingAnchor.constraint(lessThanOrEqualTo: drag.leadingAnchor, constant: -12),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: drag.trailingAnchor, constant: 12),
        ])
    }
    func refresh() {
        guard isWindowLoaded else { return }
        window?.title = "\(session.document.title) — Skitchish"
        window?.isDocumentEdited = session.hasUnsavedChanges
        if window?.firstResponder !== nameField.currentEditor() { nameField.stringValue = session.document.title }
        sidebarController.refresh()
        let viewport = scroll.contentView.bounds.size
        let size = session.document.canvas.size
        if session.fitsWindow && !canvas.isEditingText {
            session.zoom = max(
                0.05,
                min(1, min((viewport.width - 96) / max(1, size.width), (viewport.height - 96) / max(1, size.height))))
        }
        canvas.setFrameSize(
            NSSize(
                width: max(viewport.width, size.width * session.zoom + 96),
                height: max(viewport.height, size.height * session.zoom + 96)))
        canvas.synchronizeTextEditorPosition()
        zoomLabel.stringValue = "\(Int((session.zoom * 100).rounded()))%"
        dimensions.stringValue = "\(Int(size.width)) × \(Int(size.height))"
        canvas.needsDisplay = true
        canvas.refreshCursor()
    }
    func windowDidResize(_ notification: Notification) {
        window?.contentView?.layoutSubtreeIfNeeded()
        sidebarController.updateTrackingAreas()
        refresh()
    }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard prepareToLeaveDocument() else { return false }
        approvedClosingDocument = session.document
        return true
    }
    func prepareToTerminate() -> Bool {
        if window?.isVisible == false, approvedClosingDocument == session.document, !canvas.isEditingText {
            return true
        }
        return prepareToLeaveDocument()
    }
    enum UnsavedChangesChoice { case save, keepDraft, discard, cancel }

    /// Closing, quitting, and replacing an image share the same cancellation boundary.
    func prepareToLeaveDocument(
        choose: (() -> UnsavedChangesChoice)? = nil,
        save: (() -> Bool)? = nil
    ) -> Bool {
        guard canvas.finishTextEditing() else { return false }
        if let editor = nameField.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }
        guard window?.makeFirstResponder(canvas) != false else { return false }
        autosaveTimer?.invalidate()
        if discardedDocument == session.document { return true }
        guard session.hasUnsavedChanges else { return flushDraft() }
        switch choose?() ?? askToSaveChanges() {
        case .cancel:
            scheduleAutosave()
            return false
        case .keepDraft: return flushDraft()
        case .save:
            guard save?() ?? saveDocumentBeforeLeaving() else {
                scheduleAutosave()
                return false
            }
            return flushDraft()
        case .discard:
            do {
                try store.discardDraft(id: session.document.id)
                discardedDocument = session.document
                return true
            } catch {
                scheduleAutosave()
                present(error)
                return false
            }
        }
    }
    private func askToSaveChanges() -> UnsavedChangesChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to “\(session.document.title)”?"
        alert.informativeText =
            "Save an editable file, or choose Keep Draft to restore this image later. Don’t Save discards this image’s working draft and unsaved changes. Previously saved files are kept."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Keep Draft")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .keepDraft
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3):
            return .discard
        default: return .cancel
        }
    }
    private func saveDocumentBeforeLeaving() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "com.skitchish.document", conformingTo: .package)]
        panel.nameFieldStringValue = session.document.title + ".skitchish"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try saveEditableDocument(to: url)
            return true
        } catch {
            present(error)
            return false
        }
    }
    func saveEditableDocument(to url: URL) throws {
        try store.save(document: session.document, to: url)
        session.markSaved()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        session.change("Rename") { $0.title = title.isEmpty ? "Untitled" : title }
    }
    private func scheduleAutosave() {
        guard !isTesting else { return }
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveDraftNow() }
        }
    }
    private func saveDraftNow() {
        guard discardedDocument != session.document else { return }
        do {
            try store.saveDraft(canvas.draftDocument)
            draftErrorShown = false
        } catch {
            if !draftErrorShown {
                draftErrorShown = true
                present(error)
            }
        }
    }
    @discardableResult func flushDraft() -> Bool {
        guard canvas.finishTextEditing() else { return false }
        autosaveTimer?.invalidate()
        if discardedDocument == session.document { return true }
        if isTesting { return true }
        do {
            try store.saveDraft(session.document)
            return true
        } catch {
            present(error)
            return false
        }
    }
    private func replace(_ document: EditorDocument, isSaved: Bool = false) {
        guard prepareToLeaveDocument() else { return }
        approvedClosingDocument = nil
        discardedDocument = nil
        session.replace(with: document, isSaved: isSaved)
        scheduleAutosave()
        window?.makeFirstResponder(canvas)
    }
    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let doc =
                url.pathExtension.lowercased() == "skitchish"
                ? try store.loadForEditing(from: url)
                : try Self.document(
                    for: ImageService.image(from: url), title: url.deletingPathExtension().lastPathComponent)
            let isDraft = url.deletingLastPathComponent().standardizedFileURL == store.baseURL.standardizedFileURL
            replace(doc, isSaved: url.pathExtension.lowercased() == "skitchish" && !isDraft)
            showWindow(nil)
        } catch { present(error) }
    }
    private func present(_ error: Error) { NSApp.presentError(error) }
    @objc func openFile(_ sender: Any?) {
        guard canvas.finishTextEditing() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, UTType(exportedAs: "com.skitchish.document", conformingTo: .package)]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] result in
            if result == .OK, let url = panel.url { self?.open(url) }
        }
    }
    @objc func newDocument(_ sender: Any?) {
        do { replace(try Self.blankDocument(), isSaved: true) } catch { present(error) }
    }
    @objc func saveDocument(_ sender: Any?) {
        guard canvas.finishTextEditing() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "com.skitchish.document", conformingTo: .package)]
        panel.nameFieldStringValue = session.document.title + ".skitchish"
        panel.beginSheetModal(for: window!) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do { try self.saveEditableDocument(to: url) } catch { self.present(error) }
        }
    }
    var exportFormat: ExportFormat { [.png, .jpeg, .tiff][max(0, formatPicker.indexOfSelectedItem)] }
    @objc func exportImage(_ sender: Any?) {
        guard canvas.finishTextEditing() else { return }
        let format = exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = session.document.title + "." + format.fileExtension
        panel.beginSheetModal(for: window!) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                try ImageService.write(self.renderer.render(document: self.session.document), to: url, format: format)
            } catch { self.present(error) }
        }
    }
    @objc func copyImage(_ sender: Any?) {
        guard canvas.finishTextEditing() else { return }
        do { try ImageService.copy(renderer.render(document: session.document)) } catch { present(error) }
    }
    @objc func copySelection(_ sender: Any?) {
        let marks = session.document.annotations.filter { session.selection.contains($0.id) }
        guard !marks.isEmpty else {
            copyImage(sender)
            return
        }
        do {
            let data = try JSONEncoder().encode(marks)
            var selected = session.document
            selected.annotations = marks
            selected.canvas = marks.reduce(CGRect.null) { $0.union($1.visualBounds) }.integral
            selected.imageData = try ImageService.pngData(Self.transparentPixel())
            selected.imageSize = CGSize(width: 1, height: 1)
            selected.imageTransform = PixelTransform()
            try ImageService.copy(renderer.render(document: selected))
            guard NSPasteboard.general.setData(data, forType: Self.annotationType) else {
                throw EditorServiceError.encodingFailed
            }
        } catch { present(error) }
    }
    private static func transparentPixel() throws -> CGImage {
        guard
            let ctx = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = ctx.makeImage()
        else { throw EditorRenderError.allocationFailed }
        return image
    }
    @objc func paste(_ sender: Any?) {
        guard canvas.finishTextEditing() else { return }
        do {
            if let data = NSPasteboard.general.data(forType: Self.annotationType) {
                guard data.count <= 32_000_000 else { throw EditorServiceError.invalidDocument }
                var marks = try JSONDecoder().decode([Markup].self, from: data)
                for i in marks.indices {
                    marks[i] = marks[i].translated(dx: 16, dy: 16)
                    marks[i].id = UUID()
                }
                var validation = session.document
                validation.annotations = marks
                try validation.validate()
                session.append(marks, name: "Paste Annotations")
                return
            }
            if let image = try ImageService.image(from: NSPasteboard.general) {
                replace(try Self.document(for: image, title: "Pasted Image"))
            } else {
                NSSound.beep()
            }
        } catch { present(error) }
    }
    @objc func duplicate(_ sender: Any?) { if canvas.finishTextEditing() { session.duplicateSelection() } }
    @objc func remove(_ sender: Any?) { if canvas.finishTextEditing() { session.deleteSelection() } }
    @objc func selectToolMenu(_ sender: NSMenuItem) { sidebarController.chooseTool(toolItems[sender.tag].tool) }
    @objc func pickTool(_ sender: NSButton) { sidebarController.pickTool(sender) }
    @objc func pickColor(_ sender: NSButton) { sidebarController.pickColor(sender) }
    @objc func pickSize(_ sender: NSButton) { sidebarController.setSize(sender.tag) }
    @objc func pickSizeMenu(_ sender: NSMenuItem) { sidebarController.setSize(sender.tag) }
    @objc func pickStampChoice(_ sender: NSButton) { sidebarController.pickStampChoice(sender) }
    @objc private func changeExportFormat(_ sender: NSPopUpButton) {
        dragView?.formatLabel = sender.titleOfSelectedItem ?? "PNG"
    }
    private func setZoom(_ value: CGFloat) {
        guard canvas.finishTextEditing() else { return }
        session.fitsWindow = false
        session.zoom = min(8, max(0.05, value))
        refresh()
    }
    @objc func zoomIn(_ sender: Any?) { setZoom(session.zoom * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setZoom(session.zoom / 1.25) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }
    @objc func fit(_ sender: Any?) {
        if canvas.finishTextEditing() {
            session.fitsWindow = true
            refresh()
        }
    }
    @objc func rotate(_ sender: Any?) {
        if canvas.finishTextEditing() { session.change("Rotate Clockwise") { $0.rotateClockwise() } }
    }
    @objc func rotateBack(_ sender: Any?) {
        if canvas.finishTextEditing() {
            session.change("Rotate Counterclockwise") { doc in for _ in 0..<3 { doc.rotateClockwise() } }
        }
    }
    @objc func flipHorizontal(_ sender: Any?) {
        if canvas.finishTextEditing() { session.change("Flip Horizontally") { $0.flip(horizontal: true) } }
    }
    @objc func flipVertical(_ sender: Any?) {
        if canvas.finishTextEditing() { session.change("Flip Vertically") { $0.flip(horizontal: false) } }
    }
    @objc func resizeImage(_ sender: Any?) {
        guard canvas.finishTextEditing() else { return }
        let alert = NSAlert()
        alert.messageText = "Resize Image"
        alert.informativeText = "Enter output dimensions in pixels. Annotations scale with the image."
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        let fields = NSStackView()
        fields.orientation = .horizontal
        fields.spacing = 10
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        let width = NSTextField(string: String(Int(session.document.canvas.width)))
        let height = NSTextField(string: String(Int(session.document.canvas.height)))
        width.widthAnchor.constraint(equalToConstant: 110).isActive = true
        height.widthAnchor.constraint(equalToConstant: 110).isActive = true
        fields.addArrangedSubview(width)
        fields.addArrangedSubview(NSTextField(labelWithString: "×"))
        fields.addArrangedSubview(height)
        alert.accessoryView = fields
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let w = Int(width.stringValue), let h = Int(height.stringValue), w > 0, h > 0, w <= 30000, h <= 30000,
                Double(w) * Double(h) <= 150_000_000
            else {
                self.present(EditorRenderError.invalidDimensions)
                return
            }
            self.session.change("Resize Image") { $0.resize(to: CGSize(width: w, height: h)) }
        }
    }
    @objc func printImage(_ sender: Any?) {
        guard canvas.finishTextEditing() else { return }
        do {
            let image = try renderer.render(document: session.document)
            let view = NSImageView(
                frame: NSRect(x: 0, y: 0, width: session.document.canvas.width, height: session.document.canvas.height))
            view.image = NSImage(cgImage: image, size: view.frame.size)
            view.imageScaling = .scaleProportionallyUpOrDown
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            NSPrintOperation(view: view, printInfo: info).runModal(
                for: window!, delegate: nil, didRun: nil, contextInfo: nil)
        } catch { present(error) }
    }
    @objc func restoreDraft(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { open(url) } }
    @objc func showDrafts(_ sender: Any?) {
        do {
            let drafts = try store.drafts()
            let menu = NSMenu()
            if drafts.isEmpty { menu.addItem(withTitle: "No saved drafts", action: nil, keyEquivalent: "") }
            for draft in drafts {
                let item = menu.addItem(withTitle: draft.title, action: #selector(restoreDraft(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = draft.url
            }
            menu.popUp(
                positioning: nil, at: NSPoint(x: 120, y: window!.contentView!.bounds.height - 50),
                in: window!.contentView)
        } catch { present(error) }
    }
    @objc func showSettings(_ sender: Any?) { settings.showWindow(nil) }
    @objc func snapRegion(_ sender: Any?) { capture(.region) }
    @objc func snapFull(_ sender: Any?) { capture(.fullScreen) }
    @objc func snapWindow(_ sender: Any?) { capture(.window) }
    @objc func snapPrevious(_ sender: Any?) { capture(.previousRegion) }
    @objc func snapTimed(_ sender: Any?) { capture(.timed) }
    @objc func snapMenu(_ sender: Any?) { capture(.menu) }
    @objc func pickCapture(_ sender: NSPopUpButton) {
        let modes: [CaptureMode] = [.region, .fullScreen, .window, .previousRegion, .timed, .menu]
        let index = sender.indexOfSelectedItem
        sender.selectItem(at: 0)
        if index > 0 { capture(modes[index]) }
    }
    func capture(_ mode: CaptureMode) {
        guard !captureInProgress, flushDraft() else { return }
        captureInProgress = true
        Task { @MainActor in
            defer {
                captureInProgress = false
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            do {
                if let image = try await captureService.capture(mode: mode, delay: settings.delay) {
                    replace(try Self.document(for: image, title: "Screen Snap"))
                }
            } catch { present(error) }
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(duplicate(_:)) || menuItem.action == #selector(remove(_:)) {
            return !session.selection.isEmpty && !canvas.isEditingText
        }
        return !captureInProgress
    }
}
