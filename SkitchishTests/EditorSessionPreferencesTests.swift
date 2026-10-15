import AppKit
import Testing

@testable import Skitchish

@MainActor
struct EditorSessionPreferencesTests {
    @Test func toolAndSizePersistOnlyInTheSuppliedPreferences() {
        let firstPreferences = TestPreferences()
        let otherPreferences = TestPreferences()
        let document = EditorDocument(imageData: Data(), imageSize: CGSize(width: 1, height: 1))
        let first = firstPreferences.session(document: document)
        first.tool = .stamp
        first.sizeIndex = 4

        let reopened = firstPreferences.session(document: document)
        #expect(reopened.tool == .stamp && reopened.sizeIndex == 4)
        #expect(reopened.strokeWidth == 20)

        let other = otherPreferences.session(document: document)
        #expect(other.tool == .arrow && other.sizeIndex == 2)
        other.tool = .ellipse
        other.sizeIndex = 0

        let firstAgain = firstPreferences.session(document: document)
        let otherAgain = otherPreferences.session(document: document)
        #expect(firstAgain.tool == .stamp && firstAgain.sizeIndex == 4)
        #expect(otherAgain.tool == .ellipse && otherAgain.sizeIndex == 0)
        #expect(first.document == document && !first.history.canUndo && !first.hasUnsavedChanges)
    }
}
