import XCTest
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class PomodoroTests: XCTestCase {
    func testStandaloneTimerRunsBothMonitorsThroughBreakAndStopsWithoutChangingTasks() async throws {
        let fixture = try makeFixture()
        fixture.model.startPomodoro()
        XCTAssertNil(fixture.model.activeTaskID)
        XCTAssertTrue(fixture.model.isMonitoringActive)
        let interval = try XCTUnwrap(fixture.model.pomodoro.interval)
        let identity = try XCTUnwrap(fixture.model.pomodoro.session?.id)
        await eventually {
            let detections = await fixture.detector.count
            let captures = await fixture.capturer.count
            return detections > 0 && captures > 0
        }
        let count = await fixture.capturer.count
        fixture.model.advancePomodoro(at: interval.endsAt)
        XCTAssertEqual(fixture.model.pomodoro.interval?.phase, .breakTime)
        XCTAssertTrue(fixture.model.isMonitoringActive)
        XCTAssertEqual(fixture.model.pomodoro.session?.id, identity)
        XCTAssertTrue(fixture.model.activity.entries.contains { $0.message.contains("Drink a glass of water") })
        await eventually { await fixture.capturer.count > count }
        let recorded = await fixture.detector.contexts
        XCTAssertTrue(recorded.allSatisfy { if case .pomodoro = $0.session { return true }; return false })
        XCTAssertTrue(recorded.allSatisfy { $0.deadline.timeIntervalSinceNow < 31 })
        let snapshot = await fixture.service.snapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty)
        fixture.model.stopPomodoro()
        XCTAssertFalse(fixture.model.isMonitoringActive)
        let stopped = await fixture.capturer.count
        try await Task.sleep(for: .milliseconds(60))
        let afterStop = await fixture.capturer.count
        XCTAssertEqual(afterStop, stopped)
    }

    func testCompletingATaskDoesNotTurnOffPomodoroMonitoring() async throws {
        let fixture = try makeFixture()
        let task = try await fixture.service.addTask(title: "Independent task", dueAt: Date(), duration: 120)
        await fixture.model.start(requestPermissions: false)
        fixture.model.startPomodoro()
        let completed = expectation(description: "Task completion saved")
        fixture.model.complete(task.id) { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(fixture.model.activeTaskID)
        XCTAssertTrue(fixture.model.isMonitoringActive)
        fixture.model.stopPomodoro()
        XCTAssertFalse(fixture.model.isMonitoringActive)
    }

    func testStoppingPomodoroPreservesActiveTaskMonitoring() async throws {
        let fixture = try makeFixture()
        let task = try await fixture.service.addTask(title: "Still active", dueAt: Date(), duration: 120)
        await fixture.model.start(requestPermissions: false)
        fixture.model.startPomodoro()
        fixture.model.stopPomodoro()
        XCTAssertEqual(fixture.model.activeTaskID, task.id)
        XCTAssertTrue(fixture.model.isMonitoringActive)
        await eventually {
            await fixture.detector.contexts.contains { if case .task(let active) = $0.session { return active.id == task.id }; return false }
        }
    }

    func testDurationPreferencesPersistAndInvalidPreferencesFallBackToDefaults() throws {
        let fixture = try makeFixture()
        let configuration = try XCTUnwrap(PomodoroConfiguration(focusMinutes: 45, breakMinutes: 12))
        fixture.model.configurePomodoro(configuration)
        let reloaded = makeModel(service: fixture.service, preferences: fixture.preferences, directory: fixture.directory,
                                 detector: fixture.detector, capturer: fixture.capturer)
        XCTAssertEqual(reloaded.pomodoro.configuration, configuration)
        XCTAssertNil(reloaded.pomodoro.session)
        fixture.preferences.set(-10, forKey: "pomodoro.focusMinutes")
        let invalid = makeModel(service: fixture.service, preferences: fixture.preferences, directory: fixture.directory,
                                detector: fixture.detector, capturer: fixture.capturer)
        XCTAssertEqual(invalid.pomodoro.configuration, .standard)
    }

    func testBackwardClockChangeKeepsBothStandaloneMonitorsRunning() async throws {
        let fixture = try makeFixture()
        var date = Date()
        var timer = PomodoroTimer()
        timer.start(at: date)
        let session = MonitoringSession.pomodoro(try XCTUnwrap(timer.session))
        let detector = fixture.detector
        let capturer = fixture.capturer
        let monitor = DistractionMonitor(detector: detector, actions: PomodoroActions(), log: fixture.model.activity, now: { date })
        let screenshots = ScreenshotMonitor(capturer: capturer, log: fixture.model.activity,
                                             interval: .milliseconds(20), now: { date })
        monitor.update(session: session)
        screenshots.update(session: session)
        await eventually { await detector.count > 0 }
        date = date.addingTimeInterval(-3600)
        let before = await detector.count
        let captures = await capturer.count
        monitor.update(session: session)
        screenshots.update(session: session)
        await eventually { await detector.count > before }
        await eventually { await capturer.count > captures }
        monitor.update(session: nil)
        screenshots.update(session: nil)
    }

    func testLateStandaloneDetectionCannotEnforceAfterItsOperationDeadline() async throws {
        let fixture = try makeFixture()
        var date = Date()
        var timer = PomodoroTimer()
        timer.start(at: date)
        let detector = DelayedPomodoroDetector()
        let actions = PomodoroActions(foreground: .init(bundleID: "com.apple.Chess", processID: 100))
        let monitor = DistractionMonitor(detector: detector, actions: actions, log: fixture.model.activity, now: { date })
        monitor.update(session: .pomodoro(try XCTUnwrap(timer.session)))
        await eventually { await detector.started }
        date = date.addingTimeInterval(31)
        await detector.finish(with: .application(try XCTUnwrap(actions.frontmostApplication())))
        await eventually { await detector.returned }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(actions.terminations, 0)
        monitor.update(session: nil)
    }

    private func makeFixture() throws -> (model: AppModel, service: TaskService, preferences: UserDefaults,
                                         directory: URL, detector: PomodoroDetector, capturer: PomodoroCapturer) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-pomodoro-\(UUID())")
        let suite = "hawkeye-pomodoro-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = try TaskService(store: JSONTaskStore(url: directory.appendingPathComponent("tasks.json")))
        let detector = PomodoroDetector()
        let capturer = PomodoroCapturer()
        let model = makeModel(service: service, preferences: preferences, directory: directory, detector: detector, capturer: capturer)
        return (model, service, preferences, directory, detector, capturer)
    }

    private func makeModel(service: TaskService, preferences: UserDefaults, directory: URL,
                           detector: PomodoroDetector, capturer: PomodoroCapturer) -> AppModel {
        AppModel(service: service, client: TickTickClient(token: "unused"), project: .init(id: "test", name: "Test"),
                 preferences: preferences, tokenStore: .file(directory.appendingPathComponent("token.txt")),
                 monitorDetector: detector, monitorActions: PomodoroActions(), screenshotCapturer: capturer,
                 screenshotInterval: .milliseconds(20))
    }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected monitoring effect did not occur", file: file, line: line)
    }
}

