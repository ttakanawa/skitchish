import AppKit
import Testing

@testable import Skitchish

@MainActor
struct UnsavedChangesTests {
    private let preferences = TestPreferences()

    @Test func discardRemovesOnlyCurrentDraftAndDoesNotRestoreItOnTermination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(baseURL: directory.appendingPathComponent("Drafts"))
        let controller = try EditorWindowController(
            restoringDraft: false, store: store, preferences: preferences.defaults)
        let older = try EditorWindowController.blankDocument(width: 20, height: 20)
        try store.saveDraft(older)
        controller.session.change("Rename") { $0.title = "Discard this work" }
        let current = controller.session.document
        #expect(controller.flushDraft())
        #expect(try store.latestDraft() == current)
        let savedFile = directory.appendingPathComponent("Saved.skitchish")
        try store.save(document: current, to: savedFile)
        #expect(controller.prepareToLeaveDocument(choose: { .discard }))
        #expect(try store.latestDraft() == nil)
        #expect(try store.drafts().count == 1)
        #expect(try store.load(from: store.drafts()[0].url) == older)
        #expect(try store.load(from: savedFile) == current)
        // AppKit may ask to terminate after closing the last window. Neither that
        // callback nor a late autosave flush may recreate discarded work.
        #expect(controller.prepareToTerminate())
        #expect(controller.flushDraft())
        #expect(try store.latestDraft() == nil)
        #expect(try store.drafts().count == 1)
    }

    @Test func discardingNonLatestDraftPreservesLatestAndCanBeRepeated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(baseURL: directory)
        let first = try EditorWindowController.blankDocument(width: 20, height: 20)
        let second = try EditorWindowController.blankDocument(width: 30, height: 30)
        try store.saveDraft(first)
        try store.saveDraft(second)
        try store.discardDraft(id: first.id)
        try store.discardDraft(id: first.id)
        #expect(try store.latestDraft() == second)
        #expect(try store.drafts().count == 1)
    }

    @Test func discardFailurePreservesWorkingPackage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(baseURL: directory)
        let document = try EditorWindowController.blankDocument(width: 20, height: 20)
        try store.saveDraft(document)
        // An unreadable recovery pointer must fail before deleting the package.
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("latest.json"))
        #expect(throws: (any Error).self) { try store.discardDraft(id: document.id) }
        #expect(try store.load(from: store.drafts()[0].url) == document)
    }

    @Test func saveCheckpointTracksUndoRedoAndImportedImages() throws {
        let document = try EditorWindowController.blankDocument(width: 40, height: 30)
        let session = preferences.session(document: document)
        #expect(!session.hasUnsavedChanges)
        session.change("Rename") { $0.title = "Changed" }
        #expect(session.hasUnsavedChanges)
        session.history.undo()
        #expect(!session.hasUnsavedChanges)
        session.history.redo()
        #expect(session.hasUnsavedChanges)
        session.markSaved()
        #expect(!session.hasUnsavedChanges)
        session.history.undo()
        #expect(session.hasUnsavedChanges)
        session.history.redo()
        #expect(!session.hasUnsavedChanges)
        session.replace(with: document)
        #expect(session.hasUnsavedChanges)
        session.replace(with: document, isSaved: true)
        #expect(!session.hasUnsavedChanges)
    }

    @Test func cancelAndCancelledSaveKeepTheCurrentDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(baseURL: directory)
        let controller = try EditorWindowController(
            restoringDraft: false, store: store, preferences: preferences.defaults)
        controller.session.change("Rename") { $0.title = "Keep this work" }
        let edited = controller.session.document
        #expect(!controller.prepareToLeaveDocument(choose: { .cancel }))
        #expect(controller.session.document == edited)
        #expect(!controller.prepareToLeaveDocument(choose: { .save }, save: { false }))
        #expect(controller.session.document == edited)
        #expect(controller.session.hasUnsavedChanges)
        #expect(try store.latestDraft() == nil)
        #expect(controller.prepareToLeaveDocument(choose: { .keepDraft }))
        #expect(controller.session.document == edited)
        #expect(controller.session.hasUnsavedChanges)
        #expect(try store.latestDraft() == edited)
    }

    @Test func savedDocumentsLeaveWithoutPromptAndFailedSaveStaysDirty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(baseURL: directory.appendingPathComponent("Drafts"))
        let controller = try EditorWindowController(
            restoringDraft: false, store: store, preferences: preferences.defaults)
        var prompts = 0
        #expect(try store.latestDraft() == nil)
        #expect(
            controller.prepareToLeaveDocument(choose: {
                prompts += 1
                return .cancel
            }))
        #expect(prompts == 0)
        #expect(try store.latestDraft() == controller.session.document)
        controller.session.change("Rename") { $0.title = "Saved document" }
        let url = directory.appendingPathComponent("Saved.skitchish")
        #expect(
            controller.prepareToLeaveDocument(
                choose: { .save },
                save: {
                    do {
                        try controller.saveEditableDocument(to: url)
                        return true
                    } catch {
                        Issue.record(error)
                        return false
                    }
                }))
        #expect(!controller.session.hasUnsavedChanges)
        #expect(try controller.store.load(from: url) == controller.session.document)
        #expect(try store.latestDraft() == controller.session.document)
        #expect(
            controller.prepareToLeaveDocument(choose: {
                prompts += 1
                return .cancel
            }))
        #expect(prompts == 0)
        controller.session.change("Invalid canvas") { $0.canvas.size.width = 0 }
        #expect(throws: (any Error).self) { try controller.saveEditableDocument(to: url) }
        #expect(controller.session.hasUnsavedChanges)
        #expect(try controller.store.load(from: url).canvas.width > 0)
    }
}
