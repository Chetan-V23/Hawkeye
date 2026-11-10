import XCTest
import HawkeyeCore

final class PomodoroTimerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testDefaultsAlternateFocusAndBreakAtTheirDeadlines() throws {
        var timer = PomodoroTimer()
        timer.start(at: start)
        let session = timer.session
        XCTAssertEqual(timer.interval?.remaining(at: start), 25 * 60)
        XCTAssertNil(timer.advance(at: start.addingTimeInterval(1499)))
        let rest = try XCTUnwrap(timer.advance(at: start.addingTimeInterval(1500)))
        XCTAssertEqual(rest.phase, .breakTime)
        XCTAssertEqual(rest.remaining(at: start.addingTimeInterval(1500)), 300)
        let focus = try XCTUnwrap(timer.advance(at: start.addingTimeInterval(1800)))
        XCTAssertEqual(focus.phase, .focus)
        XCTAssertEqual(focus.remaining(at: start.addingTimeInterval(1800)), 1500)
        XCTAssertEqual(timer.session, session)
    }

    func testConfiguredDurationsAndSubsecondRemainingUseAbsoluteDeadlines() throws {
        var timer = PomodoroTimer(configuration: try XCTUnwrap(.init(focusMinutes: 7, breakMinutes: 2)))
        timer.start(at: start)
        XCTAssertEqual(timer.interval?.remaining(at: start.addingTimeInterval(419.5)), 0.5)
        let rest = try XCTUnwrap(timer.advance(at: start.addingTimeInterval(420)))
        XCTAssertEqual(rest.phase, .breakTime)
        XCTAssertEqual(rest.endsAt, start.addingTimeInterval(540))
        XCTAssertEqual(timer.advance(at: start.addingTimeInterval(540))?.phase, .focus)
    }

    func testWakeSkipsDaysOfMissedCyclesAndDoesNotRepeatTransitions() throws {
        var timer = PomodoroTimer()
        timer.start(at: start)
        let wake = start.addingTimeInterval(1800 * 10_000 + 1510)
        let current = try XCTUnwrap(timer.advance(at: wake))
        XCTAssertEqual(current.phase, .breakTime)
        XCTAssertEqual(current.remaining(at: wake), 290)
        XCTAssertNil(timer.advance(at: wake))
        XCTAssertNil(timer.advance(at: wake.addingTimeInterval(1)))
    }

    func testDurationChangesApplyOnNextStartAndStopResetsToFocus() throws {
        var timer = PomodoroTimer()
        timer.start(at: start)
        let firstSession = timer.session
        timer.configure(try XCTUnwrap(.init(focusMinutes: 10, breakMinutes: 3)))
        XCTAssertEqual(timer.advance(at: start.addingTimeInterval(1500))?.remaining(at: start.addingTimeInterval(1500)), 300)
        timer.stop()
        timer.stop()
        XCTAssertNil(timer.interval)
        XCTAssertNil(timer.session)
        XCTAssertNil(timer.advance(at: start.addingTimeInterval(100_000)))
        timer.start(at: start.addingTimeInterval(2000))
        XCTAssertNotEqual(timer.session?.id, firstSession?.id)
        XCTAssertEqual(timer.interval?.phase, .focus)
        XCTAssertEqual(timer.interval?.remaining(at: start.addingTimeInterval(2000)), 600)
    }

    func testRepeatedStartAndBackwardClockDoNotRestartOrReplayACompletedPhase() {
        var timer = PomodoroTimer()
        timer.start(at: start)
        let session = timer.session
        timer.start(at: start.addingTimeInterval(100))
        XCTAssertEqual(timer.session, session)
        _ = timer.advance(at: start.addingTimeInterval(1500))
        XCTAssertNil(timer.advance(at: start.addingTimeInterval(1000)))
        XCTAssertEqual(timer.interval?.phase, .breakTime)
    }

    func testInvalidDurationSettingsAreRejected() {
        XCTAssertNil(PomodoroConfiguration(focusMinutes: 0, breakMinutes: 5))
        XCTAssertNil(PomodoroConfiguration(focusMinutes: 181, breakMinutes: 5))
        XCTAssertNil(PomodoroConfiguration(focusMinutes: 25, breakMinutes: -1))
        XCTAssertNil(PomodoroConfiguration(focusMinutes: 25, breakMinutes: 61))
    }
}
