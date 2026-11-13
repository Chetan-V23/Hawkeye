import Foundation
import SwiftUI
import HawkeyeCore
import Combine
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tasks: [TodoTask] = []
    @Published private(set) var connected = false
    @Published private(set) var syncing = false
    @Published private(set) var saving = false
    @Published private(set) var ready = false
    @Published private(set) var projectName = "your selected list"
    @Published private(set) var projectID = ""
    @Published private(set) var syncStatus = "Connect a Third Party App in settings."
    @Published private(set) var connection: TaskConnection?
    @Published private(set) var uncertainNotionTasks: [TodoTask] = []
    @Published var error: String?
    @Published var now = Date()
    @Published var showSettings = false
    @Published var showFocusConfiguration = false
    @Published private(set) var activeTaskID: UUID?
    @Published private(set) var userFocus = UserFocusState()
    @Published private(set) var pomodoro = PomodoroTimer()
    let focusEvents = PassthroughSubject<TaskFocusEvent, Never>()
    let activity: ActivityLog
    let permissions: FocusPermissions
    let distractions: DistractionSettings

    private let service: TaskService?
    private let isolated: Bool
    private let preferences: UserDefaults
    private let pomodoroSettingsURL: URL?
    private let tokenStore: TokenStore
    private var tickTickClient: TickTickClient?
    private var syncProvider: (any TaskSyncProvider)?
    private let transport: any HTTPTransport
    private var syncTask: Task<Void, Never>?
    private var changingConnection = false
    private var pendingIDs = Set<UUID>()
    private var polling: Task<Void, Never>?
    private var connectionGeneration = 0
    private var focusTimer: Task<Void, Never>?
    private var pomodoroTick: Task<Void, Never>?
    private var monitoringTask: TodoTask?
    private var permissionSetup: Task<Void, Never>?
    private var focusListeners = Set<AnyCancellable>()
    private let notifications: TaskNotifications
    private let distractionMonitor: DistractionMonitor
    private let screenshotMonitor: ScreenshotMonitor?
    private let browserContentMonitor: BrowserContentMonitor?
    private var started = false
    private var lifecycleReady = false

    init(screenshotProcessors: [any ScreenshotProcessing] = ScreenshotPipeline.defaultProcessors) {
        tokenStore = .defaultStore
        transport = URLSessionTransport()
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
        pomodoroSettingsURL = directory.map { URL(fileURLWithPath: $0).appendingPathComponent("pomodoro.json") }
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
            detector: DeterministicDistractionDetector(observations: nativeMonitoring,
                youtubeCategories: YouTubeCategoryResolver(sourceReader: nativeMonitoring)), actions: nativeMonitoring, log: activity)
        screenshotMonitor = permissions.effectsEnabled
            ? ScreenshotMonitor(capturer: MacScreenshotCapture(effectsEnabled: true), log: activity,
                                policy: distractions.policy, processors: screenshotProcessors,
                                actions: MacScreenshotActions(permissions: permissions)) : nil
        browserContentMonitor = permissions.effectsEnabled
            ? BrowserContentMonitor(capturer: MacBrowserContentCapture(effectsEnabled: true), log: activity) : nil
        do {
            let defaultStoreURL: URL
            #if DEBUG
            defaultStoreURL = TokenStore.developmentDirectory.appendingPathComponent("tasks.json")
            #else
            defaultStoreURL = try JSONTaskStore.defaultURL()
            #endif
            let storeURL = directory.map { URL(fileURLWithPath: $0).appendingPathComponent("tasks.json") } ?? defaultStoreURL
            let saved = isolated ? nil : TaskConnection.load(from: preferences)
            var token: String?
            var credentialError: String?
            if let saved {
                do { token = try tokenStore.scoped(to: saved.provider).read() }
                catch { credentialError = error.localizedDescription }
            }
            let provider: (any TaskSyncProvider)?
            if let token, let saved { provider = try Self.provider(for: saved, token: token, transport: transport) }
            else { provider = nil }
            service = try TaskService(store: JSONTaskStore(url: storeURL), provider: provider, destinationID: saved?.destinationID)
            syncProvider = provider
            connection = saved
            connected = provider != nil
            self.projectID = saved?.destinationID ?? ""
            projectName = saved?.destinationName ?? "your selected destination"
            ready = true
            if let credentialError { syncStatus = "Tasks are available locally. \(credentialError)" }
        } catch {
            service = nil
            self.error = "Could not open task storage. Your existing data was left intact. \(error.localizedDescription)"
            syncStatus = "Task storage unavailable. Restart after resolving the error."
        }
        restorePomodoroConfiguration()
        installFocusListeners()
        activity.record("App", ready ? "Application started. Task storage ready." : "Application started. Task storage unavailable.")
        if let error { activity.record("Storage error", error) }
    }

    init(service: TaskService, client: TickTickClient, project: ProjectOption, preferences: UserDefaults,
         tokenStore: TokenStore = .defaultStore, monitorDetector: (any DistractionDetecting)? = nil,
         monitorActions: (any DistractionActions)? = nil, screenshotCapturer: (any ScreenshotCapturing)? = nil,
         screenshotInterval: Duration = .seconds(60),
         screenshotProcessors: [any ScreenshotProcessing] = ScreenshotPipeline.defaultProcessors,
         screenshotActions: (any ScreenshotActions)? = nil,
         browserContentCapturer: (any BrowserContentCapturing)? = nil,
         browserContentInterval: Duration = .seconds(60),
         transport: any HTTPTransport = URLSessionTransport()) {
        self.service = service
        self.tokenStore = tokenStore
        self.transport = transport
        tickTickClient = client
        syncProvider = TickTickTaskProvider(client: client)
        connection = TaskConnection(provider: .ticktick, destinationID: project.id, destinationName: project.name, notionMapping: nil)
        self.preferences = preferences
        pomodoroSettingsURL = nil
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
            detector: monitorDetector ?? DeterministicDistractionDetector(observations: nativeMonitoring,
                youtubeCategories: YouTubeCategoryResolver(sourceReader: nativeMonitoring)),
            actions: monitorActions ?? nativeMonitoring, log: activity)
        if let screenshotCapturer {
            screenshotMonitor = ScreenshotMonitor(capturer: screenshotCapturer, log: activity, interval: screenshotInterval,
                                                  policy: distractions.policy, processors: screenshotProcessors,
                                                  actions: screenshotActions)
        } else { screenshotMonitor = nil }
        if let browserContentCapturer {
            browserContentMonitor = BrowserContentMonitor(capturer: browserContentCapturer, log: activity, interval: browserContentInterval)
        } else { browserContentMonitor = nil }
        restorePomodoroConfiguration()
        installFocusListeners()
    }

    deinit { syncTask?.cancel(); polling?.cancel(); focusTimer?.cancel(); pomodoroTick?.cancel(); permissionSetup?.cancel() }

    var activeTask: TodoTask? { tasks.first { $0.id == activeTaskID } }
    var isMonitoringActive: Bool { monitoringSession?.isActive(at: now) == true }

    private var monitoringSession: MonitoringSession? {
        if let session = pomodoro.session { return .pomodoro(session) }
        return monitoringTask.map(MonitoringSession.task)
    }

    func configurePomodoro(_ configuration: PomodoroConfiguration) {
        if let pomodoroSettingsURL {
            do {
                let data = try JSONSerialization.data(withJSONObject: ["focusMinutes": configuration.focusMinutes,
                                                                       "breakMinutes": configuration.breakMinutes])
                try FileManager.default.createDirectory(at: pomodoroSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: pomodoroSettingsURL, options: .atomic)
            } catch {
                self.error = "Could not save Pomodoro durations. \(error.localizedDescription)"
                return
            }
        } else {
            preferences.set(configuration.focusMinutes, forKey: "pomodoro.focusMinutes")
            preferences.set(configuration.breakMinutes, forKey: "pomodoro.breakMinutes")
        }
        pomodoro.configure(configuration)
    }

    func startPomodoro() {
        guard pomodoro.session == nil else { return }
        now = Date()
        pomodoro.start(at: now)
        updateMonitoring()
        activity.record("Pomodoro", "Started focus. Monitoring active.")
        pomodoroTick = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self = self else { return }
                self.advancePomodoro(at: Date())
            }
        }
    }

    func stopPomodoro() {
        guard pomodoro.session != nil else { return }
        pomodoroTick?.cancel()
        pomodoroTick = nil
        pomodoro.stop()
        now = Date()
        notifications.cancelPomodoro()
        updateMonitoring()
        activity.record("Pomodoro", "Timer stopped.")
    }

    func advancePomodoro(at date: Date) {
        guard pomodoro.session != nil else { return }
        now = date
        if let interval = pomodoro.advance(at: date), let session = pomodoro.session {
            let message = interval.phase == .breakTime
                ? "Break started. Drink a glass of water. Monitoring remains active."
                : "Break finished. Focus started. Monitoring remains active."
            activity.record("Pomodoro", message)
            notifications.receive(pomodoro: interval, sessionID: session.id)
        }
    }

    private func restorePomodoroConfiguration() {
        if let pomodoroSettingsURL {
            if let data = try? Data(contentsOf: pomodoroSettingsURL),
               let values = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
               let focus = values["focusMinutes"], let rest = values["breakMinutes"],
               let configuration = PomodoroConfiguration(focusMinutes: focus, breakMinutes: rest) {
                pomodoro.configure(configuration)
            }
            return
        }
        let focus = preferences.object(forKey: "pomodoro.focusMinutes") as? Int ?? 25
        let rest = preferences.object(forKey: "pomodoro.breakMinutes") as? Int ?? 5
        pomodoro.configure(PomodoroConfiguration(focusMinutes: focus, breakMinutes: rest) ?? .standard)
    }

    private func updateMonitoring() {
        distractionMonitor.update(session: monitoringSession)
        screenshotMonitor?.update(session: monitoringSession)
        browserContentMonitor?.update(session: monitoringSession)
    }
    func isActive(_ task: TodoTask) -> Bool { activeTaskID == task.id }
    func canPause(_ task: TodoTask) -> Bool {
        isActive(task) && userFocus.snooze == nil && !userFocus.snoozedTaskIDs.contains(task.id)
    }

    func updateMonitoringDetector(_ detector: any DistractionDetecting) {
        distractionMonitor.update(detector: detector)
    }

    private func installFocusListeners() {
        distractions.$policy.dropFirst().sink { [weak self] policy in
            self?.distractionMonitor.update(policy: policy)
            self?.screenshotMonitor?.update(policy: policy)
        }.store(in: &focusListeners)
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
            .sink { [weak self] _ in self?.refreshClocks() }.store(in: &focusListeners)
        NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemClockDidChange)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshClocks() }.store(in: &focusListeners)
    }

    private func refreshClocks() {
        advancePomodoro(at: Date())
        Task { [weak self] in await self?.refreshFocus() }
    }

    var providerID: TaskProviderID { connection?.provider ?? .ticktick }
    var providerName: String { providerID.displayName }
    var tokenFileURL: URL? { tokenStore.scoped(to: providerID).fileURL }
    func tokenFileURL(for provider: TaskProviderID) -> URL? { tokenStore.scoped(to: provider).fileURL }
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

    func start(requestPermissions: Bool = true) async {
        guard !started, ready else { return }
        started = true
        lifecycleReady = true
        await refresh()
        if requestPermissions { startInteractivePermissions() }
        else { await permissions.refresh() }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let clock = ContinuousClock()
                let nextPoll = clock.now.advanced(by: .seconds(60))
                self?.syncNow()
                await self?.syncTask?.value
                do { try await clock.sleep(until: nextPoll) }
                catch { break }
            }
        }
    }

    func startInteractivePermissions() {
        guard permissionSetup == nil else { return }
        permissionSetup = Task { [weak self] in await self?.permissions.start() }
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

    private static func provider(for connection: TaskConnection, token: String,
                                 transport: any HTTPTransport) throws -> any TaskSyncProvider {
        switch connection.provider {
        case .ticktick: return TickTickTaskProvider(client: TickTickClient(token: token, transport: transport))
        case .todoist: return TodoistTaskProvider(client: TodoistClient(token: token, transport: transport))
        case .notion:
            guard let mapping = connection.notionMapping else { throw TaskProviderError.invalidMapping }
            return NotionTaskProvider(client: NotionClient(token: token, transport: transport), mapping: mapping)
        }
    }

    func checkToken(_ rawToken: String) async throws -> [ProjectOption] {
        try await discover(provider: .ticktick, token: rawToken).destinations
    }

    func availableProjects() async throws -> [ProjectOption] {
        if let client = tickTickClient {
            return try await client.projects().filter { $0.closed != true && $0.kind != "NOTE" && $0.permission != "read" }
                .map { TaskDestination(id: $0.id, name: $0.name) }
        }
        return try await discover(provider: providerID).destinations
    }

    func discover(provider: TaskProviderID, token rawToken: String? = nil) async throws -> ConnectionCatalog {
        let token = try rawToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (provider == providerID && connected ? tokenStore.scoped(to: provider).read() : nil)
        if rawToken == nil, provider == .ticktick, let client = tickTickClient {
            return ConnectionCatalog(destinations: try await client.projects()
                .filter { $0.closed != true && $0.kind != "NOTE" && $0.permission != "read" }
                .map { TaskDestination(id: $0.id, name: $0.name) })
        }
        guard let token, !token.isEmpty else { throw AppFailure.emptyToken }
        switch provider {
        case .ticktick:
            let projects = try await TickTickClient(token: token, transport: transport).projects()
            return ConnectionCatalog(destinations: projects.filter { $0.closed != true && $0.kind != "NOTE" && $0.permission != "read" }
                .map { TaskDestination(id: $0.id, name: $0.name) })
        case .todoist:
            return ConnectionCatalog(destinations: try await TodoistClient(token: token, transport: transport).projects())
        case .notion:
            let sources = try await NotionClient(token: token, transport: transport).dataSources()
            return ConnectionCatalog(destinations: sources.map { TaskDestination(id: $0.id, name: $0.name) }, notionDataSources: sources)
        }
    }

    func changeDestination(to project: ProjectOption) async throws {
        guard !changingConnection else { throw AppFailure.connectionBusy }
        guard let service, let syncProvider, var saved = connection else { throw AppFailure.notConnected }
        changingConnection = true
        defer { changingConnection = false }
        saved = TaskConnection(provider: saved.provider, destinationID: project.id, destinationName: project.name,
                               notionMapping: saved.notionMapping)
        invalidateSync()
        await service.configureSync(provider: syncProvider, destinationID: project.id)
        saveConnection(saved)
    }

    private func saveConnection(_ value: TaskConnection) {
        value.save(to: preferences)
        connection = value
        projectID = value.destinationID
        projectName = value.destinationName
        activity.record("Third Party App", "Connected to \(value.provider.displayName), destination \(value.destinationName).")
    }

    func connect(token: String, project: ProjectOption) async throws {
        try await connect(provider: .ticktick, token: token, destination: project)
    }

    func connect(provider: TaskProviderID, token rawToken: String?, destination: TaskDestination,
                 notionMapping: NotionTaskMapping? = nil) async throws {
        guard let service else { throw AppFailure.storageUnavailable }
        guard !isolated else { throw AppFailure.isolatedSession }
        guard !changingConnection else { throw AppFailure.connectionBusy }
        changingConnection = true
        defer { changingConnection = false }
        let nextStore = tokenStore.scoped(to: provider)
        let previousNextToken = try nextStore.read()
        let trimmed = rawToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? previousNextToken
        guard let trimmed, !trimmed.isEmpty else { throw AppFailure.emptyToken }
        let catalog = try await discover(provider: provider, token: trimmed)
        guard catalog.destinations.contains(where: { $0.id == destination.id }) else { throw AppFailure.invalidDestination }
        if provider == .notion {
            guard let source = catalog.notionDataSources.first(where: { $0.id == destination.id }), let notionMapping else {
                throw TaskProviderError.invalidMapping
            }
            try notionMapping.validate(in: source)
        }
        let next = TaskConnection(provider: provider, destinationID: destination.id, destinationName: destination.name,
                                  notionMapping: notionMapping)
        let nextProvider = try Self.provider(for: next, token: trimmed, transport: transport)
        let previous = connection
        let previousProvider = syncProvider
        let previousStore = tokenStore.scoped(to: providerID)
        let previousToken = try previousStore.read()
        let detach = previous != nil && (previous?.provider != provider
            || (provider == .notion && previous?.destinationID != next.destinationID))
        try nextStore.save(trimmed)
        do {
            if previous?.provider != provider { try previousStore.remove() }
            invalidateSync()
            if detach { try await service.discardConnectionData() }
        } catch {
            if let previousNextToken { try? nextStore.save(previousNextToken) } else { try? nextStore.remove() }
            if let previousToken { try? previousStore.save(previousToken) }
            await service.configureSync(provider: previousProvider, destinationID: previous?.destinationID)
            throw error
        }
        await service.configureSync(provider: nextProvider, destinationID: destination.id)
        syncProvider = nextProvider
        tickTickClient = nil
        saveConnection(next)
        connected = true
        syncStatus = "Connected to \(provider.displayName). Preparing your tasks…"
        await refresh()
        syncNow()
    }

    func disconnect() async throws {
        guard !changingConnection else { throw AppFailure.connectionBusy }
        changingConnection = true
        defer { changingConnection = false }
        let store = tokenStore.scoped(to: providerID)
        let previousToken = try store.read()
        try store.remove()
        invalidateSync()
        do { try await service?.discardConnectionData() }
        catch {
            if let previousToken { try? store.save(previousToken) }
            await service?.configureSync(provider: syncProvider, destinationID: connection?.destinationID)
            throw error
        }
        await service?.configureSync(provider: nil, destinationID: nil)
        tickTickClient = nil
        syncProvider = nil
        connected = false
        connection = nil
        activity.record("Third Party App", "Disconnected. Saved tasks retained locally.")
        preferences.removeObject(forKey: TaskConnection.preferenceKey)
        preferences.removeObject(forKey: "ticktick.projectID")
        preferences.removeObject(forKey: "ticktick.projectName")
        projectID = ""
        projectName = "your selected destination"
        syncStatus = "Disconnected. Your tasks are still saved locally."
        await refresh()
    }

    private func invalidateSync() {
        connectionGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        syncing = false
    }

    @discardableResult
    func syncNow() -> Task<Void, Never>? {
        guard syncTask == nil else { return syncTask }
        let generation = connectionGeneration
        syncTask = Task { [weak self] in
            await self?.synchronize()
            if self?.connectionGeneration == generation { self?.syncTask = nil }
        }
        return syncTask
    }

    private func synchronize() async {
        guard connected, !syncing, !changingConnection, let service else { return }
        let generation = connectionGeneration
        let name = providerName
        syncing = true
        syncStatus = "Syncing with \(name)…"
        activity.record("Sync", "\(name) sync started.")
        defer { if generation == connectionGeneration { syncing = false } }
        do {
            let report = try await service.sync()
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            await refresh(expectedConnectionGeneration: generation)
            guard generation == connectionGeneration, !report.skipped else { return }
            activity.record("Sync", "\(name) sync finished. Pushed \(report.pushed), pulled \(report.pulled).")
            for warning in report.warnings { activity.record("Sync warning", warning) }
            syncStatus = report.warnings.isEmpty
                ? "Synced \(report.finishedAt.formatted(date: .omitted, time: .shortened)) · Every minute"
                : report.warnings.joined(separator: " ")
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            await refresh(expectedConnectionGeneration: generation)
            guard generation == connectionGeneration else { return }
            syncStatus = "Sync paused · \(error.localizedDescription) Retrying next minute."
            activity.record("Sync error", error.localizedDescription)
        }
    }

    func retryNotionCreation(_ taskID: UUID) async throws {
        try await service?.retryUncertainCreation(taskID: taskID)
        await refresh()
        syncNow()
    }

    func attachNotionCreation(_ taskID: UUID, pageID: String) async throws {
        try await service?.attachUncertainCreation(taskID: taskID, pageID: pageID)
        await refresh()
        syncNow()
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

    private func refresh(expectedConnectionGeneration: Int? = nil) async {
        guard let service else { return }
        let state = await service.snapshot()
        let uncertainTasks = await service.uncertainNotionCreations()
        if let expectedConnectionGeneration, expectedConnectionGeneration != connectionGeneration { return }
        tasks = state.tasks
        uncertainNotionTasks = uncertainTasks
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
        monitoringTask = update.activeTask
        updateMonitoring()
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
    case storageUnavailable, isolatedSession, emptyToken, notConnected, invalidDestination, connectionBusy
    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "Task storage is unavailable."
        case .isolatedSession: return "This isolated verification session does not save credentials. Open Hawkeye normally to connect an app."
        case .emptyToken: return "Enter a personal access token."
        case .notConnected: return "Connect a Third Party App before choosing a destination."
        case .invalidDestination: return "The selected destination is no longer available. Refresh and choose another."
        case .connectionBusy: return "A connection change is already in progress."
        }
    }
}
