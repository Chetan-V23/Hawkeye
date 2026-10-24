import Foundation
import SwiftUI
import HawkeyeCore
import Combine
import AppKit

struct ProjectOption: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tasks: [TodoTask] = []
    @Published private(set) var connected = false
    @Published private(set) var syncing = false
    @Published private(set) var saving = false
    @Published private(set) var ready = false
    @Published private(set) var projectName = "your selected list"
    @Published private(set) var projectID = ""
    @Published private(set) var syncStatus = "Connect TickTick in settings."
    @Published var error: String?
    @Published var now = Date()
    @Published var showSettings = false
    @Published var showFocusConfiguration = false
    @Published private(set) var activeTaskID: UUID?
    @Published private(set) var userFocus = UserFocusState()
    let focusEvents = PassthroughSubject<TaskFocusEvent, Never>()
    let activity: ActivityLog
    let permissions: FocusPermissions
    let distractions: DistractionSettings

    private let service: TaskService?
    private let isolated: Bool
    private let preferences: UserDefaults
    private let tokenStore: TokenStore
    private var tickTickClient: TickTickClient?
    private var pendingIDs = Set<UUID>()
    private var polling: Task<Void, Never>?
    private var connectionGeneration = 0
    private var focusTimer: Task<Void, Never>?
    private var permissionSetup: Task<Void, Never>?
    private var focusListeners = Set<AnyCancellable>()
    private let notifications: TaskNotifications
    private let distractionMonitor: DistractionMonitor
    private var started = false
    private var lifecycleReady = false

    init() {
        tokenStore = .defaultStore
        #if DEBUG
        preferences = UserDefaults(suiteName: "com.hawkeye2.mac.development") ?? .standard
        #else
        preferences = .standard
        #endif
        let arguments = ProcessInfo.processInfo.arguments
        let directory: String? = arguments.firstIndex(of: "--data-directory").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        } ?? Bundle.main.object(forInfoDictionaryKey: "HawkeyeDataDirectory") as? String
        isolated = directory != nil
        activity = ActivityLog(fileURL: directory.map {
            URL(fileURLWithPath: $0).appendingPathComponent("activity.log")
        } ?? ActivityLog.defaultURL)
        notifications = TaskNotifications(log: activity, effectsEnabled: !isolated)
        distractions = DistractionSettings(preferences: preferences, fileURL: directory.map {
            URL(fileURLWithPath: $0).appendingPathComponent("focus-policy.json")
        })
        permissions = FocusPermissions(effectsRequested: true, preferences: preferences, notifications: notifications,
                                       settings: distractions, isolated: isolated)
        let nativeMonitoring = MacDistractionEffects(permissions: permissions)
        distractionMonitor = DistractionMonitor(policy: distractions.policy,
            detector: DeterministicDistractionDetector(observations: nativeMonitoring), actions: nativeMonitoring, log: activity)
        do {
            let defaultStoreURL: URL
            #if DEBUG
            defaultStoreURL = TokenStore.developmentDirectory.appendingPathComponent("tasks.json")
            #else
            defaultStoreURL = try JSONTaskStore.defaultURL()
            #endif
            let storeURL = directory.map { URL(fileURLWithPath: $0).appendingPathComponent("tasks.json") } ?? defaultStoreURL
            var token: String?
            var credentialError: String?
            if !isolated {
                do { token = try tokenStore.read() }
                catch { credentialError = error.localizedDescription }
            }
            let projectID = isolated ? nil : preferences.string(forKey: "ticktick.projectID")
            let client = token.map { TickTickClient(token: $0) }
            service = try TaskService(store: JSONTaskStore(url: storeURL), client: client, projectID: projectID)
            tickTickClient = client
            connected = token != nil
            self.projectID = projectID ?? ""
            projectName = isolated ? "your selected list" : preferences.string(forKey: "ticktick.projectName") ?? "your selected list"
            ready = true
            if let credentialError { syncStatus = "Tasks are available locally. \(credentialError)" }
        } catch {
            service = nil
            self.error = "Could not open task storage. Your existing data was left intact. \(error.localizedDescription)"
            syncStatus = "Task storage unavailable. Restart after resolving the error."
        }
        installFocusListeners()
        activity.record("App", ready ? "Application started. Task storage ready." : "Application started. Task storage unavailable.")
        if let error { activity.record("Storage error", error) }
    }

    init(service: TaskService, client: TickTickClient, project: ProjectOption, preferences: UserDefaults,
         tokenStore: TokenStore = .defaultStore, monitorDetector: (any DistractionDetecting)? = nil,
         monitorActions: (any DistractionActions)? = nil) {
        self.service = service
        self.tokenStore = tokenStore
        tickTickClient = client
        self.preferences = preferences
        isolated = false
        connected = true
        projectID = project.id
        projectName = project.name
        ready = true
        activity = ActivityLog(fileURL: tokenStore.fileURL?.deletingLastPathComponent().appendingPathComponent("activity.log")
                               ?? ActivityLog.defaultURL)
        notifications = TaskNotifications(log: activity, effectsEnabled: false)
        distractions = DistractionSettings(preferences: preferences)
        permissions = FocusPermissions(effectsRequested: false, preferences: preferences, notifications: notifications, settings: distractions)
        let nativeMonitoring = MacDistractionEffects(permissions: permissions)
        distractionMonitor = DistractionMonitor(policy: distractions.policy,
            detector: monitorDetector ?? DeterministicDistractionDetector(observations: nativeMonitoring),
            actions: monitorActions ?? nativeMonitoring, log: activity)
        installFocusListeners()
    }

    deinit { polling?.cancel(); focusTimer?.cancel(); permissionSetup?.cancel() }

    var activeTask: TodoTask? { tasks.first { $0.id == activeTaskID } }
    func isActive(_ task: TodoTask) -> Bool { activeTaskID == task.id }
    func canPause(_ task: TodoTask) -> Bool {
        isActive(task) && userFocus.snooze == nil && !userFocus.snoozedTaskIDs.contains(task.id)
    }

    func updateMonitoringDetector(_ detector: any DistractionDetecting) {
        distractionMonitor.update(detector: detector)
    }

    private func installFocusListeners() {
        distractions.$policy.dropFirst().sink { [weak self] in self?.distractionMonitor.update(policy: $0) }.store(in: &focusListeners)
        focusEvents.sink { [weak self] event in
            guard let self else { return }
            switch event {
            case .activated(let task, _):
                self.activeTaskID = task.id
                self.activity.record("Focus", "Activated \(task.title).")
            case .deactivated(let task, let reason):
                self.activeTaskID = nil
                self.activity.record("Focus", "Deactivated \(task.title). Reason: \(reason.rawValue).")
            case .snoozed(let snooze):
                self.activity.record("Pause", "User paused until \(snooze.until.formatted(date: .omitted, time: .standard)). Task \(snooze.taskID).")
            case .snoozeEnded:
                self.activity.record("Pause", "User pause ended.")
            }
        }.store(in: &focusListeners)
        focusEvents.sink { [weak self] event in self?.notifications.receive(event) }.store(in: &focusListeners)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refreshFocus() } }.store(in: &focusListeners)
        NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemClockDidChange)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refreshFocus() } }.store(in: &focusListeners)
    }

    var tokenFileURL: URL? { tokenStore.fileURL }
    var tokenStorageDescription: String {
        tokenFileURL == nil ? "Personal access token saved in Keychain" : "Personal access token saved in development file"
    }
    var tokenStorageExplanation: String {
        tokenFileURL == nil ? "Hawkeye keeps it in your Mac's Keychain." : "This developer build saves it as plain text in your development token file."
    }

    var completedTasks: [TodoTask] {
        tasks.filter(\.completed).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var pendingTasks: [TodoTask] {
        tasks.filter { !$0.completed }.sorted {
            let lhs = $0.dueAt ?? .distantFuture
            let rhs = $1.dueAt ?? .distantFuture
            return lhs == rhs ? $0.createdAt < $1.createdAt : lhs < rhs
        }
    }

    func isPending(_ task: TodoTask) -> Bool { connected && pendingIDs.contains(task.id) }
    func isRemote(_ task: TodoTask) -> Bool { task.remote != nil }

    func start() async {
        guard !started, ready else { return }
        started = true
        lifecycleReady = true
        await refresh()
        permissionSetup = Task { [weak self] in await self?.permissions.start() }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let clock = ContinuousClock()
                let nextPoll = clock.now.advanced(by: .seconds(60))
                await self?.synchronize()
                do { try await clock.sleep(until: nextPoll) }
                catch { break }
            }
        }
    }

    func add(title: String, description: String, dueAt: Date?, duration: TimeInterval?, completion: @escaping (Bool) -> Void) {
        mutate({ service in
            _ = try await service.addTask(title: title, description: description, dueAt: dueAt, duration: duration)
        }, activity: "Created \(title).", completion: completion)
    }

    func update(_ task: TodoTask, title: String, description: String, dueAt: Date?, duration: TimeInterval?, completion: @escaping (Bool) -> Void) {
        var edited = task
        edited.title = title
        edited.taskDescription = description
        edited.dueAt = dueAt
        edited.duration = duration
        mutate({ service in _ = try await service.updateTask(edited) }, activity: "Updated \(title).", completion: completion)
    }

    func complete(_ id: UUID, completion: @escaping (Bool) -> Void = { _ in }) {
        let title = tasks.first { $0.id == id }?.title ?? id.uuidString
        mutate({ service in try await service.setCompleted(id: id, completed: true) }, activity: "Completed \(title).", completion: completion)
    }

    func reopen(_ id: UUID) {
        let title = tasks.first { $0.id == id }?.title ?? id.uuidString
        mutate({ service in try await service.setCompleted(id: id, completed: false) }, activity: "Reopened \(title).")
    }

    func pause(_ id: UUID, minutes: Int) {
        guard let service, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { apply(try await service.pause(id: id, minutes: minutes)) }
            catch {
                self.error = error.localizedDescription
                activity.record("Error", error.localizedDescription)
            }
        }
    }

    func deferTask(_ task: TodoTask, to start: Date, completion: @escaping (Bool) -> Void) {
        mutate({ service in try await service.deferTask(id: task.id, to: start) },
               activity: "Deferred \(task.title) to \(start.formatted()).", completion: completion)
    }

    func startNow(_ task: TodoTask, completion: @escaping (Bool) -> Void = { _ in }) {
        mutate({ service in
            let update = try await service.startNow(id: task.id)
            self.apply(update)
        }, activity: "Started now \(task.title).", completion: completion)
    }

    func checkToken(_ rawToken: String) async throws -> [ProjectOption] {
        let client = TickTickClient(token: rawToken.trimmingCharacters(in: .whitespacesAndNewlines))
        return try await projects(using: client)
    }

    func availableProjects() async throws -> [ProjectOption] {
        guard let client = tickTickClient else { throw AppFailure.notConnected }
        return try await projects(using: client)
    }

    private func projects(using client: TickTickClient) async throws -> [ProjectOption] {
        return try await client.projects()
            .filter { $0.closed != true && $0.kind != "NOTE" && $0.permission != "read" }
            .map { ProjectOption(id: $0.id, name: $0.name) }
    }

    func changeDestination(to project: ProjectOption) async throws {
        guard let service else { throw AppFailure.storageUnavailable }
        guard let client = tickTickClient else { throw AppFailure.notConnected }
        connectionGeneration += 1
        await service.configureSync(client: client, projectID: project.id)
        saveDestination(project)
    }

    private func saveDestination(_ project: ProjectOption) {
        preferences.set(project.id, forKey: "ticktick.projectID")
        preferences.set(project.name, forKey: "ticktick.projectName")
        projectID = project.id
        projectName = project.name
        activity.record("TickTick", "Default destination changed to \(project.name).")
    }

    func connect(token: String, project: ProjectOption) async throws {
        guard let service else { throw AppFailure.storageUnavailable }
        guard !isolated else { throw AppFailure.isolatedSession }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppFailure.emptyToken }
        try tokenStore.save(trimmed)
        let client = TickTickClient(token: trimmed)
        connectionGeneration += 1
        await service.configureSync(client: client, projectID: project.id)
        tickTickClient = client
        saveDestination(project)
        connected = true
        activity.record("TickTick", "Connected to TickTick.")
        syncStatus = "Connected. Preparing your tasks…"
        syncNow()
    }

    func disconnect() async throws {
        try tokenStore.remove()
        connectionGeneration += 1
        await service?.configureSync(client: nil, projectID: nil)
        tickTickClient = nil
        connected = false
        activity.record("TickTick", "Disconnected from TickTick.")
        preferences.removeObject(forKey: "ticktick.projectID")
        preferences.removeObject(forKey: "ticktick.projectName")
        projectID = ""
        projectName = "your selected list"
        syncStatus = "Disconnected. Your tasks are still saved locally."
        await refresh()
    }

    func syncNow() { Task { await synchronize() } }

    private func synchronize() async {
        guard connected, !syncing, let service else { return }
        let generation = connectionGeneration
        syncing = true
        syncStatus = "Syncing with TickTick…"
        activity.record("Sync", "TickTick sync started.")
        defer { syncing = false }
        do {
            let report = try await service.sync()
            guard generation == connectionGeneration else { return }
            await refresh()
            guard !report.skipped else { return }
            activity.record("Sync", "TickTick sync finished. Pushed \(report.pushed), pulled \(report.pulled).")
            for warning in report.warnings { activity.record("Sync warning", warning) }
            if !report.warnings.isEmpty {
                syncStatus = report.warnings.joined(separator: " ")
            } else {
                syncStatus = "Synced \(report.finishedAt.formatted(date: .omitted, time: .shortened)) · Every minute"
            }
        } catch {
            guard generation == connectionGeneration else { return }
            await refresh()
            syncStatus = "Sync paused · \(error.localizedDescription) Retrying next minute."
            activity.record("Sync error", error.localizedDescription)
        }
    }

    private func mutate(_ operation: @escaping (TaskService) async throws -> Void,
                        activity message: String,
                        completion: @escaping (Bool) -> Void = { _ in }) {
        guard let service else { completion(false); return }
        saving = true
        Task {
            do {
                try await operation(service)
                activity.record("Task", message)
                await refresh()
                saving = false
                completion(true)
                syncNow()
            } catch {
                saving = false
                self.error = error.localizedDescription
                activity.record("Error", error.localizedDescription)
                completion(false)
            }
        }
    }

    private func refresh() async {
        guard let service else { return }
        let state = await service.snapshot()
        tasks = state.tasks
        pendingIDs = Set(state.tasks.filter { state.isPending($0.id) }.map(\.id))
        now = Date()
        await refreshFocus()
    }

    private func refreshFocus() async {
        guard lifecycleReady, let service else { return }
        now = Date()
        do { apply(try await service.evaluateFocus(at: now)) }
        catch {
            self.error = "Could not update task activity. \(error.localizedDescription)"
            activity.record("Focus error", error.localizedDescription)
            scheduleFocusEvaluation(at: Date().addingTimeInterval(30))
        }
    }

    private func apply(_ update: TaskFocusUpdate) {
        userFocus = update.user
        distractionMonitor.update(activeTask: update.activeTask)
        for event in update.events { focusEvents.send(event) }
        scheduleFocusEvaluation(at: update.nextTransitionAt)
    }

    private func scheduleFocusEvaluation(at boundary: Date?) {
        focusTimer?.cancel()
        let delay = min(30, max(0.01, boundary?.timeIntervalSinceNow ?? 30))
        focusTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.refreshFocus()
        }
    }
}

private enum AppFailure: LocalizedError {
    case storageUnavailable, isolatedSession, emptyToken, notConnected
    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "Task storage is unavailable."
        case .isolatedSession: return "This isolated verification session does not save credentials. Open Hawkeye normally to connect TickTick."
        case .emptyToken: return "Enter a TickTick personal access token."
        case .notConnected: return "Connect TickTick before choosing a destination list."
        }
    }
}
