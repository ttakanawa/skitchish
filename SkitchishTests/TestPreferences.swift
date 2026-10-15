import Foundation

@testable import Skitchish

/// Each test owns its preference domain, including its cleanup.
final class TestPreferences {
    private let suiteName = "com.skitchish.unit-tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor func session(document: EditorDocument) -> EditorSession {
        EditorSession(document: document, preferences: defaults)
    }
}
