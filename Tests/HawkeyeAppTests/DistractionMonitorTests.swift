import XCTest
import Combine
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class DistractionMonitorTests: XCTestCase {
    private let safari = ForegroundApplication(bundleID: "com.apple.Safari", processID: 100)
    private let blockedTab = BrowserTab(windowID: "1", index: 1, tabID: nil, url: "https://instagram.com/p/private?x=secret")

    func testIdleExpiredAndUnsupportedAppsHaveNoDestructiveEffects() async throws {
        let effects = FakeDistractionEffects()
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(effects.foregroundReads, 0)
        monitor.update(session: .task(TodoTask(title: "Expired", dueAt: Date().addingTimeInterval(-60), duration: 1)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(effects.foregroundReads, 0)
        effects.frontmost = .init(bundleID: "com.example.editor", processID: 1)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.foregroundReads > 0 }
        monitor.update(session: nil)
        XCTAssertTrue(effects.terminated.isEmpty)
        XCTAssertEqual(effects.readCount, 0)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testChessFirefoxAndAnAdditionalConfiguredAppAreWholeAppBlocks() async throws {
        let custom = BlockedApplication(bundleID: "com.example.game", name: "Game")
        let policy = DistractionPolicy(applications: DistractionPolicy.standard.applications + [custom], websiteDomains: [])
        for application in policy.applications {
            let effects = FakeDistractionEffects()
            effects.frontmost = .init(bundleID: application.bundleID, processID: 101)
            let log = makeLog()
            let monitor = makeMonitor(effects, policy: policy, log: log)
            monitor.update(session: .task(activeTask()))
            await eventually { !effects.terminated.isEmpty }
            monitor.update(session: nil)
            XCTAssertEqual(effects.terminated.first?.bundleID, application.bundleID)
            XCTAssertEqual(effects.readCount, 0)
            try assertLog(log, messages: ["Detected blocked app \(application.name).", "Closing \(application.name).",
                                          "Force-quit request sent for \(application.name)."])
            XCTAssertEqual(log.entries.map(\.category), ["Focus detection", "Focus block", "Focus block"])
        }
    }

    func testMatchingTabsCloseInReverseOrderAndLogNoBrowsingURL() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        effects.observedTabs = [blockedTab, .init(windowID: "1", index: 3, tabID: nil, url: "https://www.instagram.com/secret"),
                               .init(windowID: "1", index: 0, tabID: nil, url: "https://example.com/?q=instagram.com")]
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.closed.count == 2 }
        monitor.update(session: nil)
        XCTAssertEqual(effects.closed.map(\.index), [3, 1])
        let messages = ["Detected blocked website instagram.com in Safari.", "Closing instagram.com tab in Safari.",
                        "Close command sent for instagram.com tab in Safari."]
        try assertLog(log, messages: messages + messages)
        XCTAssertTrue(log.entries.allSatisfy { !$0.message.contains("private") && !$0.message.contains("https://") && !$0.message.contains("secret") })
    }

    func testFailedAppRequestsKeepRetryingWithoutRepeatedLogsAndLogRecovery() async throws {
        let effects = FakeDistractionEffects()
        let application = ForegroundApplication(bundleID: "com.apple.Chess", processID: 101)
        effects.frontmost = application
        effects.terminationSucceeds = false
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.terminationAttempts.count >= 3 }
        let failed = ["Detected blocked app Chess.", "Closing Chess.",
                      "Could not send force-quit request for Chess. Will retry while it is in front."]
        try assertLog(log, messages: failed)
        XCTAssertTrue(effects.terminated.isEmpty)
        effects.terminationSucceeds = true
        await eventually { effects.terminated.count == 1 }
        effects.frontmost = application
        await eventually { effects.terminated.count == 2 }
        monitor.update(session: nil)
        try assertLog(log, messages: failed + ["Force-quit request sent for Chess.", "Detected blocked app Chess.",
                                              "Closing Chess.", "Force-quit request sent for Chess."])
    }

    func testFailedAppTargetIsReportedAgainAfterItLeavesTheForeground() async throws {
        let effects = FakeDistractionEffects()
        let application = ForegroundApplication(bundleID: "org.mozilla.firefox", processID: 102)
        effects.frontmost = application
        effects.terminationSucceeds = false
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.terminationAttempts.count >= 2 }
        effects.frontmost = .init(bundleID: "com.example.editor", processID: 103)
        let reads = effects.foregroundReads
        await eventually { effects.foregroundReads > reads }
        XCTAssertEqual(log.entries.count, 3)
        effects.frontmost = application
        await eventually { log.entries.count == 6 }
        monitor.update(session: nil)
        XCTAssertEqual(log.entries.filter { $0.category == "Focus detection" }.count, 2)
    }

    func testSkippedTabsKeepRetryingWithoutRepeatedLogsAndRedetectAfterDisappearing() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        effects.observedTabs = [blockedTab]
        effects.closeHandler = { _ in false }
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.closeAttempts.count >= 3 }
        let skipped = ["Detected blocked website instagram.com in Safari.", "Closing instagram.com tab in Safari.",
                       "Skipped instagram.com tab in Safari after revalidation."]
        try assertLog(log, messages: skipped)
        XCTAssertTrue(effects.closed.isEmpty)
        effects.observedTabs = []
        let reads = effects.readCount
        await eventually { effects.readCount > reads }
        effects.closeHandler = { _ in true }
        effects.observedTabs = [blockedTab]
        await eventually { effects.closed.count == 1 }
        monitor.update(session: nil)
        try assertLog(log, messages: skipped + ["Detected blocked website instagram.com in Safari.", "Closing instagram.com tab in Safari.",
                                               "Close command sent for instagram.com tab in Safari."])
    }

    func testThrownTabCloseUsesSafeFailureReasonsAndSuppressesRepeatedDetection() async throws {
        let failures: [(Error, String)] = [
            (CommandFailure.timedOut, "Browser command timed out."),
            (CommandFailure.failed, "Browser command failed."),
            (CommandFailure.outputTooLarge, "Browser response exceeded the size limit."),
            (NSError(domain: "https://instagram.com/private?secret", code: 1,
                     userInfo: [NSLocalizedDescriptionKey: "https://instagram.com/private?secret"]), "Check browser access in Focus permissions.")
        ]
        for (failure, reason) in failures {
            let effects = FakeDistractionEffects()
            effects.frontmost = safari
            effects.observedTabs = [blockedTab]
            effects.closeHandler = { _ in throw failure }
            let log = makeLog()
            let monitor = makeMonitor(effects, log: log)
            monitor.update(session: .task(activeTask()))
            await eventually { effects.closeAttempts.count >= 3 }
            monitor.update(session: nil)
            XCTAssertTrue(effects.closed.isEmpty)
            try assertLog(log, messages: ["Detected blocked website instagram.com in Safari.", "Closing instagram.com tab in Safari.",
                                         "Could not close instagram.com tab in Safari. \(reason)"])
        }
    }

    func testMissingAutomationIsReportedOnceAndRecoveryAllowsDetection() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        effects.automationGranted = false
        effects.observedTabs = [blockedTab]
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.foregroundReads >= 3 }
        let unavailable = "Cannot inspect or close blocked website tabs in Safari. Allow Automation access in Focus permissions."
        try assertLog(log, messages: [unavailable])
        effects.automationGranted = true
        await eventually { effects.closed.count == 1 }
        monitor.update(session: nil)
        try assertLog(log, messages: [unavailable, "Detected blocked website instagram.com in Safari.", "Closing instagram.com tab in Safari.",
                                     "Close command sent for instagram.com tab in Safari."])
    }

    func testChangedCloseFailureReasonLogsTheNewOutcomeWithoutRepeatingDetection() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        effects.observedTabs = [blockedTab]
        var failure = CommandFailure.timedOut
        effects.closeHandler = { _ in throw failure }
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.closeAttempts.count >= 3 }
        failure = .failed
        await eventually { log.entries.count == 4 }
        monitor.update(session: nil)
        try assertLog(log, messages: ["Detected blocked website instagram.com in Safari.", "Closing instagram.com tab in Safari.",
                                     "Could not close instagram.com tab in Safari. Browser command timed out.",
                                     "Could not close instagram.com tab in Safari. Browser command failed."])
    }

    func testStaleCloseResultCannotSuppressDetectionAfterPolicyRestart() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        effects.observedTabs = [blockedTab]
        let gate = ReadGate()
        effects.closeHandler = { _ in _ = await gate.wait(); return false }
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.closeAttempts.count == 1 }
        monitor.update(policy: .init(applications: [], websiteDomains: ["instagram.com", "example.org"]))
        effects.closeHandler = nil
        await gate.resume([])
        await eventually { effects.closed.count == 1 }
        monitor.update(session: nil)
        let attempted = ["Detected blocked website instagram.com in Safari.", "Closing instagram.com tab in Safari."]
        try assertLog(log, messages: attempted + attempted + ["Close command sent for instagram.com tab in Safari."])
    }

    func testAllowedBrowserTabsProduceNoDetectionOrClosingLogs() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        effects.observedTabs = [.init(windowID: "1", index: 0, tabID: nil, url: "https://example.com/?q=instagram.com")]
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.readCount >= 2 }
        monitor.update(session: nil)
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(effects.closeAttempts.isEmpty)
    }

    func testDeniedAutomationAndEmptyWebsitePolicyNeverInspectBrowsers() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        effects.automationGranted = false
        let monitor = makeMonitor(effects)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.foregroundReads > 0 }
        XCTAssertEqual(effects.readCount, 0)
        effects.automationGranted = true
        monitor.update(policy: .init(applications: [], websiteDomains: []))
        try await Task.sleep(for: .milliseconds(40))
        monitor.update(session: nil)
        XCTAssertEqual(effects.readCount, 0)
    }

    func testStoppingCancelsInFlightReadAndReactivationDiscardsOldResults() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        let reading = expectation(description: "Read started")
        let cancelled = expectation(description: "Read was cancelled")
        let gate = ReadGate()
        effects.readHandler = {
            reading.fulfill()
            return await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.fulfill() }
        }
        let monitor = makeMonitor(effects)
        monitor.update(session: .task(activeTask()))
        await fulfillment(of: [reading], timeout: 1)
        monitor.update(session: nil)
        effects.readHandler = { [] }
        monitor.update(session: .task(activeTask()))
        await fulfillment(of: [cancelled], timeout: 1)
        await gate.resume([blockedTab])
        await eventually { effects.readCount >= 2 }
        monitor.update(session: nil)
        XCTAssertTrue(effects.closed.isEmpty)
    }

    func testDeadlineAndForegroundAreRecheckedAfterAnAwait() async throws {
        for changeForeground in [false, true] {
            let effects = FakeDistractionEffects()
            effects.frontmost = safari
            let gate = ReadGate()
            effects.readHandler = { await gate.wait() }
            var now = Date()
            let task = TodoTask(title: "Task", dueAt: now.addingTimeInterval(-1), duration: 60)
            let monitor = makeMonitor(effects, now: { now })
            monitor.update(session: .task(task))
            await eventually { effects.readCount == 1 }
            if changeForeground { effects.frontmost = .init(bundleID: "com.example.editor", processID: 200) }
            else { now = try XCTUnwrap(task.endsAt) }
            await gate.resume([blockedTab])
            try await Task.sleep(for: .milliseconds(40))
            monitor.update(session: nil)
            XCTAssertTrue(effects.closed.isEmpty)
        }
    }

    func testRemovingDomainDuringReadPreventsStaleClosureAndNewPolicyTakesEffect() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        let gate = ReadGate()
        effects.readHandler = { await gate.wait() }
        let monitor = makeMonitor(effects)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.readCount == 1 }
        monitor.update(policy: .init(applications: [], websiteDomains: ["example.org"]))
        effects.readHandler = { [.init(windowID: "2", index: 0, tabID: nil, url: "https://sub.example.org")] }
        await gate.resume([blockedTab])
        await eventually { !effects.closed.isEmpty }
        monitor.update(session: nil)
        XCTAssertEqual(effects.closed.map(\.url), ["https://sub.example.org"])
    }

    func testReadFailureIsRecoverableAndDoesNotLogURLs() async throws {
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        effects.readHandler = { throw CommandFailure.timedOut }
        let log = makeLog()
        let monitor = makeMonitor(effects, log: log)
        monitor.update(session: .task(activeTask()))
        await eventually { effects.readCount >= 2 }
        XCTAssertEqual(log.entries.count, 1)
        effects.readHandler = { [self.blockedTab] }
        await eventually { !effects.closed.isEmpty }
        monitor.update(session: nil)
        XCTAssertFalse(log.entries.contains { $0.message.contains("https://") })
    }

    func testAppModelStartsRestartedOccurrenceWithoutNotificationThenPauseStopsMonitoring() async throws {
        let fixture = try makeAppFixture()
        let task = try await fixture.service.addTask(title: "Already announced", dueAt: Date().addingTimeInterval(-1), duration: 60)
        _ = try await fixture.service.evaluateFocus(at: Date())
        let reloaded = try TaskService(store: fixture.store)
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        effects.observedTabs = [blockedTab]
        let model = AppModel(service: reloaded, client: fixture.client, project: .init(id: "p", name: "Test"),
                             preferences: fixture.preferences, tokenStore: .file(fixture.directory.appendingPathComponent("token")),
                             monitorDetector: DeterministicDistractionDetector(observations: effects), monitorActions: effects)
        var activationNotifies: [Bool] = []
        let subscription = model.focusEvents.sink { if case .activated(_, let notify) = $0 { activationNotifies.append(notify) } }
        defer { subscription.cancel() }
        await model.start()
        await eventually { !effects.closed.isEmpty }
        XCTAssertEqual(activationNotifies, [false])
        XCTAssertFalse(model.permissions.effectsEnabled)
        model.pause(task.id, minutes: 2)
        await eventually { model.userFocus.snooze != nil }
        let previousReadCount = effects.readCount
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(effects.readCount, previousReadCount)
        XCTAssertNil(model.activeTaskID)
    }

    func testAppModelRefreshesDurationWithoutAnActivationEvent() async throws {
        let fixture = try makeAppFixture()
        let task = try await fixture.service.addTask(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60)
        let effects = FakeDistractionEffects()
        effects.frontmost = safari
        let gate = ReadGate()
        effects.readHandler = { await gate.wait() }
        let model = AppModel(service: fixture.service, client: fixture.client, project: .init(id: "p", name: "Test"),
                             preferences: fixture.preferences, tokenStore: .file(fixture.directory.appendingPathComponent("token")),
                             monitorDetector: DeterministicDistractionDetector(observations: effects), monitorActions: effects)
        await model.start()
        await eventually { effects.readCount == 1 }
        let updated = expectation(description: "Duration saved")
        let shortenedDuration = Date().timeIntervalSince(try XCTUnwrap(task.dueAt)) + 0.15
        model.update(task, title: task.title, description: "", dueAt: task.dueAt, duration: shortenedDuration) { success in
            XCTAssertTrue(success)
            updated.fulfill()
        }
        await fulfillment(of: [updated], timeout: 1)
        effects.readHandler = { [] }
        try await Task.sleep(for: .milliseconds(200))
        await gate.resume([blockedTab])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(effects.closed.isEmpty)
    }

    func testAppModelAppliesBlacklistEditsDuringActiveTask() async throws {
        let fixture = try makeAppFixture()
        _ = try await fixture.service.addTask(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60)
        let effects = FakeDistractionEffects()
        effects.frontmost = .init(bundleID: "com.example.game", processID: 202)
        let model = AppModel(service: fixture.service, client: fixture.client, project: .init(id: "p", name: "Test"),
                             preferences: fixture.preferences, tokenStore: .file(fixture.directory.appendingPathComponent("token")),
                             monitorDetector: DeterministicDistractionDetector(observations: effects), monitorActions: effects)
        await model.start()
        await eventually { effects.foregroundReads > 0 }
        XCTAssertTrue(effects.terminated.isEmpty)
        try model.distractions.addApplication(.init(bundleID: "com.example.game", name: "Game"))
        await eventually { !effects.terminated.isEmpty }
        XCTAssertEqual(effects.terminated.first?.bundleID, "com.example.game")
    }

    private func makeMonitor(_ effects: FakeDistractionEffects, policy: DistractionPolicy = .standard,
                             log: ActivityLog? = nil, now: @escaping () -> Date = Date.init) -> DistractionMonitor {
        DistractionMonitor(policy: policy, detector: DeterministicDistractionDetector(observations: effects),
                           actions: effects, log: log ?? makeLog(), interval: .milliseconds(20), now: now)
    }

    private func makeLog() -> ActivityLog {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-monitor-\(UUID()).log")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return ActivityLog(fileURL: url)
    }

    private func activeTask() -> TodoTask { TodoTask(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60) }

    private func assertLog(_ log: ActivityLog, messages: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(log.entries.map(\.message), messages, file: file, line: line)
        let persisted = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = persisted.split(separator: "\n")
        XCTAssertEqual(lines.count, messages.count, file: file, line: line)
        for (entry, message) in zip(lines, messages) { XCTAssertTrue(entry.hasSuffix(message), file: file, line: line) }
        for privateValue in ["https://", "private", "secret"] {
            XCTAssertFalse(persisted.contains(privateValue), file: file, line: line)
        }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func makeAppFixture() throws -> (service: TaskService, store: JSONTaskStore, client: TickTickClient, preferences: UserDefaults, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-monitor-app-\(UUID())")
        let suite = "hawkeye-monitor-app-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = JSONTaskStore(url: directory.appendingPathComponent("tasks.json"))
        return (try TaskService(store: store), store, TickTickClient(token: "unused", transport: OfflineTransport()), preferences, directory)
    }
}

