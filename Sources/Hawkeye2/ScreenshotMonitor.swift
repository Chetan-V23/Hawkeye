import Foundation
import HawkeyeCore

@MainActor
final class ScreenshotMonitor {
    private struct Session {
        let token: UUID
        let work: Task<Void, Never>
    }

    private struct Sample {
        let token: UUID
        let revision: Int
        let policy: DistractionPolicy
        let deadline: Date
        var windowsByDisplay: [UInt32: [ScreenshotWindow]] = [:]
        var attemptedTerminations: [ForegroundApplication] = []
        var attemptedTabCloses: [VisibleBrowserTab] = []
    }

    private let capturer: any ScreenshotCapturing
    private let log: ActivityLog
    private let interval: Duration
    private let now: () -> Date
    private var activity: MonitoringSession?
    private var session: Session?
    private var finishing: Task<Void, Never>?
    private var lastFailure: ScreenshotFailure?
    private var displayFailures: [UInt32: ScreenshotFailure] = [:]
    private var stageFailures: [UInt32: [ScreenshotProcessingFailure]] = [:]
    private let pipeline: ScreenshotPipeline
    private let actions: (any ScreenshotActions)?
    private var policy: DistractionPolicy
    private var revision = 0
    private var processing: Task<Void, Never>?

    init(capturer: any ScreenshotCapturing, log: ActivityLog, interval: Duration = .seconds(60),
         now: @escaping () -> Date = Date.init, policy: DistractionPolicy = .standard,
         processors: [any ScreenshotProcessing] = ScreenshotPipeline.defaultProcessors,
         actions: (any ScreenshotActions)? = nil) {
        self.capturer = capturer
        self.log = log
        self.interval = interval
        self.now = now
        self.policy = policy
        self.pipeline = ScreenshotPipeline(processors: processors)
        self.actions = actions
    }

    deinit { session?.work.cancel(); finishing?.cancel(); processing?.cancel() }

    func update(policy: DistractionPolicy) {
        guard self.policy != policy else { return }
        self.policy = policy
        revision += 1
        processing?.cancel()
    }

