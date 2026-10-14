import AppKit

extension EditorWindowController {
    func installMenu() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return m
        }
        @discardableResult func add(
            _ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
            _ flags: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
        ) -> NSMenuItem {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.target = target
            return item
        }
        let app = menu("Skitchish")
        add(app, "About Skitchish", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        add(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
        app.addItem(.separator())
        add(app, "Hide Skitchish", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "Quit Skitchish", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("File")
        add(file, "New Blank", #selector(newDocument(_:)), "n", target: self)
        add(file, "Open…", #selector(openFile(_:)), "o", target: self)
        add(file, "Save Editable Document…", #selector(saveDocument(_:)), "s", target: self)
        add(file, "Restore Draft…", #selector(showDrafts(_:)), target: self)
        file.addItem(.separator())
        add(file, "Export Image…", #selector(exportImage(_:)), "e", target: self)
        add(file, "Print…", #selector(printImage(_:)), "p", target: self)
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Edit")
        add(edit, "Undo", #selector(CanvasView.undo(_:)), "z")
        add(edit, "Redo", #selector(CanvasView.redo(_:)), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Copy Image", #selector(copyImage(_:)), "c", [.command, .shift], target: self)
        add(edit, "Duplicate", #selector(duplicate(_:)), "d", target: self)
        add(edit, "Delete", #selector(remove(_:)), target: self)
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let tools = menu("Tools")
        for (index, item) in toolItems.enumerated() {
            let entry = add(
                tools, item.title, #selector(selectToolMenu(_:)), item.shortcut, [.command, .option], target: self)
            entry.tag = index
        }
        tools.addItem(.separator())
        for index in 0..<5 {
            let item = add(
                tools, ["Smallest", "Small", "Medium", "Large", "Largest"][index], #selector(pickSizeMenu(_:)),
                String(index + 1), [.command, .option], target: self)
            item.tag = index
        }
        let image = menu("Image")
        add(image, "Resize…", #selector(resizeImage(_:)), target: self)
        add(image, "Rotate Clockwise", #selector(rotate(_:)), "r", target: self)
        add(image, "Rotate Counterclockwise", #selector(rotateBack(_:)), "r", [.command, .shift], target: self)
        add(image, "Flip Horizontally", #selector(flipHorizontal(_:)), "f", [.command, .shift], target: self)
        add(image, "Flip Vertically", #selector(flipVertical(_:)), target: self)
        let view = menu("View")
        add(view, "Fit in Window", #selector(fit(_:)), "0", target: self)
        add(view, "Actual Size", #selector(actualSize(_:)), "1", target: self)
        add(view, "Zoom In", #selector(zoomIn(_:)), "+", target: self)
        add(view, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)
        let capture = menu("Capture")
        add(capture, "Area", #selector(snapRegion(_:)), "5", [.command, .shift], target: self)
        add(capture, "Full Screen", #selector(snapFull(_:)), "6", [.command, .shift], target: self)
        add(capture, "Window", #selector(snapWindow(_:)), "w", [.command, .shift], target: self)
        add(capture, "Previous Area", #selector(snapPrevious(_:)), "5", [.command, .shift, .option], target: self)
        add(capture, "Timed Area…", #selector(snapTimed(_:)), "5", [.command, .shift, .control], target: self)
        add(capture, "Menu…", #selector(snapMenu(_:)), "u", [.command, .shift], target: self)
        NSApp.mainMenu = main
    }
}
