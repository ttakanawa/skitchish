import AppKit
import Carbon

struct CaptureShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var flags: UInt32 = 0
        var label = ""
        if event.modifierFlags.contains(.control) {
            flags |= UInt32(controlKey)
            label += "⌃"
        }
        if event.modifierFlags.contains(.option) {
            flags |= UInt32(optionKey)
            label += "⌥"
        }
        if event.modifierFlags.contains(.shift) {
            flags |= UInt32(shiftKey)
            label += "⇧"
        }
        if event.modifierFlags.contains(.command) {
            flags |= UInt32(cmdKey)
            label += "⌘"
        }
        modifiers = flags
        let special: [UInt16: String] = [
            49: "Space", 36: "Return", 48: "Tab", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        display =
            label
            + (special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
    }
}

@MainActor final class GlobalCaptureShortcuts {
    var onCapture: (CaptureMode) -> Void
    private var references: [CaptureMode: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private(set) var shortcuts: [CaptureMode: CaptureShortcut] = [:]
    private(set) var restoreErrors: [String] = []

    init(onCapture: @escaping (CaptureMode) -> Void) {
        self.onCapture = onCapture
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == 0x534B_4348,
                    Int(id.id) < CaptureMode.allCases.count
                else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalCaptureShortcuts>.fromOpaque(context).takeUnretainedValue()
                manager.onCapture(CaptureMode.allCases[Int(id.id)])
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for mode in CaptureMode.allCases {
            if let data = UserDefaults.standard.data(forKey: "capture.shortcut.\(mode.rawValue)"),
                let shortcut = try? JSONDecoder().decode(CaptureShortcut.self, from: data)
            {
                do { try set(shortcut, for: mode) } catch {
                    restoreErrors.append("\(mode.title): \(error.localizedDescription)")
                }
            }
        }
    }

    deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func set(_ shortcut: CaptureShortcut?, for mode: CaptureMode) throws {
        if shortcuts[mode] == shortcut { return }
        if let shortcut,
            shortcuts.contains(where: {
                $0.key != mode && $0.value.keyCode == shortcut.keyCode && $0.value.modifiers == shortcut.modifiers
            })
        {
            throw EditorServiceError.shortcutUnavailable
        }
        let previous = shortcuts[mode]
        if let reference = references.removeValue(forKey: mode) { UnregisterEventHotKey(reference) }
        if let shortcut {
            do { references[mode] = try register(shortcut, for: mode) } catch {
                if let previous { references[mode] = try? register(previous, for: mode) }
                throw error
            }
        }
        shortcuts[mode] = shortcut
        if let shortcut {
            UserDefaults.standard.set(try JSONEncoder().encode(shortcut), forKey: "capture.shortcut.\(mode.rawValue)")
        } else {
            UserDefaults.standard.removeObject(forKey: "capture.shortcut.\(mode.rawValue)")
        }
    }

    private func register(_ shortcut: CaptureShortcut, for mode: CaptureMode) throws -> EventHotKeyRef {
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x534B_4348, id: UInt32(CaptureMode.allCases.firstIndex(of: mode)!))
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { throw EditorServiceError.shortcutUnavailable }
        return reference
    }
}