    func update(session activity: MonitoringSession?) {
        let sameOccurrence = activity?.id == self.activity?.id && activity?.startedAt == self.activity?.startedAt
        if self.activity != activity { revision += 1; processing?.cancel() }
        self.activity = activity
        if activity?.isActive(at: now()) == true, sameOccurrence, session != nil { return }
        if let session {
            session.work.cancel()
            finishing = session.work
            self.session = nil
        }
        lastFailure = nil
        displayFailures = [:]
        stageFailures = [:]
        guard activity?.isActive(at: now()) == true else { return }
        let previous = finishing
        finishing = nil
        let token = UUID()
        let interval = interval
        let work = Task { [weak self] in
            defer { self?.finish(token) }
            await previous?.value
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard self?.isCurrent(token) == true else { return }
                guard let self else { return }
                let sample = Task { [weak self] in
                    guard let self else { return }
                    await self.sample(token)
                }
                await withTaskCancellationHandler { await sample.value } onCancel: { sample.cancel() }
            }
        }
        session = Session(token: token, work: work)
    }

    private func isCurrent(_ token: UUID) -> Bool {
        !Task.isCancelled && session?.token == token && activity?.isActive(at: now()) == true
    }

    private func finish(_ token: UUID) {
        if session?.token == token { session = nil }
    }

    private func eligible(_ token: UUID, revision: Int, before deadline: Date) -> Bool {
        isCurrent(token) && self.revision == revision && now() < deadline
    }

    private func sample(_ token: UUID) async {
        guard isCurrent(token), let activity else { return }
        let deadline = activity.operationDeadline(at: now())
        do {
            let outcomes = try await capturer.capture(before: deadline)
            guard isCurrent(token), now() < deadline else { return }
            lastFailure = nil
            let revision = revision
            let work = Task { [weak self] in
                guard let self else { return }
                await self.process(outcomes, token: token, revision: revision, deadline: deadline)
            }
            processing = work
            await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            processing = nil
        } catch is CancellationError {
        } catch {
            guard isCurrent(token) else { return }
            let failure = error as? ScreenshotFailure ?? .captureFailed
            if lastFailure != failure { log.record("Screenshot", failure.message); lastFailure = failure }
        }
    }

    private func process(_ outcomes: [DisplayCaptureOutcome], token: UUID, revision: Int, deadline: Date) async {
        guard eligible(token, revision: revision, before: deadline), let activity else { return }
        let end = min(deadline, activity.operationDeadline(at: now()))
        let pipeline = pipeline
        let policy = policy
        var sample = Sample(token: token, revision: revision, policy: policy, deadline: end)
        await withTaskGroup(of: (UInt32, ScreenshotProcessingResult?).self) { group in
            for outcome in outcomes {
                switch outcome {
                case .failed(let displayID, let failure): recordFailure(failure, displayID: displayID)
                case .captured(let screenshot):
                    guard activity.isActive(at: screenshot.capturedAt), screenshot.capturedAt < end else { continue }
                    sample.windowsByDisplay[screenshot.displayID] = screenshot.windows
                    do {
                        try log.recordScreenshot(screenshot.thumbnail, displayID: screenshot.displayID)
                        displayFailures[screenshot.displayID] = nil
                    } catch { recordFailure(.persistenceFailed, displayID: screenshot.displayID) }
                    group.addTask {
                        let context = ScreenshotProcessingContext(screenshot: screenshot, session: activity, policy: policy, deadline: end)
                        return (screenshot.displayID, try? await pipeline.process(context))
                    }
                }
            }
            for await (displayID, result) in group {
                guard eligible(token, revision: revision, before: deadline), let result else { continue }
                for failure in result.failures where stageFailures[displayID]?.contains(failure) != true {
                    log.record("Screenshot processing", "Display \(displayID): \(failure.stage) failed (\(failure.failure)).")
                }
                stageFailures[displayID] = result.failures
                do { try await enforce(result.analysis.actions, on: displayID, sample: &sample) }
                catch { return }
            }
        }
    }

    private func enforce(_ proposals: [ScreenshotAction], on displayID: UInt32, sample: inout Sample) async throws {
        let token = sample.token
        let revision = sample.revision
        let deadline = sample.deadline
        for proposal in proposals {
            guard eligible(token, revision: revision, before: deadline), let actions else { return }
            do {
                switch proposal {
                case .blockedApplication(let window):
                    guard window.displayID == displayID,
                          sample.windowsByDisplay[displayID]?.contains(window) == true,
                          !sample.attemptedTerminations.contains(window.application),
                          sample.policy.applications.contains(where: { $0.bundleID == window.application.bundleID }),
                          try await actions.revalidate(window, before: sample.deadline),
                          eligible(token, revision: revision, before: deadline) else { continue }
                    sample.attemptedTerminations.append(window.application)
                    if actions.terminate(window) {
                        log.record("Focus block", "Display \(displayID): force-quit request sent for \(window.application.bundleID).")
                    }
                case .closeBrowserTab(let target):
                    guard target.window.displayID == displayID,
                          sample.windowsByDisplay[displayID]?.contains(target.window) == true,
                          target.browser.bundleID == target.window.application.bundleID,
                          !sample.attemptedTabCloses.contains(where: { $0.window.application == target.window.application && $0.browser == target.browser && $0.tab == target.tab }),
                          try await actions.revalidate(target.window, before: sample.deadline),
                          eligible(token, revision: revision, before: deadline) else { continue }
                    sample.attemptedTabCloses.append(target)
                    let sent = try await actions.close(target, before: sample.deadline,
                        authorizing: { self.eligible(token, revision: revision, before: deadline) })
                    guard eligible(token, revision: revision, before: deadline) else { continue }
                    if sent { log.record("Focus block", "Display \(displayID): exact tab close command sent in \(target.browser.name).") }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard eligible(token, revision: revision, before: deadline) else { continue }
                log.record("Screenshot processing", "Display \(displayID): action failed (\(DetectionFailure(error))).")
            }
        }
    }

    private func recordFailure(_ failure: ScreenshotFailure, displayID: UInt32) {
        if displayFailures[displayID] != failure {
            log.record("Screenshot", "Display \(displayID): \(failure.message)")
            displayFailures[displayID] = failure
        }
    }
}
