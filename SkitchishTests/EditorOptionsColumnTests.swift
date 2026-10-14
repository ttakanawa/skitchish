import AppKit
import Testing

@testable import Skitchish

@MainActor
struct EditorOptionsColumnTests {
    @Test func leavingOptionsClosesOnceAfterTheGracePeriod() async throws {
        let column = EditorOptionsColumn()
        var closeCount = 0
        column.onClose = { [weak column] in
            closeCount += 1
            column?.setPresented(false)
        }
        defer { column.cancelPendingClose() }
        column.setPresented(true)
        column.pointerExited()
        #expect(closeCount == 0 && column.isPresented)
        try await Task.sleep(for: .milliseconds(650))
        #expect(closeCount == 1 && !column.isPresented)
        column.pointerExited()
        column.closeAfterChoice()
        try await Task.sleep(for: .milliseconds(500))
        #expect(closeCount == 1, "Hidden options cannot issue another close")
    }

    @Test func returningToOptionsCancelsExitButChoosingStillCloses() async throws {
        let column = EditorOptionsColumn()
        var closeCount = 0
        column.onClose = { [weak column] in
            closeCount += 1
            column?.setPresented(false)
        }
        defer { column.cancelPendingClose() }
        column.setPresented(true)
        column.pointerExited()
        column.pointerEntered()
        try await Task.sleep(for: .milliseconds(650))
        #expect(closeCount == 0 && column.isPresented, "Crossing back into the panel cancels dismissal")
        column.closeAfterChoice()
        column.pointerEntered()
        #expect(column.isPresented, "Keep the chosen option briefly visible before returning")
        try await Task.sleep(for: .milliseconds(350))
        #expect(closeCount == 1 && !column.isPresented)
    }

    @Test func pinningCancelsPendingExitAndChoiceDismissal() async throws {
        let column = EditorOptionsColumn()
        var closeCount = 0
        column.onClose = { [weak column] in
            closeCount += 1
            column?.setPresented(false)
        }
        defer { column.cancelPendingClose() }
        column.setPresented(true)
        column.pointerExited()
        column.isPinned = true
        column.closeAfterChoice()
        try await Task.sleep(for: .milliseconds(650))
        #expect(closeCount == 0 && column.isPresented)
        column.isPinned = false
        column.closeAfterChoice()
        column.isPinned = true
        try await Task.sleep(for: .milliseconds(350))
        #expect(closeCount == 0 && column.isPresented, "Pinning also cancels an already queued choice close")
        column.isPinned = false
        column.pointerExited()
        try await Task.sleep(for: .milliseconds(650))
        #expect(closeCount == 1 && !column.isPresented)
    }

    @Test func reopeningOptionsDiscardsThePreviousCloseTimer() async throws {
        let column = EditorOptionsColumn()
        var closeCount = 0
        column.onClose = { closeCount += 1 }
        defer { column.cancelPendingClose() }
        column.setPresented(true)
        column.pointerExited()
        column.setPresented(false)
        column.setPresented(true)
        try await Task.sleep(for: .milliseconds(650))
        #expect(closeCount == 0 && column.isPresented)
    }

    @Test func optionsTrackTheSidebarAndAdjacentGraceAreaOnlyWhilePresented() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let sidebar = NSView(frame: CGRect(x: 10, y: 30, width: 56, height: 440))
        host.addSubview(sidebar)
        let column = EditorOptionsColumn()
        sidebar.addSubview(column)
        column.configureTracking(in: host, sidebar: sidebar)
        #expect(host.trackingAreas.isEmpty)
        column.setPresented(true)
        #expect(host.trackingAreas.count == 1)
        let area = host.trackingAreas.first
        #expect(area?.rect == CGRect(x: 10, y: 30, width: 96, height: 440))
        #expect(area?.rect.contains(CGPoint(x: 105, y: 250)) == true)
        #expect(area?.rect.contains(CGPoint(x: 107, y: 250)) == false)
        column.updateTrackingAreas()
        #expect(host.trackingAreas.count == 1, "Resizing must replace, not duplicate, the tracking area")
        column.setPresented(false)
        #expect(host.trackingAreas.isEmpty)
    }

    @Test func panelBackgroundClickClosesAndEscapeWorksWhilePinned() throws {
        let column = EditorOptionsColumn()
        var closeCount = 0
        var escapeCount = 0
        column.onClose = { closeCount += 1 }
        column.onEscape = { escapeCount += 1 }
        column.setPresented(true)
        let click = try TestEvent.mouse(.leftMouseDown, atWindowPoint: .zero)
        column.mouseDown(with: click)
        #expect(closeCount == 1)
        column.isPinned = true
        column.mouseDown(with: click)
        #expect(closeCount == 1, "A pinned panel stays available for repeated choices")
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53))
        column.keyDown(with: escape)
        #expect(escapeCount == 1)
    }

    @Test func customColorPersistsAcrossPaletteChoicesAndRelaunch() throws {
        let suite = "com.skitchish.custom-color-tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let document = EditorDocument(imageData: Data(), imageSize: CGSize(width: 1, height: 1))
        let custom = RGBA(r: 0.18, g: 0.46, b: 0.71, a: 0.85)
        let session = EditorSession(document: document, preferences: preferences)
        session.setCustomColor(custom)
        #expect(session.colorIndex == -1 && session.color == custom)
        let reopened = EditorSession(document: document, preferences: preferences)
        #expect(reopened.colorIndex == -1 && reopened.color == custom)
        reopened.colorIndex = 3
        #expect(reopened.color == RGBA.palette[3] && reopened.customColor == custom)
        let afterPaletteChoice = EditorSession(document: document, preferences: preferences)
        #expect(afterPaletteChoice.colorIndex == 3 && afterPaletteChoice.color == RGBA.palette[3])
        #expect(afterPaletteChoice.customColor == custom)
        afterPaletteChoice.colorIndex = -1
        #expect(afterPaletteChoice.color == custom)
        #expect(
            session.document == document && !session.history.canUndo,
            "Color selection is session state, not a document edit")
    }

    @Test func invalidCustomColorsCannotReplaceTheLastUsableColor() throws {
        let suite = "com.skitchish.invalid-custom-color-tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let document = EditorDocument(imageData: Data(), imageSize: CGSize(width: 1, height: 1))
        let session = EditorSession(document: document, preferences: preferences)
        let valid = RGBA(r: 0.1, g: 0.2, b: 0.3)
        session.setCustomColor(valid)
        for invalid in [
            RGBA(r: .nan, g: 0, b: 0), RGBA(r: 0, g: .infinity, b: 0),
            RGBA(r: -0.1, g: 0, b: 0), RGBA(r: 0, g: 0, b: 1.1), RGBA(r: 0, g: 0, b: 0, a: -1),
        ] {
            session.setCustomColor(invalid)
            #expect(session.color == valid && session.customColor == valid)
        }
        #expect(EditorSession(document: document, preferences: preferences).color == valid)
        preferences.set(Data("invalid JSON".utf8), forKey: "editor.customColor")
        #expect(EditorSession(document: document, preferences: preferences).color == RGBA.palette[0])
    }
}