private actor PomodoroDetector: DistractionDetecting {
    nonisolated let method = MonitoringMethod.deterministic
    nonisolated let pollingInterval: Duration = .milliseconds(10)
    private(set) var contexts: [DetectionContext] = []
    var count: Int { contexts.count }
    func inspect(_ context: DetectionContext) async throws -> DetectionReport {
        contexts.append(context)
        return .findings([])
    }
}

private actor PomodoroCapturer: ScreenshotCapturing {
    private(set) var count = 0
    func capture(before deadline: Date) async throws -> [DisplayCaptureOutcome] {
        count += 1
        return []
    }
}

private actor DelayedPomodoroDetector: DistractionDetecting {
    nonisolated let method = MonitoringMethod.deterministic
    nonisolated let pollingInterval: Duration = .seconds(60)
    private(set) var started = false
    private(set) var returned = false
    private var continuation: CheckedContinuation<DetectionReport, Never>?

    func inspect(_ context: DetectionContext) async throws -> DetectionReport {
        started = true
        let report = await withCheckedContinuation { continuation = $0 }
        returned = true
        return report
    }

    func finish(with finding: DistractionFinding) {
        continuation?.resume(returning: .findings([finding]))
        continuation = nil
    }
}

@MainActor
private final class PomodoroActions: DistractionActions {
    let foreground: ForegroundApplication
    private(set) var terminations = 0
    init(foreground: ForegroundApplication = .init(bundleID: "com.example.editor", processID: 100)) { self.foreground = foreground }
    func frontmostApplication() -> ForegroundApplication? { foreground }
    func canAutomate(_ browser: ScriptableBrowser) -> Bool { false }
    func terminate(_ application: ForegroundApplication) -> Bool { terminations += 1; return false }
    func close(_ tab: BrowserTab, in browser: ScriptableBrowser, application: ForegroundApplication, before deadline: Date) async throws -> Bool { false }
}
