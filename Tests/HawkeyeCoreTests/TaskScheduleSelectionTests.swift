import Foundation
import XCTest
@testable import HawkeyeCore

final class TaskScheduleSelectionTests: XCTestCase {
    func testSuggestionUsesStrictNextHalfHourBeforeAtAndAfterBoundary() {
        let calendar = calendar(in: "Asia/Kolkata")
        for (hour, minute, second, expectedHour, expectedMinute) in [
            (10, 0, 0, 10, 30),
            (10, 15, 0, 10, 30),
            (10, 29, 59, 10, 30),
            (10, 30, 0, 11, 0),
            (10, 30, 1, 11, 0),
            (10, 59, 59, 11, 0)
        ] {
            let now = date(2026, 10, 21, hour, minute, second, calendar: calendar)
            let expected = date(2026, 10, 21, expectedHour, expectedMinute, calendar: calendar)
            XCTAssertEqual(TaskScheduleSelection.nextHalfHour(after: now, calendar: calendar), expected)
        }
    }

    func testSuggestionRollsOverMidnightAndYear() {
        let calendar = calendar(in: "Asia/Kolkata")
        let now = date(2026, 12, 31, 23, 45, calendar: calendar)
        XCTAssertEqual(TaskScheduleSelection.nextHalfHour(after: now, calendar: calendar),
                       date(2027, 1, 1, 0, 0, calendar: calendar))
    }

    func testSuggestionClearsFractionalSeconds() {
        let calendar = calendar(in: "UTC")
        let now = date(2026, 10, 21, 10, 29, 59, calendar: calendar).addingTimeInterval(0.75)
        XCTAssertEqual(TaskScheduleSelection.nextHalfHour(after: now, calendar: calendar),
                       date(2026, 10, 21, 10, 30, calendar: calendar))
    }

    func testSuggestionSkipsMissingSpringHour() {
        let calendar = calendar(in: "America/Los_Angeles")
        let now = date(2026, 3, 8, 1, 45, calendar: calendar)
        let suggestion = TaskScheduleSelection.nextHalfHour(after: now, calendar: calendar)
        XCTAssertEqual(suggestion, date(2026, 3, 8, 3, 0, calendar: calendar))
        XCTAssertEqual(suggestion.timeIntervalSince(now), 15 * 60)
    }

    func testSuggestionUsesNextChronologicalBoundaryAcrossRepeatedHour() {
        let calendar = calendar(in: "America/Los_Angeles")
        let now = ISO8601DateFormatter().date(from: "2026-11-01T01:45:00-07:00")!
        let expected = ISO8601DateFormatter().date(from: "2026-11-01T01:00:00-08:00")!
        XCTAssertEqual(TaskScheduleSelection.nextHalfHour(after: now, calendar: calendar), expected)
    }

    func testSuggestionHandlesHalfHourDaylightSavingTransition() {
        let calendar = calendar(in: "Australia/Lord_Howe")
        let now = date(2026, 10, 4, 1, 45, calendar: calendar)
        XCTAssertEqual(TaskScheduleSelection.nextHalfHour(after: now, calendar: calendar),
                       date(2026, 10, 4, 2, 30, calendar: calendar))
    }

    func testTwelveHourControlsPreserveMeridiemAndMinutes() {
        let calendar = calendar(in: "UTC")
        var draft = TaskScheduleSelection(date: date(2026, 10, 21, 0, 37, calendar: calendar), calendar: calendar)
        XCTAssertEqual(draft.hour12, 12)
        XCTAssertFalse(draft.isAfternoon)
        draft.selectAfternoon(true)
        XCTAssertEqual(draft.hour, 12)
        draft.selectHour12(3)
        XCTAssertEqual(draft.hour, 15)
        draft.selectAfternoon(false)
        XCTAssertEqual(draft.hour, 3)
        draft.selectHour12(12)
        XCTAssertEqual(draft.hour, 0)
        draft.selectHour12(0)
        draft.selectHour12(13)
        XCTAssertEqual(draft.hour, 0)
        XCTAssertEqual(draft.minute, 37)
        XCTAssertEqual(draft.resolved(calendar: calendar), date(2026, 10, 21, 0, 37, calendar: calendar))
    }

    func testResolvingChangedDayPreservesWallClockAndRejectsMissingTime() {
        let calendar = calendar(in: "America/Los_Angeles")
        var draft = TaskScheduleSelection(date: date(2026, 3, 7, 2, 30, calendar: calendar), calendar: calendar)
        draft.day = date(2026, 3, 8, 0, 0, calendar: calendar)
        XCTAssertNil(draft.resolved(calendar: calendar))
        draft.hour = 3
        XCTAssertEqual(draft.resolved(calendar: calendar), date(2026, 3, 8, 3, 30, calendar: calendar))
        draft.minute = 60
        XCTAssertNil(draft.resolved(calendar: calendar))
    }

    func testCalendarGridContainsEachDayAcrossDaylightSavingChange() throws {
        var calendar = calendar(in: "America/Los_Angeles")
        calendar.firstWeekday = 2
        let march = date(2026, 3, 12, 12, 0, calendar: calendar)
        let grid = TaskScheduleSelection.monthGrid(containing: march, calendar: calendar)
        XCTAssertEqual(grid.count, 42)
        XCTAssertTrue(grid.prefix(6).allSatisfy { $0 == nil })
        let days = grid.compactMap { $0 }
        XCTAssertEqual(days.count, 31)
        XCTAssertEqual(days.map { calendar.component(.day, from: $0) }, Array(1...31))
        XCTAssertEqual(Set(days).count, 31)
        for (previous, next) in zip(days, days.dropFirst()) {
            XCTAssertEqual(calendar.dateComponents([.day], from: previous, to: next).day, 1)
            XCTAssertEqual(calendar.component(.hour, from: next), 0)
        }
        XCTAssertEqual(days[8].timeIntervalSince(days[7]), 23 * 60 * 60)
        XCTAssertEqual(TaskScheduleSelection.monthStart(containing: march, calendar: calendar), try XCTUnwrap(days.first))
    }

    func testDialCoordinatesAndCompleteInstantValidation() {
        XCTAssertEqual(TaskScheduleSelection.dialIndex(dx: 0, dy: -1, divisions: 12), 0)
        XCTAssertEqual(TaskScheduleSelection.dialIndex(dx: 1, dy: 0, divisions: 12), 3)
        XCTAssertEqual(TaskScheduleSelection.dialIndex(dx: -1, dy: 0, divisions: 60), 45)
        XCTAssertNil(TaskScheduleSelection.dialIndex(dx: 0, dy: 0, divisions: 12))
        XCTAssertNil(TaskScheduleSelection.dialIndex(dx: .nan, dy: 1, divisions: 12))
        let calendar = calendar(in: "UTC")
        let now = date(2026, 10, 21, 23, 45, calendar: calendar)
        XCTAssertTrue(TaskScheduleSelection.isValidStart(date(2026, 10, 22, 0, 0, calendar: calendar), at: now))
        XCTAssertFalse(TaskScheduleSelection.isValidStart(now.addingTimeInterval(-1), at: now))
    }

    private func calendar(in timeZone: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: timeZone)!
        return result
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                      _ second: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                          hour: hour, minute: minute, second: second))!
    }
}
