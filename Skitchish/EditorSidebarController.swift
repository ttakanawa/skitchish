import AppKit
import QuartzCore

/// Owns the annotation tools and their in-place option palettes.
@MainActor
final class EditorSidebarController: NSObject {
    private enum OptionsKind {
        case variants, color, size, stamp
    }

    private let session: EditorSession
    private let canvas: CanvasView
    private let toolItems = EditorToolCatalog.items
    private var window: NSWindow? { canvas.window }
    private var toolButtons: [EditorTool: EditorToolButton] = [:]
    private var colorButtons: [NSButton] = []
    private var sizeButtons: [NSButton] = []
    private lazy var colorControl = EditorStyleButton(kind: .color, target: self, action: #selector(showColors(_:)))
    private lazy var sizeControl = EditorStyleButton(kind: .width, target: self, action: #selector(showSizes(_:)))
    private let toolColumn = NSStackView()
    private let optionsColumn = EditorOptionsColumn()
    private var toolColumnX: NSLayoutConstraint?
    private var optionsColumnX: NSLayoutConstraint?
    private var optionButtons: [NSButton] = []
    private var optionsKind: OptionsKind?
    private var optionsTransition = 0

    init(session: EditorSession, canvas: CanvasView) {
        self.session = session
        self.canvas = canvas
        super.init()
    }

    func configure(in sidebar: NSView, content: NSView) {
        let tools = toolColumn
        tools.orientation = .vertical
        tools.spacing = 0
        tools.detachesHiddenViews = false
        tools.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(tools)
        let toolColumnX = tools.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor)
        self.toolColumnX = toolColumnX
        NSLayoutConstraint.activate([tools.centerYAnchor.constraint(equalTo: sidebar.centerYAnchor), toolColumnX])
        optionsColumn.orientation = .vertical
        optionsColumn.alignment = .centerX
        optionsColumn.spacing = 0
        optionsColumn.translatesAutoresizingMaskIntoConstraints = false
        optionsColumn.isHidden = true
        optionsColumn.onClose = { [weak self] in self?.closeOptions() }
        optionsColumn.onEscape = { [weak self] in self?.closeOptions(force: true) }
        optionsColumn.configureTracking(in: content, sidebar: sidebar)
        sidebar.addSubview(optionsColumn)
        let optionsColumnX = optionsColumn.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor, constant: 57)
        self.optionsColumnX = optionsColumnX
        NSLayoutConstraint.activate([
            optionsColumnX, optionsColumn.topAnchor.constraint(equalTo: tools.topAnchor),
            optionsColumn.heightAnchor.constraint(greaterThanOrEqualTo: tools.heightAnchor),
            optionsColumn.widthAnchor.constraint(equalToConstant: 40),
        ])
        for primary in EditorToolCatalog.primaryTools {
            let index = toolItems.firstIndex { $0.tool == primary }!
            let item = toolItems[index]
            let b = EditorToolButton(tool: item.tool, target: self, action: #selector(pickTool(_:)))
            b.tag = index
            b.toolTip = item.toolTip
            b.setAccessibilityLabel(item.title)
            b.setAccessibilityIdentifier("tool.\(item.tool.rawValue)")
            sizePaletteButton(b)
            if primary == .rectangle || primary == .pen {
                if primary == .rectangle {
                    b.alwaysOpensVariants = true
                    b.setAccessibilityRole(.button)
                }
                b.onOpenVariants = { [weak self] in
                    guard let self else { return }
                    self.showToolVariants(EditorToolCatalog.tools(for: primary))
                }
            } else if primary == .stamp {
                b.alwaysOpensVariants = true
                b.setAccessibilityRole(.button)
                b.onOpenVariants = { [weak self] in self?.showStamps() }
            }
            tools.addArrangedSubview(b)
            toolButtons[item.tool] = b
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let separator = NSView()
        separator.addSubview(divider)
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 24),
            separator.widthAnchor.constraint(equalToConstant: 40),
            divider.centerXAnchor.constraint(equalTo: separator.centerXAnchor),
            divider.centerYAnchor.constraint(equalTo: separator.centerYAnchor),
        ])
        tools.addArrangedSubview(separator)
        for (control, label, identifier) in [
            (colorControl, "Color", "style.color"), (sizeControl, "Size", "style.size"),
        ] {
            control.setAccessibilityLabel(label)
            control.setAccessibilityIdentifier(identifier)
            control.toolTip = label
            sizePaletteButton(control)
            tools.addArrangedSubview(control)
        }
    }

    func refresh() {
        for (primary, button) in toolButtons {
            if primary == .stamp { button.stamp = session.stamp }
            let group = EditorToolCatalog.tools(for: primary)
            if group.contains(session.tool) { button.tool = session.tool }
            let index = toolItems.firstIndex { $0.tool == button.tool }!
            let item = toolItems[index]
            button.tag = index
            button.setAccessibilityIdentifier("tool.\(button.tool.rawValue)")
            button.setAccessibilityLabel(item.title)
            if primary == .stamp {
                button.setAccessibilityLabel("Stamp \(EditorStampButton.symbol(for: session.stamp))")
            }
            button.toolTip =
                item.toolTip
                + (button.alwaysOpensVariants
                    ? (primary == .rectangle ? " — choose a shape" : " — choose a stamp")
                    : button.onOpenVariants == nil ? "" : " — click the corner for options")
            button.state = group.contains(session.tool) ? .on : .off
            button.needsDisplay = true
        }
        colorControl.swatch = session.color.nsColor
        sizeControl.sizeIndex = session.sizeIndex
        let selectedMarks = session.document.annotations.filter { session.selection.contains($0.id) }
        let styleEnabled =
            session.tool != .stamp && (selectedMarks.isEmpty || !selectedMarks.allSatisfy { $0.tool == .stamp })
        colorControl.isEnabled = styleEnabled
        sizeControl.isEnabled = styleEnabled
        for button in colorButtons {
            button.isEnabled = styleEnabled
            button.state = button.tag == session.colorIndex ? .on : .off
            button.needsDisplay = true
        }
        for (index, button) in sizeButtons.enumerated() {
            button.isEnabled = styleEnabled
            button.state = index == session.sizeIndex ? .on : .off
            button.needsDisplay = true
        }
        for button in optionButtons {
            if optionsKind == .stamp {
                button.state = button.tag == session.stamp ? .on : .off
            } else if optionsKind == .variants {
                button.state = isSelectedVariant(toolItems[button.tag].tool) ? .on : .off
            }
            button.needsDisplay = true
        }
    }

    func updateTrackingAreas() {
        optionsColumn.updateTrackingAreas()
    }

    private func sizePaletteButton(_ button: NSButton) {
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func makeOptionsStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        return stack
    }

    @objc func pickTool(_ sender: NSButton) {
        if sender.isDescendant(of: optionsColumn) {
            guard canvas.finishTextEditing() else { return }
            session.tool = toolItems[sender.tag].tool
            optionsColumn.closeAfterChoice()
        } else {
            chooseTool(toolItems[sender.tag].tool)
        }
    }
    func chooseTool(_ tool: EditorTool) {
        if canvas.finishTextEditing() {
            closeOptions(force: true)
            session.tool = tool
            window?.makeFirstResponder(canvas)
        }
    }
    func closeOptions(force: Bool = false) {
        guard optionsColumn.isPresented, force || !optionsColumn.isPinned else { return }
        optionsColumn.isPinned = false
        optionsColumn.setPresented(false)
        optionsKind = nil
        transitionOptions(show: false)
        window?.makeFirstResponder(canvas)
    }
    private func transitionOptions(show: Bool) {
        optionsTransition += 1
        let transition = optionsTransition
        toolColumn.isHidden = false
        optionsColumn.isHidden = false
        window?.contentView?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : EditorOptionsColumn.transitionDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0, 1, 0.66, 1)
            toolColumnX?.animator().constant = show ? -57 : 0
            optionsColumnX?.animator().constant = show ? 0 : 57
        } completionHandler: { [weak self] in
            // AppKit invokes animation completion handlers on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.optionsTransition == transition else { return }
                self.toolColumn.isHidden = show
                self.optionsColumn.isHidden = !show
            }
        }
    }
    @objc private func toggleOptionsPin(_ sender: NSButton) {
        optionsColumn.isPinned.toggle()
        sender.state = optionsColumn.isPinned ? .on : .off
        sender.setAccessibilityValue(optionsColumn.isPinned ? 1 : 0)
        sender.needsDisplay = true
        if !optionsColumn.isPinned { closeOptions() }
    }
    private func showOptions(_ contents: NSView, kind: OptionsKind, blankRow: Bool = false) {
        guard canvas.finishTextEditing() else { return }
        if optionsColumn.isPresented, optionsKind == kind {
            closeOptions(force: true)
            return
        }
        for view in optionsColumn.arrangedSubviews {
            optionsColumn.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let pin = EditorPinButton(title: "", target: self, action: #selector(toggleOptionsPin(_:)))
        pin.isBordered = false
        pin.setButtonType(.toggle)
        pin.state = optionsColumn.isPinned ? .on : .off
        pin.setAccessibilityIdentifier("options.pin")
        pin.setAccessibilityLabel("Pin sub tools open")
        pin.toolTip = "Pin sub tools open"
        sizePaletteButton(pin)
        optionsColumn.addArrangedSubview(pin)
        if blankRow {
            let blank = NSView()
            blank.heightAnchor.constraint(equalToConstant: 40).isActive = true
            optionsColumn.addArrangedSubview(blank)
        }
        optionsColumn.addArrangedSubview(contents)
        let bottomSpace = NSView()
        bottomSpace.setContentHuggingPriority(.init(1), for: .vertical)
        bottomSpace.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        optionsColumn.addArrangedSubview(bottomSpace)
        optionsKind = kind
        optionsColumn.setPresented(true)
        transitionOptions(show: true)
        window?.makeFirstResponder(optionsColumn)
    }
    private func isSelectedVariant(_ tool: EditorTool) -> Bool {
        // Like the stamp repertoire, shapes retain a highlighted choice even
        // while another drawing tool is active.
        let selected =
            EditorToolCatalog.shapeTools.contains(tool) ? (toolButtons[.rectangle]?.tool ?? .rectangle) : session.tool
        return tool == selected
    }

    private func showToolVariants(_ variants: [EditorTool]) {
        let row = makeOptionsStack()
        optionButtons.removeAll()
        for tool in variants {
            let index = toolItems.firstIndex { $0.tool == tool }!
            let item = toolItems[index]
            let choice = EditorToolButton(tool: tool, target: self, action: #selector(pickTool(_:)))
            choice.tag = index
            choice.state = isSelectedVariant(tool) ? .on : .off
            choice.setAccessibilityLabel(item.title)
            choice.setAccessibilityIdentifier("variant.\(tool.rawValue)")
            choice.toolTip = item.title
            sizePaletteButton(choice)
            row.addArrangedSubview(choice)
            optionButtons.append(choice)
        }
        showOptions(row, kind: .variants, blankRow: true)
    }
    @objc private func showColors(_ sender: NSButton) {
        let grid = makeOptionsStack()
        let names = ["Red", "Orange", "Yellow", "Green", "Blue", "Pink", "White", "Black"]
        colorButtons.removeAll()
        for index in 0..<RGBA.palette.count {
            let choice = EditorColorButton(
                color: RGBA.palette[index].nsColor, target: self, action: #selector(pickColor(_:)))
            choice.tag = index
            choice.state = session.colorIndex == index ? .on : .off
            choice.setAccessibilityIdentifier("color.\(index)")
            choice.setAccessibilityLabel(names[index])
            choice.toolTip = names[index]
            sizePaletteButton(choice)
            grid.addArrangedSubview(choice)
            colorButtons.append(choice)
        }
        let custom = EditorColorButton(
            color: session.customColor.nsColor, target: self, action: #selector(showCustomColor(_:)))
        custom.isCustomColor = true
        custom.tag = -1
        custom.state = session.colorIndex == -1 ? .on : .off
        custom.setAccessibilityIdentifier("color.custom")
        custom.setAccessibilityLabel("Custom Color")
        custom.toolTip = "Custom Color"
        sizePaletteButton(custom)
        grid.addArrangedSubview(custom)
        colorButtons.append(custom)
        showOptions(grid, kind: .color)
    }
    @objc private func showCustomColor(_ sender: NSButton) {
        guard canvas.finishTextEditing() else { return }
        optionsColumn.closeAfterChoice()
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false
        // Merely opening the chooser must not recolor the selected annotation.
        panel.color = session.color.nsColor
        panel.setTarget(self)
        panel.setAction(#selector(changeCustomColor(_:)))
        panel.orderFront(sender)
    }
    @objc private func changeCustomColor(_ sender: NSColorPanel) {
        guard canvas.finishTextEditing(), let color = sender.color.usingColorSpace(.sRGB) else { return }
        session.setCustomColor(RGBA(r: color.redComponent, g: color.greenComponent, b: color.blueComponent))
        applySelectedColor()
    }
    private func applySelectedColor() {
        session.change("Change Color") { doc in
            for i in doc.annotations.indices where session.selection.contains(doc.annotations[i].id) {
                doc.annotations[i].color = session.color
            }
        }
    }
    @objc private func showSizes(_ sender: NSButton) {
        let row = makeOptionsStack()
        sizeButtons.removeAll()
        for index in 0..<5 {
            let choice = EditorSizeButton(title: "", target: self, action: #selector(pickSize(_:)))
            choice.isBordered = false
            choice.setButtonType(.toggle)
            choice.tag = index
            choice.state = session.sizeIndex == index ? .on : .off
            choice.setAccessibilityIdentifier("size.\(index)")
            choice.setAccessibilityLabel("Size \(index + 1)")
            sizePaletteButton(choice)
            row.addArrangedSubview(choice)
            sizeButtons.append(choice)
        }
        showOptions(row, kind: .size, blankRow: true)
    }
    private func showStamps() {
        let row = makeOptionsStack()
        optionButtons.removeAll()
        for index in [1, 3, 2, 0, 4] {
            let choice = EditorStampButton(stamp: index, target: self, action: #selector(pickStampChoice(_:)))
            choice.tag = index
            choice.state = index == session.stamp ? .on : .off
            choice.setAccessibilityIdentifier("stamp.\(index)")
            row.addArrangedSubview(choice)
            optionButtons.append(choice)
        }
        showOptions(row, kind: .stamp, blankRow: true)
    }
    func selectShortcut(_ key: String) -> Bool {
        guard let item = toolItems.first(where: { $0.shortcut == key }) else { return false }
        chooseTool(item.tool)
        return true
    }
    @objc func pickColor(_ sender: NSButton) {
        guard canvas.finishTextEditing() else { return }
        session.colorIndex = sender.tag
        applySelectedColor()
        optionsColumn.closeAfterChoice()
        if !optionsColumn.isPresented { window?.makeFirstResponder(canvas) }
    }
    @objc func pickSize(_ sender: NSButton) { setSize(sender.tag) }
    func setSize(_ index: Int) {
        guard canvas.finishTextEditing() else { return }
        session.sizeIndex = index
        session.change("Change Size") { doc in
            for i in doc.annotations.indices where session.selection.contains(doc.annotations[i].id) {
                doc.annotations[i].size = session.strokeWidth
            }
        }
        optionsColumn.closeAfterChoice()
        if !optionsColumn.isPresented { window?.makeFirstResponder(canvas) }
    }
    @objc func pickStampChoice(_ sender: NSButton) {
        guard canvas.finishTextEditing() else { return }
        session.stamp = sender.tag
        session.change("Change Stamp") { doc in
            for i in doc.annotations.indices
            where session.selection.contains(doc.annotations[i].id) && doc.annotations[i].tool == .stamp {
                doc.annotations[i].stamp = session.stamp
            }
        }
        session.tool = .stamp
        optionsColumn.closeAfterChoice()
    }
}
