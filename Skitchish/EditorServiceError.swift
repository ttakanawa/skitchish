import Foundation

enum EditorServiceError: LocalizedError {
    case invalidImage, invalidDocument
    case unsupportedVersion(Int)
    case encodingFailed, noPreviousRegion
    case capturePermission, captureUnavailable, shortcutUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "This file does not contain a supported image."
        case .invalidDocument: return "This Skitchish document is damaged or contains invalid dimensions."
        case .unsupportedVersion(let version):
            return "This document uses format version \(version). Update Skitchish to open it."
        case .encodingFailed: return "The image could not be encoded."
        case .noPreviousRegion: return "Capture a region first, then use Previous Region."
        case .capturePermission:
            return
                "Allow Skitchish in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. macOS may ask you to reopen the app."
        case .captureUnavailable: return "The selected screen or window is no longer available. Try capturing again."
        case .shortcutUnavailable: return "That shortcut is already in use. Choose another shortcut."
        }
    }
}
