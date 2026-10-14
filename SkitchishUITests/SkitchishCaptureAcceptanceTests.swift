import AppKit
import ImageIO
import XCTest

/// Opt-in tests of an already-running signed app, never the UI-test Debug launch target.
/// TEST_RUNNER_SKITCHISH_CAPTURE_TESTS=1 xcodebuild test … -only-testing:SkitchishUITests/SkitchishCaptureAcceptanceTests
/// Grant screen-recording permission manually before running. Tests never change permissions.
@MainActor
final class SkitchishCaptureAcceptanceTests: XCTestCase {
    private var app: XCUIApplication!
    private var originalClipboard: [[NSPasteboard.PasteboardType: Data]]?
    private var fixtureDirectory: URL?
    private var previewFixtureWindow: XCUIElement?
    private var preview: XCUIApplication?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SKITCHISH_CAPTURE_TESTS"] == "1" || environment["TEST_RUNNER_SKITCHISH_CAPTURE_TESTS"] == "1",
            "Set TEST_RUNNER_SKITCHISH_CAPTURE_TESTS=1 for signed-app capture acceptance.")
        continueAfterFailure = false
        let running = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.skitchish.Skitchish").first,
            "Start the final signed Release app first. This test never launches an editor.")
        if let expectedPath = environment["SKITCHISH_CAPTURE_APP_PATH"]
            ?? environment["TEST_RUNNER_SKITCHISH_CAPTURE_APP_PATH"]
        {
            XCTAssertEqual(
                running.bundleURL?.standardizedFileURL.path,
                URL(fileURLWithPath: expectedPath).standardizedFileURL.path,
                "The running editor must be the specified signed Release artifact.")
        }
        let identity = XCTAttachment(
            string: "Attached editor: \(running.bundleURL?.path ?? "unknown")\nPID: \(running.processIdentifier)")
        identity.name = "Signed capture target"
        identity.lifetime = .keepAlways
        add(identity)
        originalClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(
                uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        app = XCUIApplication(url: try XCTUnwrap(running.bundleURL))
        XCTAssertNotEqual(app.state, .notRunning)
        app.activate()
        if captureOverlay.exists {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
        if captureCountdown.buttons["Cancel"].exists {
            captureCountdown.buttons["Cancel"].click()
        }
        XCTAssertTrue(app.buttons["Copy Image"].waitForExistence(timeout: 10))
        // The regular paste flow saves the previously active document before switching to this fixture.
        app.menuBars.menuBarItems["Tools"].click()
        app.menuItems["Select"].click()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try fixturePNG(), forType: .png)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.windows["Pasted Image — Skitchish"].waitForExistence(timeout: 10))
        XCTAssertEqual(try copyImage().width, 96)
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            if captureOverlay.exists {
                app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            }
            if captureCountdown.buttons["Cancel"].exists {
                captureCountdown.buttons["Cancel"].click()
            }
        }
        if let preview, let fixture = previewFixtureWindow, fixture.exists {
            preview.activate()
            fixture.click()
            preview.typeKey("w", modifierFlags: .command)
        }
        if let fixtureDirectory { try? FileManager.default.removeItem(at: fixtureDirectory) }
        if let originalClipboard {
            NSPasteboard.general.clearContents()
            let items = originalClipboard.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, value) in values { item.setData(value, forType: type) }
                return item
            }
            NSPasteboard.general.writeObjects(items)
        }
        // Keep the signed editor running; neither launch nor termination is part of this suite.
        try super.tearDownWithError()
    }

    func testFullScreenRegionPreviousAreaAndEscapeCancellation() throws {
        let menuLocation = app.menuBars.menuBarItems["Capture"].coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).screenPoint
        let screen = try screen(containingQuartzPoint: menuLocation)
        chooseCapture("Full Screen")
        try waitForCapture()
        let fullscreen = try copyImage()
        XCTAssertEqual(fullscreen.width, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
        XCTAssertEqual(fullscreen.height, Int((screen.frame.height * screen.backingScaleFactor).rounded()))

        chooseCapture("Area")
        let expected = try selectRegion(width: 160, height: 100)
        try waitForCapture()
        let region = try copyImage()
        XCTAssertEqual(region.width, expected.width)
        XCTAssertEqual(region.height, expected.height)

        chooseCapture("Previous Area")
        try waitForCapture()
        let previous = try copyImage()
        XCTAssertEqual(previous.width, expected.width)
        XCTAssertEqual(previous.height, expected.height)
        let beforeCancel = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        chooseCapture("Area")
        XCTAssertTrue(captureOverlay.waitForExistence(timeout: 10), "Capture overlay missing.\n\(app.debugDescription)")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let cancelled = XCTNSPredicateExpectation(
            predicate: NSPredicate { [self] _, _ in
                !captureOverlay.exists && !captureCountdown.exists && app.buttons["Copy Image"].isHittable
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 10), .completed)
        _ = try copyImage()
        XCTAssertEqual(
            NSPasteboard.general.data(forType: .png), beforeCancel,
            "Cancelling selection must preserve the current document exactly.")
        attachDimensions("Full Screen + Area + Previous Area + Escape", images: [fullscreen, region, previous])
    }

    func testTimedAndMenuCaptureCompleteAtSelectedPixelDimensions() throws {
        for mode in ["Timed Area…", "Menu…"] {
            chooseCapture(mode)
            let expected = try selectRegion(width: 180, height: 120)
            try waitForCapture(timeout: 75)
            let image = try copyImage()
            XCTAssertEqual(image.width, expected.width)
            XCTAssertEqual(image.height, expected.height)
            attachDimensions(mode, images: [image])
        }
        // This verifies the menu capture route and delay. Visible menu inclusion is a separate
        // manual visual check; these assertions deliberately do not claim to verify menu pixels.
    }

    func testWindowCaptureOfGeneratedPreviewFixture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Skitchish-Capture-\(UUID().uuidString)", isDirectory: true)
        fixtureDirectory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Capture Window Fixture.png")
        try fixturePNG().write(to: url)
        let previewURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview"))
        let opened = expectation(description: "Open only the generated capture fixture")
        NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        let preview = XCUIApplication(bundleIdentifier: "com.apple.Preview")
        self.preview = preview
        preview.activate()
        let target = preview.windows.matching(NSPredicate(format: "title CONTAINS %@", "Capture Window Fixture"))
            .firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        previewFixtureWindow = target
        let targetFrame = target.frame
        let scale = try screen(containingQuartzPoint: CGPoint(x: targetFrame.midX, y: targetFrame.midY))
            .backingScaleFactor
        app.activate()
        chooseCapture("Window")
        let overlay = captureOverlay
        XCTAssertTrue(overlay.waitForExistence(timeout: 10), "Capture overlay missing.\n\(app.debugDescription)")
        overlay.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(
                dx: targetFrame.midX - overlay.frame.minX,
                dy: targetFrame.midY - overlay.frame.minY)
        ).click()
        try waitForCapture()
        let image = try copyImage()
        XCTAssertEqual(image.width, Int((targetFrame.width * scale).rounded()), accuracy: 2)
        XCTAssertEqual(image.height, Int((targetFrame.height * scale).rounded()), accuracy: 2)
        attachDimensions("Window capture of generated fixture", images: [image])
    }

    func testMenuCaptureIncludesVisiblePreviewMenuForVisualReview() throws {
        let previousDelay = try changeCaptureDelay(to: "15")
        defer {
            if captureOverlay.exists {
                app.activate()
                app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            }
            if captureCountdown.buttons["Cancel"].exists { captureCountdown.buttons["Cancel"].click() }
            do { _ = try changeCaptureDelay(to: previousDelay) } catch {
                XCTFail("Could not restore the original capture delay: \(error)")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Skitchish-Menu-\(UUID().uuidString)", isDirectory: true)
        fixtureDirectory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Capture Menu Fixture.png")
        try fixturePNG().write(to: url)
        let previewURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview"))
        let opened = expectation(description: "Open the generated menu capture fixture")
        NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        let preview = XCUIApplication(bundleIdentifier: "com.apple.Preview")
        self.preview = preview
        preview.activate()
        let fixture = preview.windows.matching(NSPredicate(format: "title CONTAINS %@", "Capture Menu Fixture"))
            .firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))
        previewFixtureWindow = fixture
        let fileMenu = preview.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists)
        let menuFrame = fileMenu.frame
        let screen = try screen(containingQuartzPoint: CGPoint(x: menuFrame.midX, y: menuFrame.midY))
        let primaryTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let screenRect = CGRect(
            x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
            width: screen.frame.width, height: screen.frame.height)
        let captureRect = CGRect(
            x: max(screenRect.minX + 2, menuFrame.minX - 8), y: screenRect.minY + 2,
            width: min(500, screenRect.maxX - menuFrame.minX - 10),
            height: min(700, screenRect.height - 4))
        app.activate()
        chooseCapture("Menu…")
        let overlay = captureOverlay
        XCTAssertTrue(overlay.waitForExistence(timeout: 10), "Capture overlay missing.\n\(app.debugDescription)")
        let origin = overlay.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(
            CGVector(dx: captureRect.minX - overlay.frame.minX, dy: captureRect.minY - overlay.frame.minY))
        start.press(
            forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: captureRect.width, dy: captureRect.height)))
        XCTAssertTrue(captureCountdown.waitForExistence(timeout: 3), "Menu capture needs a nonzero countdown.")
        preview.activate()
        fileMenu.click()
        XCTAssertTrue(
            preview.menuItems["Open…"].waitForExistence(timeout: 2),
            "Preview's File menu must be visibly open during the countdown.")
        XCTAssertTrue(captureCountdown.exists, "The File menu must open before the capture countdown ends.")
        try waitForCapture(timeout: 75)
        let captured = try copyImage()
        XCTAssertEqual(captured.width, Int((captureRect.width * screen.backingScaleFactor).rounded()))
        XCTAssertEqual(captured.height, Int((captureRect.height * screen.backingScaleFactor).rounded()))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Menu capture — inspect visible Preview File menu pixels"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Menu visibility and output dimensions are asserted; menu pixels require reviewing this PNG.
    }

    private func changeCaptureDelay(to value: String) throws -> String {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Skitchish Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let field = settings.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let previous = try XCTUnwrap(field.value as? String)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText(value)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        return previous
    }

    private func chooseCapture(_ title: String) {
        app.menuBars.menuBarItems["Capture"].click()
        app.menuItems[title].click()
    }

    // Borderless NSPanel instances can have AXUnknown subrole and are not classified as XCUI windows.
    private var captureOverlay: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "Select Capture Area").firstMatch
    }

    private var captureCountdown: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "Skitchish Capture").firstMatch
    }

    private func selectRegion(width: CGFloat, height: CGFloat) throws -> (width: Int, height: Int) {
        let overlay = captureOverlay
        guard overlay.waitForExistence(timeout: 10) else {
            try reportPermissionIfPresent()
            XCTFail("The capture selection overlay did not appear.\n\(app.debugDescription)")
            return (0, 0)
        }
        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let end = start.withOffset(CGVector(dx: width, dy: height))
        let scale = try screen(containingQuartzPoint: start.screenPoint).backingScaleFactor
        start.press(forDuration: 0.2, thenDragTo: end)
        return (Int((width * scale).rounded()), Int((height * scale).rounded()))
    }

    private func waitForCapture(timeout: TimeInterval = 20) throws {
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate { [self] _, _ in
                app.windows["Screen Snap — Skitchish"].exists && app.buttons["Copy Image"].isHittable
                    && !captureOverlay.exists && !captureCountdown.exists
            }, object: nil)
        let result = XCTWaiter.wait(for: [finished], timeout: timeout)
        if result != .completed { try reportPermissionIfPresent() }
        XCTAssertEqual(
            result, .completed,
            "Capture did not finish. Grant any screen-recording permission manually and rerun; tests never approve system dialogs."
        )
    }

    private func reportPermissionIfPresent() throws {
        let permission = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Allow Skitchish"))
            .firstMatch
        if permission.exists {
            throw XCTSkip(
                "Screen-recording permission requires manual approval for the attached signed app; no capture was verified."
            )
        }
    }

    private func screen(containingQuartzPoint point: CGPoint) throws -> NSScreen {
        let top = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        return try XCTUnwrap(
            NSScreen.screens.first { screen in
                CGRect(
                    x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width,
                    height: screen.frame.height
                ).contains(point)
            })
    }

    private func copyImage() throws -> CGImage {
        app.buttons["Copy Image"].click()
        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func fixturePNG() throws -> Data {
        let bitmap = try XCTUnwrap(
            CGContext(
                data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        bitmap.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
        bitmap.fill(CGRect(x: 12, y: 12, width: 24, height: 24))
        let image = try XCTUnwrap(bitmap.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func attachDimensions(_ name: String, images: [CGImage]) {
        let evidence = images.map { "\($0.width) × \($0.height) pixels" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: evidence)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
