import Foundation

/// Keeps the selected calendar day and wall-clock time independent while editing.
public struct TaskScheduleSelection: Equatable, Sendable {
    public var day: Date
    public var hour: Int
    public var minute: Int

    public init(date: Date, calendar: Calendar = .current) {
        day = calendar.startOfDay(for: date)
        hour = calendar.component(.hour, from: date)
        minute = calendar.component(.minute, from: date)
    }

    public var hour12: Int { hour % 12 == 0 ? 12 : hour % 12 }
    public var isAfternoon: Bool { hour >= 12 }

    public mutating func selectHour12(_ value: Int) {
        guard (1...12).contains(value) else { return }
        hour = value % 12 + (isAfternoon ? 12 : 0)
    }
    public mutating func selectAfternoon(_ value: Bool) { hour = hour % 12 + (value ? 12 : 0) }

    /// Compares dates and times, so an earlier clock time tomorrow is still valid.
    public static func isValidStart(_ date: Date, at now: Date = Date()) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= now
    }

    /// Returns the next half hour on the clock, strictly after the supplied time.
    public static func nextHalfHour(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let minutes = 30 - calendar.component(.minute, from: now) % 30
        let minuteStart = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        return calendar.date(byAdding: .minute, value: minutes, to: minuteStart)
            ?? minuteStart.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Returns nil if the selected time does not exist on that day because of daylight saving time.
    public func resolved(calendar: Calendar = .current) -> Date? {
        guard (0..<24).contains(hour), (0..<60).contains(minute),
              let date = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                of: calendar.startOfDay(for: day), matchingPolicy: .strict, repeatedTimePolicy: .first),
              calendar.isDate(date, inSameDayAs: day),
              calendar.component(.hour, from: date) == hour,
              calendar.component(.minute, from: date) == minute else { return nil }
        return date
    }

    /// Returns the clockwise dial index, with zero at twelve o'clock. Coordinates are relative to the center.
    public static func dialIndex(dx: Double, dy: Double, divisions: Int) -> Int? {
        guard divisions > 0, dx.isFinite, dy.isFinite, abs(dx) + abs(dy) > 0.00001 else { return nil }
        let turn = 2 * Double.pi
        let angle = (atan2(dx, -dy) + turn).truncatingRemainder(dividingBy: turn)
        return Int((angle / turn * Double(divisions)).rounded()) % divisions
    }

    public static func monthStart(containing date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    public static func monthGrid(containing date: Date, calendar: Calendar = .current) -> [Date?] {
        let start = monthStart(containing: date, calendar: calendar)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let padding = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0..<42).map { index in
            let day = index - padding
            return (0..<range.count).contains(day) ? calendar.date(byAdding: .day, value: day, to: start) : nil
        }
    }
}
