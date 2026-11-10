import XCTest
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class BrowserContentMonitorTests: XCTestCase {
    func testCapturesImmediatelyThenAfterCompletionAndStops() async throws {
        let (source, log, _) = fixture()
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .milliseconds(100))
        monitor.update(session: .task(activeTask()))
        await eventually { log.entries.count == 1 }
        XCTAssertNotNil(log.entries.first?.browserContent)
        try await Task.sleep(for: .milliseconds(30))
        let count = await source.count
        XCTAssertEqual(count, 1)
        monitor.update(session: nil)
        try await Task.sleep(for: .milliseconds(140))
        let stoppedCount = await source.count
        XCTAssertEqual(stoppedCount, count)
    }

    func testIdleFutureAndExpiredTasksDoNotCapture() async throws {
        let (source, log, _) = fixture()
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .milliseconds(20))
        monitor.update(session: nil)
        monitor.update(session: .task(TodoTask(title: "Later", dueAt: Date().addingTimeInterval(30), duration: 60)))
        monitor.update(session: .task(TodoTask(title: "Expired", dueAt: Date().addingTimeInterval(-60), duration: 1)))
        try await Task.sleep(for: .milliseconds(40))
        let count = await source.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testDeadlineIsCappedAtFourSecondsAndTaskEnd() async throws {
        let (source, log, _) = fixture()
        let now = Date()
        let task = TodoTask(title: "Task", dueAt: now.addingTimeInterval(-1), duration: 2)
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .seconds(60), now: { now })
        monitor.update(session: .task(task))
        await waitForCaptures(1, source)
        let deadlines = await source.deadlines
        XCTAssertEqual(deadlines.first, task.endsAt)
        monitor.update(session: .task(activeTask()))
        await waitForCaptures(2, source)
        let capped = await source.deadlines
        XCTAssertEqual(capped.last, now.addingTimeInterval(4))
        monitor.update(session: nil)
    }

    func testReplacementWaitsForCancellationResistantCaptureAndRejectsOldResult() async throws {
        let (source, log, _) = fixture()
        let gate = BrowserCaptureGate()
        await source.setGate(gate)
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .milliseconds(25))
        monitor.update(session: .task(activeTask()))
        await waitForCaptures(1, source)
        monitor.update(session: .task(activeTask()))
        monitor.update(session: .task(activeTask()))
        try await Task.sleep(for: .milliseconds(50))
        let blocked = await source.count
        XCTAssertEqual(blocked, 1)
        await source.setGate(nil)
        await gate.resume(browserTestSnapshot())
        await eventually { log.entries.contains { $0.browserContent != nil } }
        monitor.update(session: nil)
        XCTAssertEqual(log.entries.filter { $0.browserContent != nil }.count, 1)
    }

    func testStopRejectsLateResultWithoutWritingAttachment() async throws {
        let (source, log, _) = fixture()
        let gate = BrowserCaptureGate()
        await source.setGate(gate)
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .milliseconds(20))
        monitor.update(session: .task(activeTask()))
        await waitForCaptures(1, source)
        monitor.update(session: nil)
        await gate.resume(browserTestSnapshot())
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.browserContentDirectory.path))
    }

    func testSameOccurrenceEditsRejectInflightResultAndPreserveCadence() async throws {
        let (source, log, _) = fixture()
        let gate = BrowserCaptureGate()
        await source.setGate(gate)
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .milliseconds(150))
        var task = activeTask()
        monitor.update(session: .task(task))
        await waitForCaptures(1, source)
        task.title = "Changed"
        task.duration = 120
        monitor.update(session: .task(task))
        await source.setGate(nil)
        await gate.resume(browserTestSnapshot())
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(log.entries.isEmpty)
        let early = await source.count
        XCTAssertEqual(early, 1)
        await eventually { log.entries.contains { $0.browserContent != nil } }
        monitor.update(session: nil)
    }

    func testIdenticalUpdatesKeepInflightCaptureValidAndExpiredResultsAreRejected() async throws {
        let (source, log, _) = fixture()
        let gate = BrowserCaptureGate()
        await source.setGate(gate)
        var now = Date()
        let task = TodoTask(title: "Task", dueAt: now.addingTimeInterval(-1), duration: 2)
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .seconds(60), now: { now })
        monitor.update(session: .task(task))
        await waitForCaptures(1, source)
        monitor.update(session: .task(task))
        await gate.resume(browserTestSnapshot(at: now))
        await eventually { log.entries.count == 1 }
        monitor.update(session: nil)
        let gate2 = BrowserCaptureGate()
        await source.setGate(gate2)
        monitor.update(session: .task(task))
        await waitForCaptures(2, source)
        now = try XCTUnwrap(task.endsAt)
        await gate2.resume(browserTestSnapshot(at: now))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(log.entries.count, 1)
        monitor.update(session: nil)
    }

    func testFailuresDeduplicateRecoverAndNonBrowserProducesNoError() async throws {
        let (source, log, _) = fixture()
        await source.setFailure(.permissionDenied)
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .milliseconds(20))
        monitor.update(session: .task(activeTask()))
        await waitForCaptures(3, source)
        XCTAssertEqual(log.entries.map(\.message), [BrowserContentFailure.permissionDenied.message])
        await source.setFailure(nil)
        await source.setNonBrowser(true)
        let before = await source.count
        await waitForCaptures(before + 2, source)
        XCTAssertEqual(log.entries.count, 1)
        await source.setNonBrowser(false)
        await eventually { log.entries.contains { $0.browserContent != nil } }
        await source.setFailure(.permissionDenied)
        await eventually { log.entries.filter { $0.message == BrowserContentFailure.permissionDenied.message }.count == 2 }
        monitor.update(session: nil)
    }

    func testPomodoroAndBrowserOnlyAppModelInjection() async throws {
        let (source, _, directory) = fixture()
        let service = try TaskService(store: JSONTaskStore(url: directory.appendingPathComponent("tasks.json")))
        let suite = "browser-monitor-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(service: service, client: TickTickClient(token: "unused", transport: BrowserOfflineTransport()),
            project: .init(id: "test", name: "Test"), preferences: preferences,
            tokenStore: .file(directory.appendingPathComponent("token")),
            browserContentCapturer: source, browserContentInterval: .milliseconds(20))
        await model.start(requestPermissions: false)
        let idleCount = await source.count
        XCTAssertEqual(idleCount, 0)
        model.startPomodoro()
        await eventually { model.activity.entries.contains { $0.browserContent != nil } }
        XCTAssertTrue(model.activity.entries.allSatisfy { $0.screenshot == nil })
        XCTAssertFalse(model.permissions.effectsEnabled)
        let sessionID = try XCTUnwrap(model.pomodoro.session?.id)
        model.advancePomodoro(at: try XCTUnwrap(model.pomodoro.interval?.endsAt))
        XCTAssertEqual(model.pomodoro.interval?.phase, .breakTime)
        let before = await source.count
        await waitForCaptures(before + 1, source)
        let attachments = model.activity.entries.compactMap(\.browserContent)
        for attachment in attachments {
            let record = try JSONDecoder().decode(BrowserContentRecord.self, from: Data(contentsOf: attachment.fileURL))
            XCTAssertEqual(record.sessionID, sessionID)
        }
        model.stopPomodoro()
        let stopped = await source.count
        try await Task.sleep(for: .milliseconds(60))
        let after = await source.count
        XCTAssertEqual(after, stopped)
    }

    func testTaskAppModelInjectionCapturesWithoutScreenshotsAndStopsOnPause() async throws {
        let (source, _, directory) = fixture()
        let service = try TaskService(store: JSONTaskStore(url: directory.appendingPathComponent("tasks.json")))
        let task = try await service.addTask(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60)
        let suite = "browser-task-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(service: service, client: TickTickClient(token: "unused", transport: BrowserOfflineTransport()),
            project: .init(id: "test", name: "Test"), preferences: preferences,
            tokenStore: .file(directory.appendingPathComponent("token")),
            browserContentCapturer: source, browserContentInterval: .milliseconds(20))
        await model.start(requestPermissions: false)
        await eventually { model.activity.entries.contains { $0.browserContent != nil } }
        let attachment = try XCTUnwrap(model.activity.entries.compactMap(\.browserContent).first)
        let record = try JSONDecoder().decode(BrowserContentRecord.self, from: Data(contentsOf: attachment.fileURL))
        XCTAssertEqual(record.sessionID, task.id)
        XCTAssertEqual(record.sessionStartedAt, task.dueAt)
        XCTAssertTrue(model.activity.entries.allSatisfy { $0.screenshot == nil })
        model.pause(task.id, minutes: 2)
        await eventually { model.userFocus.snooze != nil }
        let before = await source.count
        try await Task.sleep(for: .milliseconds(60))
        let after = await source.count
        XCTAssertEqual(after, before)
    }

    func testTypedTimeoutAfterCaptureBudgetIsVisibleWhileSessionIsActive() async throws {
        let (source, log, _) = fixture()
        let gate = BrowserCaptureGate()
        await source.setGate(gate)
        await source.setFailure(.timedOut)
        var now = Date()
        let task = TodoTask(title: "Task", dueAt: now.addingTimeInterval(-1), duration: 60)
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .seconds(60), now: { now })
        monitor.update(session: .task(task))
        await waitForCaptures(1, source)
        now = now.addingTimeInterval(5)
        await gate.resume(browserTestSnapshot(at: now))
        await eventually { !log.entries.isEmpty }
        XCTAssertEqual(log.entries.map(\.message), [BrowserContentFailure.timedOut.message])
        XCTAssertNil(log.entries.first?.browserContent)
        monitor.update(session: nil)
    }

    func testPersistenceFailureDeduplicatesAndRecoversOnNextInterval() async throws {
        let (source, log, _) = fixture()
        try FileManager.default.createDirectory(at: log.fileURL, withIntermediateDirectories: true)
        let monitor = BrowserContentMonitor(capturer: source, log: log, interval: .milliseconds(20))
        monitor.update(session: .task(activeTask()))
        await waitForCaptures(3, source)
        XCTAssertEqual(log.entries.map(\.message), [BrowserContentFailure.persistenceFailed.message])
        XCTAssertTrue(log.entries.allSatisfy { $0.browserContent == nil })
        XCTAssertNotNil(log.contentError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: log.browserContentDirectory.path), [])
        try FileManager.default.removeItem(at: log.fileURL)
        await eventually { log.entries.contains { $0.browserContent != nil } }
        XCTAssertNil(log.contentError)
        monitor.update(session: nil)
    }

    private func activeTask() -> TodoTask { TodoTask(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60) }
    private func fixture() -> (FakeBrowserCapture, ActivityLog, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-monitor-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (FakeBrowserCapture(), ActivityLog(fileURL: directory.appendingPathComponent("activity.log")), directory)
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func waitForCaptures(_ count: Int, _ source: FakeBrowserCapture, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while await source.count < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        let actual = await source.count
        XCTAssertGreaterThanOrEqual(actual, count, file: file, line: line)
    }
}

