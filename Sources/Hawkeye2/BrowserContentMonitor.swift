import Foundation

@MainActor
final class BrowserContentMonitor {
    private struct Run {
        let token: UUID
        let work: Task<Void, Never>
    }

    private let capturer: any BrowserContentCapturing
    private let log: ActivityLog
    private let interval: Duration
    private let now: () -> Date
    private var activity: MonitoringSession?
    private var run: Run?
    private var finishing: Task<Void, Never>?
    private var revision = 0
    private var lastFailure: BrowserContentFailure?

    init(capturer: any BrowserContentCapturing, log: ActivityLog, interval: Duration = .seconds(60),
         now: @escaping () -> Date = Date.init) {
        self.capturer = capturer
        self.log = log
        self.interval = interval
        self.now = now
    }

    deinit { run?.work.cancel(); finishing?.cancel() }

    func update(session activity: MonitoringSession?) {
        let sameOccurrence = activity?.id == self.activity?.id && activity?.startedAt == self.activity?.startedAt
        if self.activity != activity { revision += 1 }
        self.activity = activity
        if activity?.isActive(at: now()) == true, sameOccurrence, run != nil { return }
        if let run {
            run.work.cancel()
            finishing = run.work
            self.run = nil
        }
        lastFailure = nil
        guard activity?.isActive(at: now()) == true else { return }
        let previous = finishing
        finishing = nil
        let token = UUID()
        let interval = interval
        let work = Task { [weak self] in
            defer { self?.finish(token) }
            await previous?.value
            while !Task.isCancelled {
                guard self?.isCurrent(token) == true else { return }
                await self?.sample(token)
                do { try await Task.sleep(for: interval) }
                catch { return }
            }
        }
        run = Run(token: token, work: work)
    }

    private func isCurrent(_ token: UUID) -> Bool {
        !Task.isCancelled && run?.token == token && activity?.isActive(at: now()) == true
    }

    private func finish(_ token: UUID) {
        if run?.token == token { run = nil }
    }

    private func eligible(_ token: UUID, revision: Int, deadline: Date) -> Bool {
        guard isCurrent(token), self.revision == revision, let activity else { return false }
        return now() < min(deadline, activity.operationDeadline(at: now()))
    }

    private func sample(_ token: UUID) async {
        guard isCurrent(token), let activity else { return }
        let revision = revision
        let sessionDeadline = activity.operationDeadline(at: now())
        let deadline = min(sessionDeadline, now().addingTimeInterval(4))
        do {
            let snapshot = try await capturer.capture(before: deadline)
            guard eligible(token, revision: revision, deadline: deadline) else { return }
            guard let snapshot else { lastFailure = nil; return }
            guard activity.isActive(at: snapshot.capturedAt), snapshot.capturedAt < deadline,
                  let current = self.activity, snapshot.capturedAt < current.operationDeadline(at: now()) else { return }
            try log.recordBrowserContent(snapshot, session: activity)
            lastFailure = nil
        } catch is CancellationError {
        } catch {
            guard eligible(token, revision: revision, deadline: sessionDeadline) else { return }
            let failure = error as? BrowserContentFailure ?? .captureFailed
            if lastFailure != failure {
                log.record("Browser content", failure.message)
                lastFailure = failure
            }
        }
    }
}
