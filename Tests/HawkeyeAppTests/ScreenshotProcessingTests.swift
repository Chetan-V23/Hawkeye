import CoreGraphics
import HawkeyeCore
import ImageIO
import XCTest
@testable import Hawkeye2

@MainActor
final class ScreenshotProcessingTests: XCTestCase {
    func testThreeDisplaysHaveIndependentOrderedStateAndOneStageFailureDoesNotErasePriorActions() async throws {
        let fixture = try fixture()
        let recorder = StageRecorder()
        let stages = [stage("first", recorder: recorder), stage("second", recorder: recorder, failingDisplay: 2), stage("third", recorder: recorder)]
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(100),
            policy: policy, processors: [BlacklistedApplicationProcessor()] + stages, actions: fixture.actions)
        monitor.update(session: .task(task()))
        await eventually { fixture.actions.terminated.count == 3 }
        monitor.update(session: nil)
        let visits = await recorder.visits
        for id: UInt32 in [1, 2, 3] { XCTAssertEqual(visits[id], ["first:0", "second:1", "third:\(id == 2 ? 1 : 2)"]) }
        XCTAssertEqual(fixture.log.entries.compactMap(\.screenshot).map(\.displayID).compactMap { $0 }.sorted(), [1, 2, 3])
        XCTAssertEqual(fixture.log.entries.filter { $0.category == "Screenshot processing" }.count, 1)
    }

    func testCaptureFailureDoesNotSkipSecondaryBlockedApplicationAndFailureDeduplicates() async throws {
        let fixture = try fixture()
        let good = try screenshot(id: 2)
        await fixture.source.set([.failed(displayID: 1, .captureFailed), .captured(good)])
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(20),
            policy: policy, actions: fixture.actions)
        monitor.update(session: .task(task()))
        await eventually { fixture.actions.terminated.count >= 3 }
        monitor.update(session: nil)
        XCTAssertTrue(fixture.actions.terminated.allSatisfy { $0.displayID == 2 })
        XCTAssertEqual(fixture.log.entries.filter { $0.message == "Display 1: \(ScreenshotFailure.captureFailed.message)" }.count, 1)
    }

    func testOneSlowDisplayDoesNotPreventOtherDisplaysEnforcement() async throws {
        let fixture = try fixture()
        let gate = ProcessingGate()
        let slow = TestScreenshotStage(name: "Slow") { context, analysis in
            if context.screenshot.displayID == 1 { await gate.wait() }
            return analysis
        }
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(20),
            policy: policy, processors: [BlacklistedApplicationProcessor(), slow], actions: fixture.actions)
        monitor.update(session: .task(task()))
        await eventually { fixture.actions.terminated.count == 2 }
        XCTAssertEqual(Set(fixture.actions.terminated.map(\.displayID)), [2, 3])
        monitor.update(session: nil)
        await gate.release()
    }

    func testSpanningApplicationAndExactTabProposalsDeduplicateAndTabsNeverTerminateBrowser() async throws {
        let fixture = try fixture()
        let application = ForegroundApplication(bundleID: ScriptableBrowser.chrome.bundleID, processID: 123)
        let windows = [1, 2].map { id in ScreenshotWindow(displayID: UInt32(id), windowID: 55,
            application: application, frame: CGRect(x: 0, y: 0, width: 200, height: 100)) }
        await fixture.source.set(try windows.map { .captured(try screenshot(id: $0.displayID, window: $0)) })
        let exact = TestScreenshotStage(name: "Exact tab") { context, analysis in
            var result = analysis
            let window = context.screenshot.windows[0]
            result.observations.append(.possibleDistraction(window))
            result.actions.append(.closeBrowserTab(.init(window: window, browser: .chrome,
                tab: .init(windowID: "script-77", index: 0, tabID: "456", url: "https://youtube.com/watch?v=example"))))
            return result
        }
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(100),
            policy: policy, processors: [exact], actions: fixture.actions)
        monitor.update(session: .task(task()))
        await eventually { fixture.actions.closed.count == 1 }
        monitor.update(session: nil)
        XCTAssertTrue(fixture.actions.terminated.isEmpty)
        XCTAssertEqual(fixture.actions.closed[0].tab.tabID, "456")

        fixture.actions.closed = []
        let spanning = ForegroundApplication(bundleID: "blocked.app", processID: 456)
        await fixture.source.set(try windows.map { window in
            .captured(try screenshot(id: window.displayID, window: .init(displayID: window.displayID,
                windowID: window.windowID, application: spanning, frame: window.frame)))
        })
        let appMonitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(100),
            policy: policy, actions: fixture.actions)
        appMonitor.update(session: .task(task()))
        await eventually { fixture.actions.terminated.count == 1 }
        appMonitor.update(session: nil)
        XCTAssertEqual(fixture.actions.terminated.count, 1)
    }

    func testPolicyEditDuringRevalidationRejectsActionAndPreservesWaitingCadence() async throws {
        let fixture = try fixture()
        let gate = ProcessingGate()
        fixture.actions.gate = gate
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(150),
            policy: policy, actions: fixture.actions)
        monitor.update(session: .task(task()))
        try await Task.sleep(for: .milliseconds(90))
        monitor.update(policy: .init(applications: policy.applications, websiteDomains: ["example.com"]))
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(fixture.actions.revalidated.isEmpty)
        monitor.update(policy: .init(applications: [], websiteDomains: []))
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        monitor.update(session: nil)
        XCTAssertTrue(fixture.actions.terminated.isEmpty)
    }

    func testPolicyEditDuringCaptureUsesLatestPolicyWithoutRecapturing() async throws {
        let fixture = try fixture()
        let gate = ProcessingGate()
        await fixture.source.setGate(gate)
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(100),
            policy: .init(applications: [], websiteDomains: []), actions: fixture.actions)
        monitor.update(session: .task(task()))
        let deadline = Date().addingTimeInterval(2)
        while await fixture.source.captures == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        monitor.update(policy: policy)
        await gate.release()
        await eventually { fixture.actions.terminated.count == 3 }
        monitor.update(session: nil)
        let captures = await fixture.source.captures
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(fixture.log.entries.compactMap(\.screenshot).count, 3)
    }

    func testPolicyPauseReplacementAndDeadlineRejectSuspendedProcessing() async throws {
        for change in 0..<4 {
            let fixture = try fixture()
            let gate = ProcessingGate()
            let blocked = TestScreenshotStage(name: "Suspended") { _, analysis in await gate.wait(); return analysis }
            var now = Date()
            let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(20),
                now: { now }, policy: policy, processors: [BlacklistedApplicationProcessor(), blocked], actions: fixture.actions)
            let active = task()
            monitor.update(session: .task(active))
            await eventually { fixture.log.entries.compactMap(\.screenshot).count == 3 }
            switch change {
            case 0: monitor.update(policy: .init(applications: [], websiteDomains: []))
            case 1: monitor.update(session: nil)
            case 2: monitor.update(session: .task(task()))
            default: now = try XCTUnwrap(active.endsAt)
            }
            await gate.release()
            try await Task.sleep(for: .milliseconds(5))
            monitor.update(session: nil)
            XCTAssertTrue(fixture.actions.terminated.isEmpty, "Change \(change)")
        }
    }

    func testPersistenceFailureDoesNotPreventAnalysisAndInventedWindowCannotAct() async throws {
        let fixture = try fixture()
        try FileManager.default.createDirectory(at: fixture.log.fileURL, withIntermediateDirectories: true)
        let forged = TestScreenshotStage(name: "Wrong association") { context, analysis in
            var result = analysis
            result.actions.append(.blockedApplication(.init(displayID: context.screenshot.displayID, windowID: 999,
                application: .init(bundleID: "blocked.app", processID: 999), frame: .zero)))
            return result
        }
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(100),
            policy: policy, processors: [BlacklistedApplicationProcessor(), forged], actions: fixture.actions)
        monitor.update(session: .task(task()))
        await eventually { fixture.actions.terminated.count == 3 }
        monitor.update(session: nil)
        XCTAssertFalse(fixture.actions.revalidated.contains { $0.windowID == 999 })
        XCTAssertTrue(fixture.log.entries.compactMap(\.screenshot).isEmpty)
    }

    func testGeometryIncludesFloatingWindowsAndExcludesOffScreenAndDesktopWindows() {
        let app = ForegroundApplication(bundleID: "blocked.app", processID: 1)
        let descriptors = [
            ScreenshotWindowDescriptor(windowID: 1, application: app, frame: CGRect(x: 90, y: 0, width: 20, height: 20), isOnScreen: true, layer: 0),
            ScreenshotWindowDescriptor(windowID: 2, application: app, frame: CGRect(x: 110, y: 0, width: 20, height: 20), isOnScreen: false, layer: 0),
            ScreenshotWindowDescriptor(windowID: 3, application: app, frame: CGRect(x: 110, y: 0, width: 20, height: 20), isOnScreen: true, layer: 3),
            ScreenshotWindowDescriptor(windowID: 4, application: app, frame: CGRect(x: 0, y: 0, width: 200, height: 100), isOnScreen: true, layer: -1)
        ]
        for id: UInt32 in [1, 2] {
            let frame = CGRect(x: id == 1 ? 0 : 100, y: 0, width: 100, height: 100)
            let result = ScreenshotWindowAssociation.windows(on: id, frame: frame, from: descriptors)
            XCTAssertEqual(result.map(\.windowID), id == 1 ? [1] : [1, 3])
            XCTAssertEqual(result.first?.displayID, id)
        }
    }

    func testDisplayAdditionAndRemovalApplyToTheNextSample() async throws {
        let fixture = try fixture()
        await fixture.source.set([.captured(try screenshot(id: 1))])
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(40), actions: fixture.actions)
        monitor.update(session: .task(task()))
        await eventually { fixture.log.entries.compactMap(\.screenshot).count == 1 }
        await fixture.source.set([.captured(try screenshot(id: 2)), .captured(try screenshot(id: 3))])
        await eventually { fixture.log.entries.compactMap(\.screenshot).count == 3 }
        monitor.update(session: nil)
        XCTAssertEqual(fixture.log.entries.compactMap { $0.screenshot?.displayID }, [1, 2, 3])
    }

    func testAppModelRunsInjectedProcessorsAndForwardsBlacklistChanges() async throws {
        let fixture = try fixture()
        let recorder = StageRecorder()
        let directory = fixture.log.fileURL.deletingLastPathComponent()
        let service = try TaskService(store: JSONTaskStore(url: directory.appendingPathComponent("tasks.json")))
        let active = try await service.addTask(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60)
        let suite = "hawkeye-processing-model-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(service: service, client: TickTickClient(token: "unused", transport: ProcessingOfflineTransport()),
            project: .init(id: "p", name: "Test"), preferences: preferences,
            tokenStore: .file(directory.appendingPathComponent("token")), screenshotCapturer: fixture.source,
            screenshotInterval: .milliseconds(40),
            screenshotProcessors: [stage("Injected processor", recorder: recorder), BlacklistedApplicationProcessor()],
            screenshotActions: fixture.actions)
        await model.start()
        await eventually { model.activity.entries.compactMap(\.screenshot).count >= 3 }
        XCTAssertTrue(fixture.actions.terminated.isEmpty)
        try model.distractions.addApplication(.init(bundleID: "blocked.app", name: "Blocked"))
        await eventually { fixture.actions.terminated.count == 3 }
        model.pause(active.id, minutes: 2)
        await eventually { model.userFocus.snooze != nil }
        let visits = await recorder.visits
        for id: UInt32 in [1, 2, 3] { XCTAssertTrue(visits[id]?.contains("Injected processor:0") == true) }
        XCTAssertFalse(model.permissions.effectsEnabled)
    }

    private var policy: DistractionPolicy { .init(applications: [.init(bundleID: "blocked.app", name: "Blocked")], websiteDomains: []) }
    private func task() -> TodoTask { .init(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60) }

    private func stage(_ name: String, recorder: StageRecorder, failingDisplay: UInt32? = nil) -> TestScreenshotStage {
        TestScreenshotStage(name: name) { context, analysis in
            await recorder.record(context.screenshot.displayID, "\(name):\(analysis.observations.count)")
            if context.screenshot.displayID == failingDisplay { throw DetectionFailure.failed }
            var result = analysis
            result.observations.append(.possibleDistraction(context.screenshot.windows[0]))
            return result
        }
    }

    private func screenshot(id: UInt32, window: ScreenshotWindow? = nil) throws -> DisplayScreenshot {
        let thumbnail = ScreenshotThumbnail(jpegData: try syntheticScreenshotJPEG(), capturedAt: Date())
        let target = window ?? ScreenshotWindow(displayID: id, windowID: id,
            application: .init(bundleID: "blocked.app", processID: Int32(id)), frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        guard case .captured(let image) = try screenshotBatch(thumbnail, displayID: id, windows: [target])[0] else { fatalError() }
        return image
    }

    private func fixture() throws -> (source: BatchScreenshotSource, log: ActivityLog, actions: ScreenshotActionSpy) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-processing-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (BatchScreenshotSource(try [1, 2, 3].map { .captured(try screenshot(id: $0)) }),
                ActivityLog(fileURL: directory.appendingPathComponent("activity.log")), ScreenshotActionSpy())
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private struct ProcessingOfflineTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

private actor StageRecorder {
    var visits: [UInt32: [String]] = [:]
    func record(_ display: UInt32, _ value: String) { visits[display, default: []].append(value) }
}

private struct TestScreenshotStage: ScreenshotProcessing {
    let name: String
    let operation: @Sendable (ScreenshotProcessingContext, ScreenshotAnalysis) async throws -> ScreenshotAnalysis
    func process(_ context: ScreenshotProcessingContext, analysis: ScreenshotAnalysis) async throws -> ScreenshotAnalysis {
        try await operation(context, analysis)
    }
}

private actor BatchScreenshotSource: ScreenshotCapturing {
    var outcomes: [DisplayCaptureOutcome]
    var captures = 0
    private var gate: ProcessingGate?
    init(_ outcomes: [DisplayCaptureOutcome]) { self.outcomes = outcomes }
    func set(_ outcomes: [DisplayCaptureOutcome]) { self.outcomes = outcomes }
    func setGate(_ gate: ProcessingGate) { self.gate = gate }
    func capture(before deadline: Date) async -> [DisplayCaptureOutcome] {
        captures += 1
        if let gate { await gate.wait() }
        return outcomes
    }
}

private actor ProcessingGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

@MainActor
private final class ScreenshotActionSpy: ScreenshotActions {
    var terminated: [ScreenshotWindow] = []
    var closed: [VisibleBrowserTab] = []
    var revalidated: [ScreenshotWindow] = []
    var gate: ProcessingGate?
    func revalidate(_ window: ScreenshotWindow, before deadline: Date) async -> Bool {
        revalidated.append(window)
        if let gate { await gate.wait() }
        return true
    }
    func terminate(_ window: ScreenshotWindow) -> Bool { terminated.append(window); return true }
    func close(_ target: VisibleBrowserTab, before deadline: Date, authorizing: @MainActor () -> Bool) async -> Bool {
        guard authorizing() else { return false }
        closed.append(target)
        return true
    }
}