func browserTestSnapshot(at date: Date = Date()) -> BrowserContentSnapshot {
    BrowserContentSnapshot(capturedAt: date, browserBundleID: "com.apple.Safari", processID: 123,
                           pageTitle: "Private title", pageURL: URL(string: "https://private.example/page"),
                           fullText: "Private whole page text", mainContent: .init(text: "Private main text", source: .mainLandmark),
                           isTruncated: false)
}

private actor FakeBrowserCapture: BrowserContentCapturing {
    var count = 0
    var deadlines: [Date] = []
    private var failure: BrowserContentFailure?
    private var gate: BrowserCaptureGate?
    private var nonBrowser = false
    func setFailure(_ value: BrowserContentFailure?) { failure = value }
    func setGate(_ value: BrowserCaptureGate?) { gate = value }
    func setNonBrowser(_ value: Bool) { nonBrowser = value }
    func capture(before deadline: Date) async throws -> BrowserContentSnapshot? {
        count += 1
        deadlines.append(deadline)
        if let gate {
            let snapshot = await gate.wait()
            if let failure { throw failure }
            return snapshot
        }
        if let failure { throw failure }
        return nonBrowser ? nil : browserTestSnapshot()
    }
}

private actor BrowserCaptureGate {
    private var continuation: CheckedContinuation<BrowserContentSnapshot, Never>?
    private var buffered: BrowserContentSnapshot?
    func wait() async -> BrowserContentSnapshot {
        if let buffered { self.buffered = nil; return buffered }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume(_ snapshot: BrowserContentSnapshot) {
        if let continuation { continuation.resume(returning: snapshot); self.continuation = nil }
        else { buffered = snapshot }
    }
}

private struct BrowserOfflineTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}
