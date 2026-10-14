import AppKit
import XCTest

@MainActor
final class SkitchishChromeTests: XCTestCase {
    private func waitForSidebarControl(
        _ element: XCUIElement, centeredAt x: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) {
        let stable = NSPredicate { _, _ in element.exists && element.isHittable && abs(element.frame.midX - x) <= 1 }
        let expectation = XCTNSPredicateExpectation(predicate: stable, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 4), .completed,
            "The sidebar control must finish sliding into place", file: file, line: line)
    }

    private func waitForPalette(
        _ app: XCUIApplication, choice identifier: String, centeredAt x: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            app.descendants(matching: .any)["tool.arrow"].firstMatch.waitForNonExistence(timeout: 4), file: file,
            line: line)
        waitForSidebarControl(
            app.descendants(matching: .any)[identifier].firstMatch, centeredAt: x, file: file, line: line)
    }

    private func waitForNormalToolbar(
        _ app: XCUIApplication, centeredAt x: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            app.descendants(matching: .any)["options.pin"].firstMatch.waitForNonExistence(timeout: 4), file: file,
            line: line)
        waitForSidebarControl(
            app.descendants(matching: .any)["tool.arrow"].firstMatch, centeredAt: x, file: file, line: line)
    }

    private func assertRemainsVisible(
        _ element: XCUIElement, for seconds: TimeInterval = 0.8,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let disappears = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !element.exists }, object: nil)
        disappears.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(for: [disappears], timeout: seconds), .completed,
            "The palette should remain available", file: file, line: line)
    }

    func testPaletteGraceAreaPinMouseExitAndBackgroundDismissal() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SKITCHISH_STAMP_TEST_SUITE"] = "com.skitchish.palette-ui-tests.\(UUID().uuidString)"
        app.launch()
        defer { app.terminate() }
        func control(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
        XCTAssertTrue(control("tool.arrow").waitForExistence(timeout: 10))
        let sidebarX = control("tool.arrow").frame.midX
        let canvas = control("editor.canvas")
        let window = app.windows.firstMatch
        let outside = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4))
        let blankSidebar = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: sidebarX - window.frame.minX, dy: canvas.frame.minY - window.frame.minY + 12))
        for (launcher, option) in [("tool.stamp", "stamp.2"), ("style.color", "color.4"), ("style.size", "size.3")] {
            if launcher != "tool.stamp" {
                control("tool.arrow").click()
                XCTAssertTrue(control("style.color").isEnabled && control("style.size").isEnabled)
            }
            control(launcher).click()
            waitForPalette(app, choice: option, centeredAt: sidebarX)
            let choice = control(option)
            // XCUICoordinate.hover is public in the installed macOS XCTest SDK.
            // Move 20 points beyond the sidebar, within its 40-point grace area,
            // then return. It must not flicker closed near the panel's edge.
            choice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 48, dy: 0)).hover()
            assertRemainsVisible(choice)
            choice.hover()
            waitForSidebarControl(choice, centeredAt: sidebarX)

            let pin = control("options.pin")
            pin.click()
            XCTAssertEqual((pin.value as? String) ?? (pin.value as? NSNumber)?.stringValue, "1")
            outside.hover()
            assertRemainsVisible(choice)
            choice.click()
            assertRemainsVisible(choice, for: 0.5)
            XCTAssertFalse(control("tool.arrow").exists, "Pinning allows repeated choices")
            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = "Pinned \(launcher) palette after choosing"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            pin.click()
            waitForNormalToolbar(app, centeredAt: sidebarX)
            if launcher == "tool.stamp" {
                XCTAssertFalse(control("style.color").isEnabled)
                XCTAssertFalse(control("style.size").isEnabled)
            }

            control(launcher).click()
            waitForPalette(app, choice: option, centeredAt: sidebarX)
            outside.hover()
            waitForNormalToolbar(app, centeredAt: sidebarX)

            control(launcher).click()
            waitForPalette(app, choice: option, centeredAt: sidebarX)
            blankSidebar.click()
            waitForNormalToolbar(app, centeredAt: sidebarX)
        }
    }

    func testStampRepertoireAlwaysOpensAndRemembersLastChoice() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SKITCHISH_STAMP_TEST_SUITE"] = "com.skitchish.stamp-ui-tests.\(UUID().uuidString)"
        app.launch()
        defer { app.terminate() }
        func control(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
        XCTAssertTrue(control("tool.stamp").waitForExistence(timeout: 10))
        let sidebarX = control("tool.arrow").frame.midX
        XCTAssertEqual(control("tool.stamp").label, "Stamp ✓")
        control("tool.arrow").click()
        // A plain click opens the repertoire even when another tool is active.
        control("tool.stamp").click()
        waitForPalette(app, choice: "stamp.1", centeredAt: sidebarX)
        XCTAssertFalse(app.checkBoxes["Tail"].exists)
        control("stamp.1").click()
        waitForNormalToolbar(app, centeredAt: sidebarX)
        XCTAssertEqual(control("tool.stamp").label, "Stamp ×")
        // It also opens while Stamp itself is active; choosing updates the icon.
        control("tool.stamp").click()
        waitForPalette(app, choice: "stamp.4", centeredAt: sidebarX)
        control("stamp.4").click()
        waitForNormalToolbar(app, centeredAt: sidebarX)
        XCTAssertEqual(control("tool.stamp").label, "Stamp ♥")
        control("tool.arrow").click()
        XCTAssertEqual(control("tool.stamp").label, "Stamp ♥", "Changing tools must retain the chosen stamp")

        app.terminate()
        app.launch()
        XCTAssertTrue(control("tool.stamp").waitForExistence(timeout: 10))
        XCTAssertEqual(control("tool.stamp").label, "Stamp ♥", "The chosen stamp must survive an app relaunch")
        control("tool.stamp").click()
        waitForPalette(app, choice: "stamp.1", centeredAt: sidebarX)
        for index in 0..<5 { XCTAssertTrue(control("stamp.\(index)").exists) }
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Remembered stamp repertoire after relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        waitForNormalToolbar(app, centeredAt: sidebarX)
        XCTAssertEqual(control("tool.stamp").label, "Stamp ♥", "Closing options must preserve the remembered choice")
    }

    func testCenteredExportAndOptionsReplaceTheToolbar() throws {
        continueAfterFailure = false
        let clipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(
                uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        func control(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
        defer {
            app.terminate()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(
                clipboard.map { contents in
                    let item = NSPasteboardItem()
                    for (type, data) in contents { item.setData(data, forType: type) }
                    return item
                })
        }
        let window = app.windows.firstMatch
        let drag = app.buttons["export.drag"]
        XCTAssertTrue(drag.waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Tools"].click()
        app.menuItems["Rectangle"].click()
        XCTAssertEqual(drag.frame.midX, window.frame.midX, accuracy: 1)
        XCTAssertLessThan(window.frame.maxY - drag.frame.maxY, 3)
        XCTAssertTrue(app.buttons["Copy Image"].exists)
        XCTAssertFalse(control("color.0").exists)
        XCTAssertFalse(control("size.0").exists)
        XCTAssertFalse(control("tool.ellipse").exists)
        let sidebarX = control("tool.arrow").frame.midX
        let canvas = app.descendants(matching: .any)["editor.canvas"].firstMatch
        func assertInsideSidebar(_ item: XCUIElement) {
            XCTAssertEqual(item.frame.midX, sidebarX, accuracy: 1)
            XCTAssertLessThanOrEqual(item.frame.maxX, canvas.frame.minX)
            XCTAssertGreaterThan(item.frame.minY, canvas.frame.minY)
            XCTAssertLessThan(item.frame.maxY, canvas.frame.maxY)
        }
        app.buttons["style.color"].click()
        waitForPalette(app, choice: "color.4", centeredAt: sidebarX)
        XCTAssertFalse(control("tool.arrow").exists, "The normal tools are replaced, not covered by a popover")
        for index in 0..<8 { assertInsideSidebar(control("color.\(index)")) }
        assertInsideSidebar(control("color.custom"))
        XCTAssertEqual(app.windows.count, 1, "Options stay inside the editor window")
        let colors = XCTAttachment(screenshot: window.screenshot())
        colors.name = "Color choices replace the left toolbar"
        colors.lifetime = .keepAlways
        add(colors)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        waitForNormalToolbar(app, centeredAt: sidebarX)
        app.buttons["style.color"].click()
        waitForPalette(app, choice: "color.4", centeredAt: sidebarX)
        control("color.4").click()
        waitForNormalToolbar(app, centeredAt: sidebarX)
        app.buttons["style.size"].click()
        waitForPalette(app, choice: "size.3", centeredAt: sidebarX)
        XCTAssertFalse(control("tool.arrow").exists)
        for index in 0..<5 { assertInsideSidebar(control("size.\(index)")) }
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        waitForNormalToolbar(app, centeredAt: sidebarX)
        app.buttons["style.size"].click()
        waitForPalette(app, choice: "size.3", centeredAt: sidebarX)
        control("size.3").click()
        waitForNormalToolbar(app, centeredAt: sidebarX)
        // One click opens shapes even while another tool is active; choosing a
        // subtype then restores its selected primary icon in the same column.
        app.menuBars.menuBarItems["Tools"].click()
        app.menuItems["Arrow"].click()
        control("tool.rectangle").click()
        let ellipse = control("variant.ellipse")
        waitForPalette(app, choice: "variant.ellipse", centeredAt: sidebarX)
        assertInsideSidebar(ellipse)
        XCTAssertFalse(control("tool.arrow").exists)
        func assertSelectedShape(_ selected: String) {
            for shape in ["rectangle", "roundedRectangle", "ellipse", "line"] {
                let value = control("variant.\(shape)").value
                XCTAssertEqual(
                    (value as? String) ?? (value as? NSNumber)?.stringValue,
                    shape == selected ? "1" : "0",
                    "The repertoire must show only the remembered shape as selected")
            }
        }
        assertSelectedShape("rectangle")
        ellipse.click()
        waitForNormalToolbar(app, centeredAt: sidebarX)
        waitForSidebarControl(control("tool.ellipse"), centeredAt: sidebarX)
        XCTAssertFalse(control("variant.ellipse").exists)
        control("tool.arrow").click()
        control("tool.ellipse").click()
        waitForPalette(app, choice: "variant.ellipse", centeredAt: sidebarX)
        assertSelectedShape("ellipse")
        ellipse.click()
        waitForNormalToolbar(app, centeredAt: sidebarX)
        waitForSidebarControl(control("tool.ellipse"), centeredAt: sidebarX)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(
            forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        app.typeKey("c", modifierFlags: .command)
        let data = try XCTUnwrap(
            NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("com.skitchish.annotations.v1")))
        let marks = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0]["tool"] as? String, "ellipse")
        XCTAssertEqual(marks[0]["size"] as? Double, 12)
        let color = try XCTUnwrap(marks[0]["color"] as? [String: Double])
        XCTAssertGreaterThan(color["b"] ?? 0, color["r"] ?? 1)
        control("tool.stamp").click()
        waitForPalette(app, choice: "stamp.1", centeredAt: sidebarX)
        for index in 0..<5 { assertInsideSidebar(control("stamp.\(index)")) }
        XCTAssertFalse(control("tool.arrow").exists)
        let stamps = XCTAttachment(screenshot: window.screenshot())
        stamps.name = "Stamp choices replace the left toolbar"
        stamps.lifetime = .keepAlways
        add(stamps)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        waitForNormalToolbar(app, centeredAt: sidebarX)
        control("tool.arrow").click()
        app.buttons["style.size"].click()
        waitForPalette(app, choice: "size.3", centeredAt: sidebarX)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).click()
        waitForNormalToolbar(app, centeredAt: sidebarX)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Centered drag tab and compact tool groups"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.menuBars.menuBarItems["Tools"].click()
        app.menuItems["Rectangle"].click()
        app.buttons["style.color"].click()
        waitForPalette(app, choice: "color.0", centeredAt: sidebarX)
        control("color.0").click()
        waitForNormalToolbar(app, centeredAt: sidebarX)
        app.typeKey("3", modifierFlags: [.option, .command])
    }
}
