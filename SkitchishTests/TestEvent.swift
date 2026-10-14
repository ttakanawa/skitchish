import AppKit
import Testing

/// Event locations are in window coordinates; each test controls its canvas mapping.
@MainActor
enum TestEvent {
    static func mouse(
        _ type: NSEvent.EventType, atWindowPoint location: CGPoint,
        modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
}