private struct OfflineTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

private actor ReadGate {
    private var continuation: CheckedContinuation<[BrowserTab], Never>?
    private var buffered: [BrowserTab]?
    func wait() async -> [BrowserTab] {
        if let buffered { self.buffered = nil; return buffered }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume(_ tabs: [BrowserTab]) {
        if let continuation { continuation.resume(returning: tabs); self.continuation = nil }
        else { buffered = tabs }
    }
}

@MainActor
private final class FakeDistractionEffects: DistractionActions, DeterministicObservation {
    var frontmost: ForegroundApplication?
    var automationGranted = true
    var observedTabs: [BrowserTab] = []
    var readHandler: (() async throws -> [BrowserTab])?
    var closeHandler: ((BrowserTab) async throws -> Bool)?
    var terminationSucceeds = true
    var foregroundReads = 0
    var readCount = 0
    var terminationAttempts: [ForegroundApplication] = []
    var terminated: [ForegroundApplication] = []
    var closeAttempts: [BrowserTab] = []
    var closed: [BrowserTab] = []

    func frontmostApplication() -> ForegroundApplication? { foregroundReads += 1; return frontmost }
    func canAutomate(_ browser: ScriptableBrowser) -> Bool { automationGranted }
    func terminate(_ application: ForegroundApplication) -> Bool {
        terminationAttempts.append(application)
        guard terminationSucceeds else { return false }
        terminated.append(application)
        frontmost = nil
        return true
    }
    func tabs(in browser: ScriptableBrowser, application: ForegroundApplication, before deadline: Date) async throws -> [BrowserTab] {
        readCount += 1
        return try await readHandler?() ?? observedTabs
    }
    func close(_ tab: BrowserTab, in browser: ScriptableBrowser, application: ForegroundApplication, before deadline: Date) async throws -> Bool {
        closeAttempts.append(tab)
        let sent = try await closeHandler?(tab) ?? true
        if sent { closed.append(tab); observedTabs.removeAll { $0 == tab } }
        return sent
    }
}
