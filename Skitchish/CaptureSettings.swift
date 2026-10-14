import AppKit
import ServiceManagement

@MainActor final class CaptureSettingsController: NSWindowController, NSWindowDelegate {
    private let shortcuts: GlobalCaptureShortcuts
    private var buttons: [CaptureMode: NSButton] = [:]
    private let delayField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var recording: CaptureMode?
    private var keyMonitor: Any?

    var delay: Double {
        let stored = UserDefaults.standard.object(forKey: "capture.delay") as? Double ?? 5
        return max(0, min(stored, 60))
    }

    init(onCapture: @escaping (CaptureMode) -> Void) {
        shortcuts = GlobalCaptureShortcuts(onCapture: onCapture)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 530, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Skitchish Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
        let heading = NSTextField(labelWithString: "Global capture shortcuts")
        heading.font = .boldSystemFont(ofSize: 16)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(NSTextField(labelWithString: "Click Record, then press a shortcut with ⌘, ⌃, or ⌥."))
        for (index, mode) in CaptureMode.allCases.enumerated() {
            let label = NSTextField(labelWithString: mode.title)
            label.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let button = NSButton(
                title: shortcuts.shortcuts[mode]?.display ?? "Record…", target: self,
                action: #selector(recordShortcut(_:)))
            button.tag = index
            button.widthAnchor.constraint(equalToConstant: 185).isActive = true
            buttons[mode] = button
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut(_:)))
            clear.tag = index
            let row = NSStackView(views: [label, button, clear])
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
        delayField.doubleValue = delay
        delayField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximum = 60
        formatter.maximumFractionDigits = 1
        delayField.formatter = formatter
        delayField.target = self
        delayField.action = #selector(updateDelay)
        stack.addArrangedSubview(
            NSStackView(views: [
                NSTextField(labelWithString: "Timed / menu capture delay"), delayField,
                NSTextField(labelWithString: "seconds"),
            ]))
        let login = NSButton(
            checkboxWithTitle: "Open Skitchish at login", target: self, action: #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        stack.addArrangedSubview(login)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.stringValue = shortcuts.restoreErrors.joined(separator: "\n")
        stack.addArrangedSubview(statusLabel)
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        stopRecording()
        let mode = CaptureMode.allCases[sender.tag]
        recording = mode
        sender.title = "Press shortcut…"
        statusLabel.stringValue = "Escape cancels. Delete clears the shortcut."
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let mode = self.recording else { return event }
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                do {
                    try self.shortcuts.set(nil, for: mode)
                    self.statusLabel.stringValue = "Shortcut cleared."
                } catch { self.statusLabel.stringValue = error.localizedDescription }
                self.stopRecording()
                return nil
            }
            guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                self.statusLabel.stringValue = "Include Command, Control, or Option in a global shortcut."
                return nil
            }
            do {
                try self.shortcuts.set(CaptureShortcut(event: event), for: mode)
                self.statusLabel.stringValue = "Shortcut saved."
            } catch { self.statusLabel.stringValue = error.localizedDescription }
            self.stopRecording()
            return nil
        }
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        stopRecording()
        let mode = CaptureMode.allCases[sender.tag]
        do {
            try shortcuts.set(nil, for: mode)
            buttons[mode]?.title = "Record…"
            statusLabel.stringValue = "Shortcut cleared."
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let recording { buttons[recording]?.title = shortcuts.shortcuts[recording]?.display ?? "Record…" }
        recording = nil
    }

    @objc private func updateDelay() {
        let value = max(0, min(delayField.doubleValue, 60))
        UserDefaults.standard.set(value, forKey: "capture.delay")
        delayField.doubleValue = value
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            if SMAppService.mainApp.status == .requiresApproval {
                statusLabel.stringValue = "Approve Skitchish in System Settings → General → Login Items."
            } else {
                statusLabel.stringValue = "Login preference saved."
            }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            statusLabel.stringValue = error.localizedDescription
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        updateDelay()
    }
}
