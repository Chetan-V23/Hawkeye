import Foundation

public struct UserSnooze: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let until: Date

    public init(taskID: UUID, until: Date) {
        self.taskID = taskID
        self.until = until
    }
}

public struct ManualTaskStart: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let start: Date

    public init(taskID: UUID, start: Date) {
        self.taskID = taskID
        self.start = start
    }

    func matches(_ task: TodoTask) -> Bool {
        task.id == taskID && !task.completed && task.dueAt == start
    }
}

public struct UserFocusState: Codable, Equatable, Sendable {
    public internal(set) var snooze: UserSnooze?
    public internal(set) var snoozedTaskIDs: Set<UUID>
    public internal(set) var announcedStarts: [UUID: Date]
    public internal(set) var manualStart: ManualTaskStart?

    public init(snooze: UserSnooze? = nil, snoozedTaskIDs: Set<UUID> = [], announcedStarts: [UUID: Date] = [:],
                manualStart: ManualTaskStart? = nil) {
        self.snooze = snooze
        self.snoozedTaskIDs = snoozedTaskIDs
        self.announcedStarts = announcedStarts
        self.manualStart = manualStart
    }
}

public enum TaskDeactivationReason: String, Sendable {
    case completed, expired, snoozed, rescheduled, superseded
}

public enum TaskFocusEvent: Equatable, Sendable {
    case activated(TodoTask, notify: Bool)
    case deactivated(TodoTask, reason: TaskDeactivationReason)
    case snoozed(UserSnooze)
    case snoozeEnded
}

public struct TaskFocusUpdate: Sendable {
    public let activeTask: TodoTask?
    public let user: UserFocusState
    public let events: [TaskFocusEvent]
    public let nextTransitionAt: Date?
}

public enum TaskFocusError: Error, LocalizedError, Equatable {
    case taskNotActive, alreadySnoozed, invalidPause, invalidDeferral, anotherTaskActive, taskAlreadyActive

    public var errorDescription: String? {
        switch self {
        case .taskNotActive: return "Only the active task can be paused."
        case .alreadySnoozed: return "This task has already been paused. Defer it to another time instead."
        case .invalidPause: return "Choose a pause of 2, 3, or 5 minutes."
        case .invalidDeferral: return "Choose a new start time in the future."
        case .anotherTaskActive: return "Another task is active. Complete, pause, or defer it before starting this task."
        case .taskAlreadyActive: return "This task is already active."
        }
    }
}

public extension TodoTask {
    var effectiveDuration: TimeInterval { duration ?? remoteDuration ?? 30 * 60 }
    var endsAt: Date? { dueAt?.addingTimeInterval(effectiveDuration) }

    func isWithinScheduledWindow(at date: Date) -> Bool {
        guard !completed, let start = dueAt, let end = endsAt else { return false }
        return start <= date && date < end
    }

    func isOverdue(at date: Date) -> Bool {
        !completed && endsAt.map { $0 <= date } == true
    }
}

struct TaskFocusController {
    private var activeTask: TodoTask?

    mutating func evaluate(tasks: [TodoTask], user: inout UserFocusState, at date: Date) -> TaskFocusUpdate {
        var events: [TaskFocusEvent] = []
        if let snooze = user.snooze, snooze.until <= date {
            user.snooze = nil
            events.append(.snoozeEnded)
        }
        let manualTask = user.manualStart.flatMap { selection in
            tasks.first { selection.matches($0) && $0.isWithinScheduledWindow(at: date) }
        }
        if manualTask == nil { user.manualStart = nil }
        let earliest = tasks.filter { $0.isWithinScheduledWindow(at: date) }.min {
            if $0.dueAt != $1.dueAt { return $0.dueAt! < $1.dueAt! }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let candidate = user.snooze == nil ? manualTask ?? earliest : nil

        if activeTask?.id != candidate?.id || activeTask?.dueAt != candidate?.dueAt {
            if let previous = activeTask {
                let current = tasks.first { $0.id == previous.id }
                let reason: TaskDeactivationReason
                if user.snooze != nil { reason = .snoozed }
                else if current?.completed == true { reason = .completed }
                else if current?.dueAt != previous.dueAt { reason = .rescheduled }
                else if current?.isWithinScheduledWindow(at: date) != true { reason = .expired }
                else { reason = .superseded }
                events.append(.deactivated(previous, reason: reason))
            }
            if let candidate, let start = candidate.dueAt {
                let notify = user.announcedStarts[candidate.id] != start
                user.announcedStarts[candidate.id] = start
                events.append(.activated(candidate, notify: notify))
            }
        }
        activeTask = candidate
        let boundaries = tasks.filter { !$0.completed }.flatMap { [$0.dueAt, $0.endsAt].compactMap { $0 } }
            + [user.snooze?.until].compactMap { $0 }
        return TaskFocusUpdate(activeTask: candidate, user: user, events: events,
                               nextTransitionAt: boundaries.filter { $0 > date }.min())
    }
}
