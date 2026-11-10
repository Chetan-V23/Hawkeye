import Foundation
import HawkeyeCore

enum MonitoringSession: Equatable, Sendable {
    case task(TodoTask)
    case pomodoro(PomodoroTimer.Session)

    var id: UUID {
        switch self {
        case .task(let task): return task.id
        case .pomodoro(let session): return session.id
        }
    }

    var startedAt: Date? {
        switch self {
        case .task(let task): return task.dueAt
        case .pomodoro(let session): return session.startedAt
        }
    }

    func operationDeadline(at date: Date) -> Date {
        switch self {
        case .task(let task): return task.endsAt ?? date
        case .pomodoro: return date.addingTimeInterval(30)
        }
    }

    func isActive(at date: Date) -> Bool {
        switch self {
        case .task(let task): return task.isWithinScheduledWindow(at: date)
        case .pomodoro: return true
        }
    }
}
