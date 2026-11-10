import CoreGraphics
import Foundation

struct ScreenshotWindow: Equatable, Sendable {
    let displayID: UInt32
    let windowID: UInt32
    let application: ForegroundApplication
    let frame: CGRect
}

struct ScreenshotThumbnail: Sendable {
    let jpegData: Data
    let capturedAt: Date
}

struct DisplayScreenshot: Sendable {
    let displayID: UInt32
    let displayFrame: CGRect
    let image: CGImage
    let thumbnail: ScreenshotThumbnail
    let windows: [ScreenshotWindow]
    var capturedAt: Date { thumbnail.capturedAt }
}

enum DisplayCaptureOutcome: Sendable {
    case captured(DisplayScreenshot)
    case failed(displayID: UInt32, ScreenshotFailure)
}

protocol ScreenshotCapturing: Sendable {
    func capture(before deadline: Date) async throws -> [DisplayCaptureOutcome]
}

enum ScreenshotFailure: Error, Equatable {
    case disabled, permissionDenied, displayUnavailable, captureFailed, encodingFailed, deadlinePassed, persistenceFailed

    var message: String {
        switch self {
        case .disabled: return "Screenshots are disabled in this session."
        case .permissionDenied: return "Screenshot unavailable. Allow Screen Recording access in Focus permissions."
        case .displayUnavailable: return "Screenshot unavailable. The display could not be found."
        case .captureFailed: return "Could not capture a task screenshot."
        case .encodingFailed: return "Could not create the screenshot thumbnail."
        case .deadlinePassed: return "Screenshot skipped because its capture deadline passed."
        case .persistenceFailed: return "Could not save the screenshot thumbnail to the activity log."
        }
    }
}
