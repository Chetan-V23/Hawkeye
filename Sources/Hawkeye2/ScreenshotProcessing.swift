import Foundation
import HawkeyeCore

struct VisibleBrowserTab: Equatable, Sendable {
    let window: ScreenshotWindow
    let browser: ScriptableBrowser
    let tab: BrowserTab
}

enum ScreenshotAction: Equatable, Sendable {
    case blockedApplication(ScreenshotWindow)
    case closeBrowserTab(VisibleBrowserTab)
}

enum ScreenshotObservation: Equatable, Sendable {
    case possibleDistraction(ScreenshotWindow)
}

struct ScreenshotAnalysis: Sendable {
    var observations: [ScreenshotObservation] = []
    var actions: [ScreenshotAction] = []
}

struct ScreenshotProcessingContext: Sendable {
    let screenshot: DisplayScreenshot
    let session: MonitoringSession
    let policy: DistractionPolicy
    let deadline: Date
}

protocol ScreenshotProcessing: Sendable {
    var name: String { get }
    func process(_ context: ScreenshotProcessingContext, analysis: ScreenshotAnalysis) async throws -> ScreenshotAnalysis
}

struct ScreenshotProcessingFailure: Equatable, Sendable {
    let stage: String
    let failure: DetectionFailure
}

struct ScreenshotProcessingResult: Sendable {
    let analysis: ScreenshotAnalysis
    let failures: [ScreenshotProcessingFailure]
}

struct ScreenshotPipeline: Sendable {
    static let defaultProcessors: [any ScreenshotProcessing] = [BlacklistedApplicationProcessor()]

    let processors: [any ScreenshotProcessing]

    func process(_ context: ScreenshotProcessingContext) async throws -> ScreenshotProcessingResult {
        var analysis = ScreenshotAnalysis()
        var failures: [ScreenshotProcessingFailure] = []
        for processor in processors {
            try checkEligibility(context.deadline)
            do {
                let next = try await processor.process(context, analysis: analysis)
                try checkEligibility(context.deadline)
                analysis = next
            } catch is CancellationError { throw CancellationError() }
            catch let failure as ScreenshotFailure where failure == .deadlinePassed { throw failure }
            catch {
                try checkEligibility(context.deadline)
                failures.append(.init(stage: processor.name, failure: DetectionFailure(error)))
            }
        }
        try checkEligibility(context.deadline)
        return ScreenshotProcessingResult(analysis: analysis, failures: failures)
    }

    private func checkEligibility(_ deadline: Date) throws {
        try Task.checkCancellation()
        guard Date() < deadline else { throw ScreenshotFailure.deadlinePassed }
    }
}

struct BlacklistedApplicationProcessor: ScreenshotProcessing {
    let name = "Application blacklist"

    func process(_ context: ScreenshotProcessingContext, analysis: ScreenshotAnalysis) async throws -> ScreenshotAnalysis {
        var result = analysis
        for window in context.screenshot.windows where context.policy.applications.contains(where: {
            $0.bundleID == window.application.bundleID
        }) {
            result.actions.append(.blockedApplication(window))
        }
        return result
    }
}

@MainActor
protocol ScreenshotObservationProviding: AnyObject, Sendable {
    func visibleTab(in window: ScreenshotWindow, browser: ScriptableBrowser, before deadline: Date) async throws -> VisibleBrowserTab?
}

@MainActor
protocol ScreenshotActions: AnyObject {
    func revalidate(_ window: ScreenshotWindow, before deadline: Date) async throws -> Bool
    func terminate(_ window: ScreenshotWindow) -> Bool
    func close(_ target: VisibleBrowserTab, before deadline: Date,
               authorizing: @MainActor () -> Bool) async throws -> Bool
}
