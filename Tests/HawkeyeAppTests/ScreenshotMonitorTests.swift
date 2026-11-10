import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class ScreenshotMonitorTests: XCTestCase {
    func testCapturesOnlyAfterIntervalAndStopsWhenPaused() async throws {
        let fixture = try makeFixture()
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(80))
        monitor.update(session: .task(activeTask()))
        try await Task.sleep(for: .milliseconds(20))
        let earlyCount = await fixture.source.count
        XCTAssertEqual(earlyCount, 0)
        await eventually { !fixture.log.entries.isEmpty }
        XCTAssertNotNil(fixture.log.entries.first?.screenshot)
        monitor.update(session: nil)
        let stoppedCount = await fixture.source.count
        try await Task.sleep(for: .milliseconds(110))
        let afterPause = await fixture.source.count
        XCTAssertEqual(afterPause, stoppedCount)
    }

    func testIdleAndExpiredTasksNeverCapture() async throws {
        let fixture = try makeFixture()
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(20))
        monitor.update(session: nil)
        monitor.update(session: .task(TodoTask(title: "Expired", dueAt: Date().addingTimeInterval(-60), duration: 1)))
        try await Task.sleep(for: .milliseconds(60))
        let count = await fixture.source.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(fixture.log.entries.isEmpty)
    }

    func testSameOccurrenceEditsPreserveCadenceAndUpdateCaptureDeadline() async throws {
        let fixture = try makeFixture()
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(160))
        var task = activeTask()
        monitor.update(session: .task(task))
        try await Task.sleep(for: .milliseconds(100))
        task.title = "Edited title"
        task.duration = 120
        monitor.update(session: .task(task))
        try await Task.sleep(for: .milliseconds(100))
        let deadlines = await fixture.source.deadlines
        monitor.update(session: nil)
        XCTAssertEqual(deadlines.count, 1)
        XCTAssertEqual(deadlines.first, task.endsAt)
    }

    func testReschedulingStartsANewInterval() async throws {
        let fixture = try makeFixture()
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(120))
        var task = activeTask()
        monitor.update(session: .task(task))
        try await Task.sleep(for: .milliseconds(70))
        task.dueAt = Date()
        monitor.update(session: .task(task))
        try await Task.sleep(for: .milliseconds(70))
        let count = await fixture.source.count
        XCTAssertEqual(count, 0)
        await eventually { !fixture.log.entries.isEmpty }
        monitor.update(session: nil)
    }

    func testOnlyOneCaptureRunsAndLateResultAfterPauseIsDiscarded() async throws {
        let fixture = try makeFixture()
        let gate = ScreenshotGate()
        await fixture.source.setGate(gate)
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(20))
        monitor.update(session: .task(activeTask()))
        await waitForCaptures(1, source: fixture.source)
        try await Task.sleep(for: .milliseconds(70))
        let count = await fixture.source.count
        XCTAssertEqual(count, 1)
        monitor.update(session: nil)
        await gate.resume(ScreenshotThumbnail(jpegData: fixture.jpeg, capturedAt: Date()))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.log.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.screenshotsDirectory.path))
    }

    func testReplacementWaitsForPreviousCaptureAndRejectsItsThumbnail() async throws {
        let fixture = try makeFixture()
        let gate = ScreenshotGate()
        await fixture.source.setGate(gate)
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(20))
        monitor.update(session: .task(activeTask()))
        await waitForCaptures(1, source: fixture.source)
        monitor.update(session: .task(activeTask()))
        try await Task.sleep(for: .milliseconds(40))
        let count = await fixture.source.count
        XCTAssertEqual(count, 1)
        await fixture.source.setGate(nil)
        await gate.resume(ScreenshotThumbnail(jpegData: fixture.jpeg, capturedAt: Date()))
        await eventually { fixture.log.entries.contains { $0.screenshot != nil } }
        monitor.update(session: nil)
        XCTAssertEqual(fixture.log.entries.filter { $0.screenshot != nil }.count, 1)
    }

    func testLatestDeadlineRejectsLateCaptureAndAnExtendedIdleOccurrenceCanRestart() async throws {
        let fixture = try makeFixture()
        let gate = ScreenshotGate()
        await fixture.source.setGate(gate)
        var now = Date()
        var task = TodoTask(title: "Task", dueAt: now.addingTimeInterval(-1), duration: 60)
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(20), now: { now })
        monitor.update(session: .task(task))
        await waitForCaptures(1, source: fixture.source)
        task.duration = 2
        monitor.update(session: .task(task))
        now = try XCTUnwrap(task.endsAt)
        await gate.resume(ScreenshotThumbnail(jpegData: fixture.jpeg, capturedAt: now))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.log.entries.isEmpty)
        await fixture.source.setGate(nil)
        task.duration = 120
        monitor.update(session: .task(task))
        await eventually { fixture.log.entries.contains { $0.screenshot != nil } }
        monitor.update(session: nil)
    }

    func testPermissionFailuresAreDeduplicatedAndRecoverWithoutPrompts() async throws {
        let fixture = try makeFixture()
        await fixture.source.setFailure(.permissionDenied)
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(20))
        monitor.update(session: .task(activeTask()))
        await waitForCaptures(3, source: fixture.source)
        XCTAssertEqual(fixture.log.entries.map(\.message), [ScreenshotFailure.permissionDenied.message])
        await fixture.source.setFailure(nil)
        await eventually { fixture.log.entries.contains { $0.screenshot != nil } }
        await fixture.source.setFailure(.permissionDenied)
        await eventually { fixture.log.entries.filter { $0.message == ScreenshotFailure.permissionDenied.message }.count == 2 }
        monitor.update(session: nil)
    }

    func testPersistenceFailureIsVisibleWithoutASuccessAttachment() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.log.fileURL, withIntermediateDirectories: true)
        let monitor = ScreenshotMonitor(capturer: fixture.source, log: fixture.log, interval: .milliseconds(20))
        monitor.update(session: .task(activeTask()))
        await eventually { !fixture.log.entries.isEmpty }
        monitor.update(session: nil)
        XCTAssertEqual(fixture.log.entries.map(\.message), ["Display 1: \(ScreenshotFailure.persistenceFailed.message)"])
        XCTAssertTrue(fixture.log.entries.allSatisfy { $0.screenshot == nil })
        XCTAssertNotNil(fixture.log.screenshotError)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.log.screenshotsDirectory.path)
        XCTAssertTrue(files.isEmpty)
    }

    func testDisabledNativeSourceReturnsBeforeAnySystemAccess() async throws {
        do {
            _ = try await MacScreenshotCapture(effectsEnabled: false).capture(before: Date().addingTimeInterval(1))
            XCTFail("Disabled native sampling must not run.")
        } catch { XCTAssertEqual(error as? ScreenshotFailure, .disabled) }
    }

    func testAppModelCapturesOnlyWithExplicitFakeSourceAndPausingStopsIt() async throws {
        let fixture = try makeFixture()
        let store = JSONTaskStore(url: fixture.directory.appendingPathComponent("tasks.json"))
        let service = try TaskService(store: store)
        let task = try await service.addTask(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60)
        let suite = "hawkeye-screenshot-app-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(service: service, client: TickTickClient(token: "unused", transport: ScreenshotOfflineTransport()),
                             project: .init(id: "p", name: "Test"), preferences: preferences,
                             tokenStore: .file(fixture.directory.appendingPathComponent("token")),
                             screenshotCapturer: fixture.source, screenshotInterval: .milliseconds(20))
        await model.start()
        await eventually { model.activity.entries.contains { $0.screenshot != nil } }
        model.pause(task.id, minutes: 2)
        await eventually { model.userFocus.snooze != nil }
        let count = await fixture.source.count
        try await Task.sleep(for: .milliseconds(50))
        let afterPause = await fixture.source.count
        XCTAssertEqual(afterPause, count)
        XCTAssertFalse(model.permissions.effectsEnabled)
    }

    private func activeTask() -> TodoTask { TodoTask(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60) }

    private func makeFixture() throws -> (source: FakeScreenshotCapture, log: ActivityLog, jpeg: Data, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-screenshot-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try syntheticScreenshotJPEG()
        return (FakeScreenshotCapture(jpeg: jpeg), ActivityLog(fileURL: directory.appendingPathComponent("activity.log")), jpeg, directory)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func waitForCaptures(_ count: Int, source: FakeScreenshotCapture, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while await source.count < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        let actual = await source.count
        XCTAssertGreaterThanOrEqual(actual, count, file: file, line: line)
    }
}

