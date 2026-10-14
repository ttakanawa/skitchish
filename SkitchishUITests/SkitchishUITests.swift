import AppKit
import ImageIO
import XCTest

/// Drives the shipping responder chain and verifies actual clipboard output.
/// UI-test mode keeps the user's drafts separate from these temporary documents.
@MainActor
final class SkitchishUITests: XCTestCase {
    private var app: XCUIApplication!
    private let annotationType = NSPasteboard.PasteboardType("com.skitchish.annotations.v1")
    private var originalClipboard: [[NSPasteboard.PasteboardType: Data]] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        originalClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(
                uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(tool("arrow").waitForExistence(timeout: 10))
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: [.command, .option])
        app.buttons["Fit"].click()
    }

    override func tearDownWithError() throws {
        app.terminate()
        NSPasteboard.general.clearContents()
        let restored = originalClipboard.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        NSPasteboard.general.writeObjects(restored)
    }

    private func tool(_ name: String) -> XCUIElement { app.descendants(matching: .any)["tool." + name].firstMatch }
    private var canvas: XCUIElement { app.descendants(matching: .any)["editor.canvas"].firstMatch }
    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
    private func draw(tool: String, from: CGVector, to: CGVector) {
        self.tool(tool).click()
        if tool == "rectangle" {
            // The first click opens the repertoire. Wait for each slide to finish
            // before choosing the shape and beginning the canvas gesture.
            XCTAssertTrue(self.tool("arrow").waitForNonExistence(timeout: 4))
            let rectangle = app.descendants(matching: .any)["variant.rectangle"].firstMatch
            XCTAssertTrue(rectangle.waitForExistence(timeout: 4))
            rectangle.click()
            XCTAssertTrue(app.descendants(matching: .any)["options.pin"].firstMatch.waitForNonExistence(timeout: 4))
            XCTAssertTrue(self.tool(tool).waitForExistence(timeout: 4))
        }
        point(from.dx, from.dy).press(forDuration: 0.05, thenDragTo: point(to.dx, to.dy))
    }
    private func selectToolFromMenu() {
        app.menuBars.menuBarItems["Tools"].click()
        app.menuItems["Select"].click()
    }
    private func selectAllAndCopy() {
        selectToolFromMenu()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
    }
    private func copiedMarks() throws -> [[String: Any]] {
        let data = try XCTUnwrap(
            NSPasteboard.general.data(forType: annotationType),
            "Selected annotations must retain editable clipboard data")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
    private func copiedImage() throws -> CGImage {
        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLayoutRemainsStableAfterSaveAndExportSheets() throws {
        let header = app.buttons["Copy Image"]
        let footer = app.buttons["export.drag"]
        let initialCanvas = canvas.frame
        XCTAssertLessThanOrEqual(header.frame.maxY, initialCanvas.minY + 1)
        XCTAssertGreaterThanOrEqual(footer.frame.minY, initialCanvas.maxY - 1)
        for key in ["s", "e"] {
            app.typeKey(key, modifierFlags: .command)
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            sheet.buttons["Cancel"].click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
            XCTAssertEqual(canvas.frame.minY, initialCanvas.minY, accuracy: 1)
            XCTAssertEqual(canvas.frame.height, initialCanvas.height, accuracy: 1)
            XCTAssertLessThanOrEqual(header.frame.maxY, canvas.frame.minY + 1)
            XCTAssertGreaterThanOrEqual(footer.frame.minY, canvas.frame.maxY - 1)
        }
        attachScreenshot("Stable layout after native sheets")
    }

    func testDrawingSelectionDeleteUndoAndRedo() throws {
        draw(tool: "arrow", from: CGVector(dx: 0.20, dy: 0.22), to: CGVector(dx: 0.43, dy: 0.40))
        draw(tool: "rectangle", from: CGVector(dx: 0.56, dy: 0.48), to: CGVector(dx: 0.77, dy: 0.70))
        selectAllAndCopy()
        let created = try copiedMarks()
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(Set(created.compactMap { $0["tool"] as? String }), ["arrow", "rectangle"])
        attachScreenshot("Arrow and rectangle selection")
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.buttons["Copy Image"].click()
        XCTAssertNil(NSPasteboard.general.data(forType: annotationType))
        let blank = try copiedImage()
        XCTAssertEqual(blank.width, 1000)
        XCTAssertEqual(blank.height, 700)
        selectToolFromMenu()
        app.typeKey("z", modifierFlags: .command)
        selectAllAndCopy()
        attachScreenshot("After delete and undo")
        XCTAssertEqual(try copiedMarks().count, 2, "Delete must be one reversible operation")
        app.typeKey("z", modifierFlags: [.command, .shift])
        app.buttons["Copy Image"].click()
        XCTAssertNil(NSPasteboard.general.data(forType: annotationType))
        XCTAssertEqual(try copiedImage().width, 1000)
    }

    func testJapaneseMultilineTextAndNativeTextUndo() throws {
        tool("text").click()
        point(0.25, 0.30).click()
        let field = app.textViews["annotation.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let expected = "Skitchish 日本語\n折り返しと改行"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(expected, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(field.value as? String, expected)
        app.typeKey("a", modifierFlags: .command)
        field.typeText("temporary")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(field.value as? String, expected)
        selectToolFromMenu()
        selectAllAndCopy()
        let marks = try copiedMarks()
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?["text"] as? String, expected)
        attachScreenshot("Japanese multiline annotation")
        app.buttons["Copy Image"].click()
        XCTAssertNil(NSPasteboard.general.data(forType: annotationType))
        XCTAssertEqual(try copiedImage().height, 700)
    }

    func testBlankDoubleClickEntersTextAndOutsideClickReturnsToSelection() throws {
        tool("arrow").click()
        point(0.25, 0.30).doubleClick()
        let field = app.textViews["annotation.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Double click text")
        point(0.75, 0.75).click()
        XCTAssertFalse(field.exists)
        // A second blank click must remain selection, rather than creating a new text field.
        point(0.72, 0.70).click()
        XCTAssertFalse(field.exists)
        selectAllAndCopy()
        XCTAssertEqual(try copiedMarks().count, 1)
        XCTAssertEqual(try copiedMarks().first?["text"] as? String, "Double click text")
        app.typeKey("z", modifierFlags: .command)
        app.buttons["Copy Image"].click()
        XCTAssertNil(NSPasteboard.general.data(forType: annotationType))
    }

    func testTextSideHandlesRewrapWithoutChangingFontSizeAndUndo() throws {
        struct TextState: Decodable {
            let points: [CGPoint]
            let size: CGFloat
            let text: String
            var bounds: CGRect {
                CGRect(
                    x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                    width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            }
        }
        func copiedText() throws -> TextState {
            let marks = try copiedMarks()
            XCTAssertEqual(marks.count, 1)
            let mark = try XCTUnwrap(marks.first)
            XCTAssertEqual(mark["tool"] as? String, "text")
            let value = try JSONDecoder().decode(TextState.self, from: JSONSerialization.data(withJSONObject: mark))
            XCTAssertEqual(value.points.count, 2)
            return value
        }

        // At actual size a one-point mouse move is one image pixel. Keeping the
        // insertion coordinate avoids relying on rounded fit-zoom labels or scrollbars.
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Actual Size"].click()
        tool("text").click()
        let insertion = point(0.23, 0.25)
        insertion.click()
        let field = app.textViews["annotation.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let text = "One two three four five six seven eight nine ten eleven twelve thirteen fourteen."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        point(0.8, 0.8).click()
        XCTAssertFalse(field.exists)
        selectAllAndCopy()
        let original = try copiedText()
        XCTAssertEqual(original.text, text)
        XCTAssertGreaterThan(original.bounds.width, 200)

        for leftEdge in [false, true] {
            let handle = insertion.withOffset(
                CGVector(
                    dx: leftEdge ? 0 : original.bounds.width,
                    dy: original.bounds.height / 2))
            let destination = handle.withOffset(CGVector(dx: leftEdge ? 120 : -120, dy: 0))
            handle.press(forDuration: 0.05, thenDragTo: destination)
            selectAllAndCopy()
            let wrapped = try copiedText()
            XCTAssertEqual(wrapped.text, original.text)
            XCTAssertEqual(
                wrapped.size, original.size, accuracy: 0.001, "Side handles rewrap text; they must not scale its font")
            XCTAssertEqual(wrapped.bounds.width, original.bounds.width - 120, accuracy: 2)
            XCTAssertGreaterThan(wrapped.bounds.height, original.bounds.height + 10)
            XCTAssertEqual(wrapped.bounds.minY, original.bounds.minY, accuracy: 1)
            XCTAssertEqual(
                leftEdge ? wrapped.bounds.maxX : wrapped.bounds.minX,
                leftEdge ? original.bounds.maxX : original.bounds.minX, accuracy: 1,
                "The opposite edge must remain fixed")
            attachScreenshot(
                leftEdge
                    ? "Left text handle rewraps at fixed font size" : "Right text handle rewraps at fixed font size")

            app.typeKey("z", modifierFlags: .command)
            selectAllAndCopy()
            let restored = try copiedText()
            XCTAssertEqual(restored.points, original.points, "One Undo must restore the entire width gesture")
            XCTAssertEqual(restored.size, original.size)
            XCTAssertEqual(restored.text, original.text)
        }
    }

    func testPastedImagePixelDimensionsRemainStableWhenZoomChanges() throws {
        let bitmap = try XCTUnwrap(
            CGContext(
                data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.systemBlue.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        let image = try XCTUnwrap(bitmap.makeImage())
        let representation = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        selectToolFromMenu()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.windows["Pasted Image — Skitchish"].waitForExistence(timeout: 5))
        for action in ["+", "+", "−", "Fit"] {
            app.buttons[action].click()
            app.buttons["Copy Image"].click()
            let output = try copiedImage()
            XCTAssertEqual(output.width, 320)
            XCTAssertEqual(output.height, 240)
            XCTAssertNil(NSPasteboard.general.data(forType: annotationType))
        }
    }

    func testExistingStampSymbolAndLabelCanBeEdited() throws {
        tool("stamp").click()
        app.descendants(matching: .any)["stamp.0"].firstMatch.click()
        point(0.35, 0.35).click()
        selectAllAndCopy()
        XCTAssertEqual(try copiedMarks().first?["stamp"] as? Int, 0)
        tool("stamp").click()
        app.descendants(matching: .any)["stamp.2"].firstMatch.click()
        selectAllAndCopy()
        XCTAssertEqual(try copiedMarks().first?["stamp"] as? Int, 2)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let field = app.textViews["annotation.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Review this")
        selectAllAndCopy()
        XCTAssertEqual(try copiedMarks().first?["text"] as? String, "Review this")
        attachScreenshot("Edited stamp symbol and label")
    }

    func testTextCornerScalesTheFontAndBoxTogether() throws {
        struct TextState: Decodable {
            let points: [CGPoint]
            let size: CGFloat
            let text: String
        }
        func state() throws -> TextState {
            try JSONDecoder().decode(
                TextState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(copiedMarks().first)))
        }
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Actual Size"].click()
        tool("text").click()
        let insertion = point(0.23, 0.25)
        insertion.click()
        let field = app.textViews["annotation.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Scale this text")
        point(0.8, 0.8).click()
        selectAllAndCopy()
        let before = try state()
        let width = before.points[1].x - before.points[0].x
        let height = before.points[1].y - before.points[0].y
        let corner = insertion.withOffset(CGVector(dx: width, dy: height))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: width * 0.5, dy: height * 0.5)))
        selectAllAndCopy()
        let after = try state()
        XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(after.size, before.size * 1.5, accuracy: 0.1)
        XCTAssertEqual(after.points[0].x, before.points[0].x, accuracy: 1)
        XCTAssertEqual(after.points[0].y, before.points[0].y, accuracy: 1)
        XCTAssertEqual(after.points[1].x - after.points[0].x, width * 1.5, accuracy: 2)
        attachScreenshot("Text corner scales font and box together")
        app.typeKey("z", modifierFlags: .command)
        selectAllAndCopy()
        XCTAssertEqual(try state().size, before.size)
        XCTAssertEqual(try state().points, before.points)
        app.typeKey("z", modifierFlags: [.command, .shift])
        selectAllAndCopy()
        XCTAssertEqual(try state().size, after.size)
    }

    func testStampPointerHandleAndDoubleClickLeftLabel() throws {
        struct StampState: Decodable {
            let points: [CGPoint]
            let tail: Bool
            let tailDirection: Int?
            let text: String
        }
        func state() throws -> StampState {
            try JSONDecoder().decode(
                StampState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(copiedMarks().first)))
        }
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Actual Size"].click()
        tool("stamp").click()
        app.descendants(matching: .any)["stamp.1"].firstMatch.click()
        let center = point(0.55, 0.42)
        center.click()
        selectAllAndCopy()
        let plain = try state()
        XCTAssertFalse(plain.tail)
        // At actual size the empty stamp's + control sits on the selection ring,
        // opposite its left-side label tab. Body drags now move the whole stamp.
        let diameter = abs(plain.points[1].x - plain.points[0].x)
        let pointerHandle = center.withOffset(CGVector(dx: max(42, diameter * 1.35), dy: 0))
        pointerHandle.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 70, dy: -70)))
        selectAllAndCopy()
        let pointed = try state()
        XCTAssertTrue(pointed.tail)
        XCTAssertEqual(pointed.tailDirection, 7)
        XCTAssertEqual(pointed.points, plain.points, "Pointer gestures must leave the circle anchored")
        app.typeKey("z", modifierFlags: .command)
        selectAllAndCopy()
        XCTAssertFalse(try state().tail)
        app.typeKey("z", modifierFlags: [.command, .shift])
        selectAllAndCopy()
        XCTAssertTrue(try state().tail)
        center.click()
        let field = app.textViews["annotation.text"]
        XCTAssertFalse(field.exists, "A single click must select the stamp without editing its label")
        selectAllAndCopy()
        XCTAssertEqual(try state().points, plain.points)
        center.doubleClick()
        XCTAssertTrue(field.waitForExistence(timeout: 3), "Double click must edit the label")
        XCTAssertLessThan(field.frame.maxX, center.screenPoint.x)
        field.typeText("Review this")
        let window = app.windows.firstMatch
        let source = try XCTUnwrap(CGImageSourceCreateWithData(window.screenshot().pngRepresentation as CFData, nil))
        let shot = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let scale = CGFloat(shot.width) / window.frame.width
        let labelRect = CGRect(
            x: (field.frame.minX - window.frame.minX) * scale,
            y: (field.frame.minY - window.frame.minY) * scale,
            width: field.frame.width * scale, height: field.frame.height * scale)
        let label = try XCTUnwrap(shot.cropping(to: labelRect))
        let pixels = try XCTUnwrap(
            CGContext(
                data: nil, width: label.width, height: label.height, bitsPerComponent: 8,
                bytesPerRow: label.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(label, in: CGRect(x: 0, y: 0, width: label.width, height: label.height))
        let bytes = try XCTUnwrap(pixels.data).assumingMemoryBound(to: UInt8.self)
        var blackPixels = 0
        var whiteGlyphPixels = 0
        var whiteFramePixels = 0
        let margin = max(3, Int(3 * scale))
        for y in 0..<label.height {
            for x in 0..<label.width {
                let offset = (y * label.width + x) * 4
                let rgb = (bytes[offset], bytes[offset + 1], bytes[offset + 2])
                if rgb.0 < 20 && rgb.1 < 20 && rgb.2 < 20 { blackPixels += 1 }
                if rgb.0 > 230 && rgb.1 > 230 && rgb.2 > 230 {
                    if x >= margin && x < label.width - margin && y >= margin && y < label.height - margin {
                        whiteGlyphPixels += 1
                    } else {
                        whiteFramePixels += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(blackPixels, 100, "The native label editor must have a black background")
        XCTAssertGreaterThan(whiteGlyphPixels, 50, "Label text must stay white inside the black frame")
        XCTAssertGreaterThan(whiteFramePixels, 30, "The native editor must retain the white frame")
        attachScreenshot("Stamp stays visible while left label is edited")
        point(0.85, 0.8).click()
        selectAllAndCopy()
        let labeled = try state()
        XCTAssertEqual(labeled.text, "Review this")
        XCTAssertEqual(labeled.points, plain.points)
        attachScreenshot("Eight-direction stamp pointer and label on the left")
    }

    func testNewStampDragCreatesPointerAndBodyDragMovesStamp() throws {
        struct StampState: Decodable {
            let points: [CGPoint]
            let tail: Bool
            let tailDirection: Int?
        }
        func state() throws -> StampState {
            let marks = try copiedMarks()
            XCTAssertEqual(marks.count, 1)
            return try JSONDecoder().decode(
                StampState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(marks.first)))
        }
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Actual Size"].click()
        tool("stamp").click()
        app.descendants(matching: .any)["stamp.1"].firstMatch.click()
        let center = point(0.55, 0.42)
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 70, dy: -70)))
        selectAllAndCopy()
        let created = try state()
        XCTAssertTrue(created.tail, "Dragging while creating a new stamp must retain its pointer")
        XCTAssertEqual(created.tailDirection, 7)

        let offset = CGVector(dx: 24, dy: 16)
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(offset))
        XCTAssertFalse(app.textViews["annotation.text"].exists)
        selectAllAndCopy()
        let moved = try state()
        XCTAssertEqual(moved.tail, created.tail)
        XCTAssertEqual(moved.tailDirection, created.tailDirection)
        for (before, after) in zip(created.points, moved.points) {
            XCTAssertEqual(after.x - before.x, offset.dx, accuracy: 1)
            XCTAssertEqual(after.y - before.y, offset.dy, accuracy: 1)
        }
        app.typeKey("z", modifierFlags: .command)
        selectAllAndCopy()
        XCTAssertEqual(try state().points, created.points, "One Undo must restore the complete body drag")
        XCTAssertTrue(try state().tail)
        app.typeKey("z", modifierFlags: [.command, .shift])
        selectAllAndCopy()
        XCTAssertEqual(try state().points, moved.points)
        attachScreenshot("New stamp pointer survives a body move")
    }
}
