import AppKit
import ImageIO
import XCTest

/// Opt-in desktop acceptance: TEST_RUNNER_SKITCHISH_CROSS_APP_TESTS=1 xcodebuild test …
/// Uses only generated local files and never submits a message or uploads an image.
@MainActor
final class SkitchishCrossAppTests: XCTestCase {
    private var app: XCUIApplication!
    private var acceptance: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SKITCHISH_CROSS_APP_TESTS"] == "1"
                || environment["TEST_RUNNER_SKITCHISH_CROSS_APP_TESTS"] == "1",
            "Set TEST_RUNNER_SKITCHISH_CROSS_APP_TESTS=1 for desktop drag acceptance.")
        continueAfterFailure = false
        acceptance = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Skitchish-CrossApp-Acceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: acceptance, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["export.drag"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try super.tearDownWithError()
    }

    func testDragMeCreatesOneImageInFinder() throws {
        let folder = acceptance.appendingPathComponent("FinderDrag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        let destination = finder.windows[folder.lastPathComponent]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        // Keep a visible area of this specific test folder to the left of the editor.
        let title = destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        title.press(
            forDuration: 0.2,
            thenDragTo: title.withOffset(CGVector(dx: 20 - destination.frame.minX, dy: 100 - destination.frame.minY)))
        app.activate()
        let drop = destination.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.55))
        XCTAssertFalse(
            app.windows.firstMatch.frame.contains(drop.screenPoint), "Test folder must remain visible beside the editor"
        )
        app.buttons["export.drag"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.5, thenDragTo: drop)
        let written = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .contains { $0.pathExtension == "png" }
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 10), .completed)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter {
            $0.pathExtension == "png"
        }
        XCTAssertEqual(files.count, 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(files[0] as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1000)
        XCTAssertEqual(image.height, 700)
        finder.activate()
        attach(destination.screenshot(), name: "Finder received one PNG")
    }

    func testDragMeCreatesOneBrowserFileWithoutUploading() throws {
        let html = acceptance.appendingPathComponent("BrowserDrop.html")
        try """
        <!doctype html><meta charset="utf-8"><title>Skitchish offline drop acceptance</title>
        <style>body{margin:32px;font:20px system-ui}#drop{height:80vh;border:3px dashed gray;padding:24px}img{max-width:60%;max-height:60vh}</style>
        <h1>Skitchish offline drop acceptance</h1><div id="drop"><p id="result">WAITING</p><img id="preview"></div>
        <script>
        const area=document.querySelector('#drop');
        area.addEventListener('dragover',e=>{e.preventDefault();e.dataTransfer.dropEffect='copy'});
        area.addEventListener('drop',async e=>{e.preventDefault();try{
          const files=[...e.dataTransfer.files];const f=files[0];const b=await createImageBitmap(f);
          document.querySelector('#result').textContent=`PASS count=${files.length} type=${f.type} width=${b.width} height=${b.height}`;
          document.querySelector('#preview').src=URL.createObjectURL(f);b.close();
        }catch(error){document.querySelector('#result').textContent='FAIL '+error.message}});
        </script>
        """.write(to: html, atomically: true, encoding: .utf8)
        let browserURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"))
        let opened = expectation(description: "Open the local drop receiver")
        NSWorkspace.shared.open([html], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        let browser = XCUIApplication(bundleIdentifier: "com.google.Chrome")
        browser.activate()
        let destination = browser.windows.matching(
            NSPredicate(format: "title CONTAINS %@", "Skitchish offline drop acceptance")
        ).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertTrue(browser.staticTexts["WAITING"].waitForExistence(timeout: 10))
        app.activate()
        let drop = destination.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
        XCTAssertFalse(
            app.windows.firstMatch.frame.contains(drop.screenPoint),
            "Browser drop area must be visible beside the editor")
        app.buttons["export.drag"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.5, thenDragTo: drop)
        browser.activate()
        let result = browser.staticTexts["PASS count=1 type=image/png width=1000 height=700"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), browser.debugDescription)
        attach(destination.screenshot(), name: "Browser received one decoded PNG")
        // Close only the generated acceptance tab.
        browser.typeKey("w", modifierFlags: .command)
    }

    func testDragMeAttachesToCurrentOrcaChatWithoutSending() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SKITCHISH_ORCA_CHAT_TEST"] == "1" || environment["TEST_RUNNER_SKITCHISH_ORCA_CHAT_TEST"] == "1",
            "Requires the user's explicit authorization and the current task tab already selected.")
        let title = "Skitchish-drag-check-\(UUID().uuidString)"
        let name = app.textFields["document.title"]
        name.click()
        app.typeKey("a", modifierFlags: .command)
        name.typeText(title)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let orca = XCUIApplication(bundleIdentifier: "com.stablyai.orca")
        orca.activate()
        // A previous CLI route is not a lock: the user can switch workspaces before
        // this test starts. The request content below identifies the conversation
        // independently of its mutable tab title and platform accessibility role.
        let showChat = orca.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Show chat view"))
            .firstMatch
        if showChat.exists { showChat.click() }
        // Older messages are virtualized away. Use the most recent explicit
        // destination answer, including its unique question ID, as the marker.
        let conversation = orca.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                "call_0d4f7c0f87e14cc5bef0ec61510a76a0", "この Orca のチャット", "Skitchish")
        ).firstMatch
        XCTAssertTrue(
            conversation.waitForExistence(timeout: 5),
            "The active conversation does not contain the authorized Skitchish request. No drop attempted.")
        let compositor = orca.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "(elementType == %d OR elementType == %d) AND (placeholderValue CONTAINS[c] 'message' OR placeholderValue CONTAINS[c] 'ask' OR placeholderValue CONTAINS[c] 'follow' OR placeholderValue CONTAINS[c] 'prompt' OR label CONTAINS[c] 'message input' OR label CONTAINS[c] 'chat input' OR label == 'Ask anything, @ to mention files, / for commands')",
                XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.textField.rawValue)
        ).firstMatch
        XCTAssertTrue(
            compositor.waitForExistence(timeout: 10),
            "Could not uniquely locate the chat composer. No drop attempted.\n\(orca.debugDescription)")
        let originalDraft = try XCTUnwrap(
            compositor.value as? String, "Composer text must be readable before changing attachments")
        let removalPredicate = NSPredicate(
            format:
                "label CONTAINS[c] 'remove' AND (label CONTAINS[c] 'attachment' OR label CONTAINS[c] 'image' OR label CONTAINS[c] 'file')"
        )
        let removalsBefore = orca.buttons.matching(removalPredicate).count
        let receiver = compositor.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        app.activate()
        XCTAssertFalse(
            app.windows.firstMatch.frame.contains(receiver.screenPoint),
            "Orca composer must be visible beside or below the editor; no drop attempted")
        XCTAssertTrue(conversation.exists, "The task changed before the drop. No drop attempted.")
        app.buttons["export.drag"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.5, thenDragTo: receiver)
        orca.activate()
        let attachment = orca.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
        XCTAssertTrue(
            attachment.waitForExistence(timeout: 10),
            "The unique image attachment was not identifiable; no message was sent.\n\(orca.debugDescription)")
        XCTAssertEqual(compositor.value as? String, originalDraft, "The existing user draft must remain unchanged")
        let identity = XCTAttachment(string: conversation.label)
        identity.name = "Verified current Skitchish conversation marker"
        identity.lifetime = .keepAlways
        add(identity)
        attach(orca.windows.firstMatch.screenshot(), name: "Orca received unsent unique PNG attachment")
        let namedRemoval = orca.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'remove' AND label CONTAINS %@", title)
        ).firstMatch
        if namedRemoval.exists {
            namedRemoval.click()
        } else if removalsBefore == 0 && orca.buttons.matching(removalPredicate).count == 1 {
            orca.buttons.matching(removalPredicate).firstMatch.click()
        } else {
            XCTFail(
                "Attachment verified and left unsent because its removal control was not uniquely identifiable: \(title).png"
            )
            return
        }
        XCTAssertTrue(attachment.waitForNonExistence(timeout: 5))
        XCTAssertEqual(compositor.value as? String, originalDraft)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