private struct ScreenshotOfflineTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

private actor FakeScreenshotCapture: ScreenshotCapturing {
    let jpeg: Data
    var count = 0
    var deadlines: [Date] = []
    private var failure: ScreenshotFailure?
    private var gate: ScreenshotGate?

    init(jpeg: Data) { self.jpeg = jpeg }
    func setFailure(_ failure: ScreenshotFailure?) { self.failure = failure }
    func setGate(_ gate: ScreenshotGate?) { self.gate = gate }
    func capture(before deadline: Date) async throws -> [DisplayCaptureOutcome] {
        count += 1
        deadlines.append(deadline)
        if let gate { return try screenshotBatch(await gate.wait()) }
        if let failure { throw failure }
        return try screenshotBatch(ScreenshotThumbnail(jpegData: jpeg, capturedAt: Date()))
    }
}

func screenshotBatch(_ thumbnail: ScreenshotThumbnail, displayID: UInt32 = 1,
                     windows: [ScreenshotWindow] = []) throws -> [DisplayCaptureOutcome] {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail.jpegData as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return [.captured(DisplayScreenshot(displayID: displayID, displayFrame: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                       image: image, thumbnail: thumbnail, windows: windows))]
}

private actor ScreenshotGate {
    private var continuation: CheckedContinuation<ScreenshotThumbnail, Never>?
    private var buffered: ScreenshotThumbnail?
    func wait() async -> ScreenshotThumbnail {
        if let buffered { self.buffered = nil; return buffered }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume(_ thumbnail: ScreenshotThumbnail) {
        if let continuation { continuation.resume(returning: thumbnail); self.continuation = nil }
        else { buffered = thumbnail }
    }
}

func syntheticScreenshotJPEG() throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 150))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}
