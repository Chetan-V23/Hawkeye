import Foundation

public struct PomodoroConfiguration: Equatable, Sendable {
    public static let focusRange = 1...180
    public static let breakRange = 1...60
    public static let standard = PomodoroConfiguration(focusMinutes: 25, breakMinutes: 5)!

    public let focusMinutes: Int
    public let breakMinutes: Int

    public init?(focusMinutes: Int, breakMinutes: Int) {
        guard Self.focusRange.contains(focusMinutes), Self.breakRange.contains(breakMinutes) else { return nil }
        self.focusMinutes = focusMinutes
        self.breakMinutes = breakMinutes
    }

    public func duration(for phase: PomodoroPhase) -> TimeInterval {
        TimeInterval(phase == .focus ? focusMinutes : breakMinutes) * 60
    }
}

public enum PomodoroPhase: String, Equatable, Sendable {
    case focus, breakTime
}

public struct PomodoroTimer: Equatable, Sendable {
    public struct Session: Equatable, Sendable {
        public let id: UUID
        public let startedAt: Date
        public let configuration: PomodoroConfiguration
    }

    public struct Interval: Equatable, Sendable {
        public let phase: PomodoroPhase
        public let startedAt: Date
        public let endsAt: Date

        public func remaining(at date: Date) -> TimeInterval {
            max(0, endsAt.timeIntervalSince(date))
        }
    }

    public private(set) var configuration: PomodoroConfiguration
    public private(set) var session: Session?
    public private(set) var interval: Interval?

    public init(configuration: PomodoroConfiguration = .standard) {
        self.configuration = configuration
    }

    public mutating func configure(_ configuration: PomodoroConfiguration) {
        self.configuration = configuration
    }

    public mutating func start(at date: Date) {
        guard session == nil else { return }
        session = Session(id: UUID(), startedAt: date, configuration: configuration)
        interval = Interval(phase: .focus, startedAt: date,
                            endsAt: date.addingTimeInterval(configuration.duration(for: .focus)))
    }

    public mutating func stop() {
        session = nil
        interval = nil
    }

    @discardableResult
    public mutating func advance(at date: Date) -> Interval? {
        guard let session, let interval, date >= interval.endsAt else { return nil }
        let focus = session.configuration.duration(for: .focus)
        let rest = session.configuration.duration(for: .breakTime)
        let cycle = focus + rest
        let elapsed = date.timeIntervalSince(session.startedAt)
        let cycleStart = session.startedAt.addingTimeInterval(floor(elapsed / cycle) * cycle)
        let onBreak = date.timeIntervalSince(cycleStart) >= focus
        let start = onBreak ? cycleStart.addingTimeInterval(focus) : cycleStart
        let current = Interval(phase: onBreak ? .breakTime : .focus, startedAt: start,
                               endsAt: start.addingTimeInterval(onBreak ? rest : focus))
        self.interval = current
        return current
    }
}
