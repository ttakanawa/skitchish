import AppKit

/// Transient interaction state and a single undo boundary for every user gesture.
@MainActor
final class EditorSession: NSObject {
    var document: EditorDocument
    private var savedDocument: EditorDocument?
    var hasUnsavedChanges: Bool { savedDocument != document }
    let history = UndoManager()
    var selection = Set<UUID>()
    var zoom: CGFloat = 1
    var fitsWindow = true
    var tool: EditorTool {
        didSet {
            UserDefaults.standard.set(tool.rawValue, forKey: "editor.tool")
            onChange?()
        }
    }
    var colorIndex: Int {
        didSet {
            colorIndex = max(-1, min(RGBA.palette.count - 1, colorIndex))
            preferences.set(colorIndex, forKey: "editor.color")
            onChange?()
        }
    }
    private let preferences: UserDefaults
    private(set) var customColor: RGBA
    var sizeIndex: Int {
        didSet {
            UserDefaults.standard.set(sizeIndex, forKey: "editor.size")
            onChange?()
        }
    }
    var stamp: Int {
        didSet {
            stamp = max(0, min(4, stamp))
            preferences.set(stamp, forKey: "editor.stamp")
            onChange?()
        }
    }
    var onChange: (() -> Void)?
    var onCommit: (() -> Void)?
    static let widths: [CGFloat] = [2, 4, 6, 12, 20]
    var color: RGBA { colorIndex == -1 ? customColor : RGBA.palette[min(max(colorIndex, 0), RGBA.palette.count - 1)] }
    var strokeWidth: CGFloat { Self.widths[min(max(sizeIndex, 0), 4)] }

    init(document: EditorDocument, preferences suppliedPreferences: UserDefaults? = nil) {
        self.document = document
        savedDocument = document
        let process = ProcessInfo.processInfo
        let preferences: UserDefaults
        if let suppliedPreferences {
            preferences = suppliedPreferences
        } else if process.arguments.contains("--ui-testing")
            || process.environment["XCTestConfigurationFilePath"] != nil
        {
            // A test may share its unique suite across relaunches without changing
            // the user's real preference. Other test sessions start independently.
            let suite =
                process.environment["SKITCHISH_STAMP_TEST_SUITE"] ?? "com.skitchish.stamp-tests.\(UUID().uuidString)"
            preferences = UserDefaults(suiteName: suite)!
        } else {
            preferences = .standard
        }
        self.preferences = preferences
        if let data = preferences.data(forKey: "editor.customColor"),
            let saved = try? JSONDecoder().decode(RGBA.self, from: data),
            saved.isValid
        {
            customColor = saved
        } else {
            customColor = .palette[0]
        }
        stamp = max(0, min(4, preferences.integer(forKey: "editor.stamp")))
        tool = EditorTool(rawValue: UserDefaults.standard.string(forKey: "editor.tool") ?? "arrow") ?? .arrow
        colorIndex = max(-1, min(RGBA.palette.count - 1, preferences.integer(forKey: "editor.color")))
        sizeIndex =
            UserDefaults.standard.object(forKey: "editor.size") == nil
            ? 2 : UserDefaults.standard.integer(forKey: "editor.size")
        super.init()
        history.groupsByEvent = false
    }
    func setCustomColor(_ value: RGBA) {
        guard value.isValid else { return }
        customColor = value
        if let data = try? JSONEncoder().encode(value) { preferences.set(data, forKey: "editor.customColor") }
        colorIndex = -1
    }
    func change(_ name: String, _ action: (inout EditorDocument) -> Void) {
        let old = document
        action(&document)
        commit(from: old, name: name)
    }
    func commit(from old: EditorDocument, name: String) {
        guard old != document else {
            onChange?()
            return
        }
        history.beginUndoGrouping()
        history.registerUndo(withTarget: self) { target in target.restore(old, name: name) }
        history.setActionName(name)
        history.endUndoGrouping()
        didCommitDocument()
    }
    private func restore(_ value: EditorDocument, name: String) {
        let old = document
        document = value
        history.registerUndo(withTarget: self) { target in target.restore(old, name: name) }
        history.setActionName(name)
        didCommitDocument()
    }

    private func didCommitDocument() {
        selection.formIntersection(document.annotations.map(\.id))
        onChange?()
        onCommit?()
    }
    func replace(with value: EditorDocument, isSaved: Bool = false) {
        document = value
        savedDocument = isSaved ? value : nil
        selection.removeAll()
        history.removeAllActions()
        fitsWindow = true
        onChange?()
    }
    func markSaved() {
        savedDocument = document
        onChange?()
    }
    func deleteSelection() {
        change("Delete Annotations") { doc in doc.annotations.removeAll { selection.contains($0.id) } }
    }
    func moveSelection(dx: CGFloat, dy: CGFloat) {
        change("Move Annotations") { doc in
            doc.annotations = doc.annotations.map { selection.contains($0.id) ? $0.translated(dx: dx, dy: dy) : $0 }
            for mark in doc.annotations where selection.contains(mark.id) {
                doc.expandCanvas(toInclude: mark.visualBounds)
            }
        }
    }
    func duplicateSelection() {
        let items = document.annotations.filter { selection.contains($0.id) }.map { item -> Markup in
            var copy = item.translated(dx: 16, dy: 16)
            copy.id = UUID()
            return copy
        }
        append(items, name: "Duplicate Annotations")
    }
    func append(_ items: [Markup], name: String) {
        change(name) { doc in
            doc.annotations += items
            for item in items { doc.expandCanvas(toInclude: item.visualBounds) }
        }
        selection = Set(items.map(\.id))
        onChange?()
    }
}
