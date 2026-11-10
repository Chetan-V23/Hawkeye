import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ScreenshotWindowDescriptor: Sendable {
    let windowID: UInt32
    let application: ForegroundApplication
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int
}

enum ScreenshotWindowAssociation {
    static func windows(on displayID: UInt32, frame: CGRect, from descriptors: [ScreenshotWindowDescriptor]) -> [ScreenshotWindow] {
        descriptors.compactMap { window in
            guard window.isOnScreen, window.layer >= 0, !window.frame.isEmpty,
                  window.frame.intersects(frame) else { return nil }
            return ScreenshotWindow(displayID: displayID, windowID: window.windowID,
                                    application: window.application, frame: window.frame)
        }.sorted { $0.windowID < $1.windowID }
    }

    static func descriptors(_ content: SCShareableContent) -> [ScreenshotWindowDescriptor] {
        content.windows.compactMap { window in
            guard let application = window.owningApplication, !application.bundleIdentifier.isEmpty else { return nil }
            return ScreenshotWindowDescriptor(windowID: window.windowID,
                application: .init(bundleID: application.bundleIdentifier, processID: application.processID),
                frame: window.frame, isOnScreen: window.isOnScreen, layer: window.windowLayer)
        }
    }
}

struct MacScreenshotCapture: ScreenshotCapturing {
    private let effectsEnabled: Bool

    init(effectsEnabled: Bool) {
        self.effectsEnabled = effectsEnabled && Bundle.main.bundleURL.pathExtension == "app"
    }

    func capture(before deadline: Date) async throws -> [DisplayCaptureOutcome] {
        guard effectsEnabled else { throw ScreenshotFailure.disabled }
        try checkEligibility(before: deadline)
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { try checkEligibility(before: deadline); throw ScreenshotFailure.captureFailed }
        try checkEligibility(before: deadline)
        guard !content.displays.isEmpty else { throw ScreenshotFailure.displayUnavailable }
        let descriptors = ScreenshotWindowAssociation.descriptors(content)
        var outcomes: [DisplayCaptureOutcome] = []
        for display in content.displays.sorted(by: { $0.displayID < $1.displayID }) {
            try Task.checkCancellation()
            do {
                try checkEligibility(before: deadline)
                guard display.width > 0, display.height > 0 else { throw ScreenshotFailure.displayUnavailable }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
                configuration.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.scalesToFit = true
                configuration.preservesAspectRatio = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let capturedAt = Date()
                try checkEligibility(before: deadline)
                let encoding = Task.detached(priority: .utility) { try Self.thumbnail(image) }
                let jpeg = try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
                try checkEligibility(before: deadline)
                outcomes.append(.captured(DisplayScreenshot(displayID: display.displayID, displayFrame: display.frame, image: image,
                    thumbnail: ScreenshotThumbnail(jpegData: jpeg, capturedAt: capturedAt),
                    windows: ScreenshotWindowAssociation.windows(on: display.displayID, frame: display.frame, from: descriptors))))
            } catch is CancellationError { throw CancellationError() }
            catch { outcomes.append(.failed(displayID: display.displayID, error as? ScreenshotFailure ?? .captureFailed)) }
        }
        return outcomes
    }

    private static func thumbnail(_ image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let scale = min(1, 480.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScreenshotFailure.encodingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { throw ScreenshotFailure.encodingFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScreenshotFailure.encodingFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotFailure.encodingFailed }
        try Task.checkCancellation()
        return data as Data
    }

    private func checkEligibility(before deadline: Date) throws {
        try Task.checkCancellation()
        guard Date() < deadline else { throw ScreenshotFailure.deadlinePassed }
        guard CGPreflightScreenCaptureAccess() else { throw ScreenshotFailure.permissionDenied }
    }
}
