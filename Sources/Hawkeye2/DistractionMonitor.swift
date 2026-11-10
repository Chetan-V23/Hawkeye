import Foundation
import HawkeyeCore

@MainActor
final class DistractionMonitor {
    private enum SuppressionTarget: Equatable {
        case application(ForegroundApplication)
        case capability(ForegroundApplication, MonitoringMethod, DetectionCapability)
        case inspection(ForegroundApplication, MonitoringMethod)
        case tab(ForegroundApplication, ScriptableBrowser, BrowserTab)
        case observation(ForegroundApplication, MonitoringMethod)

        var application: ForegroundApplication {
            switch self {
            case .application(let application), .capability(let application, _, _), .inspection(let application, _),
                 .tab(let application, _, _), .observation(let application, _): return application
            }
        }
    }

    private enum SuppressionOutcome: Equatable {
        case terminationFailed, unavailable, skipped, observed
        case failure(DetectionFailure)
    }

    private struct SuppressedEvent: Equatable {
        let target: SuppressionTarget
        let outcome: SuppressionOutcome
    }

    private var policy: DistractionPolicy
    private var detector: any DistractionDetecting
    private let actions: any DistractionActions
    private let log: ActivityLog
    private let now: () -> Date
    private let intervalOverride: Duration?
    private var activity: MonitoringSession?
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var suppressed: SuppressedEvent?

    init(policy: DistractionPolicy = .standard, detector: any DistractionDetecting,
         actions: any DistractionActions, log: ActivityLog, interval: Duration? = nil,
         now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.detector = detector
        self.actions = actions
        self.log = log
        intervalOverride = interval
        self.now = now
    }

    deinit { loop?.cancel() }

    func update(session: MonitoringSession?) {
        guard activity != session else { return }
        activity = session
        restart()
    }

    func update(policy: DistractionPolicy) {
        guard self.policy != policy else { return }
        self.policy = policy
        restart()
    }

    func update(detector: any DistractionDetecting) {
        self.detector = detector
        restart()
    }

    private func restart() {
        generation += 1
        let previous = loop
        previous?.cancel()
        suppressed = nil
        guard activity?.isActive(at: now()) == true else { return }
        let generation = generation
        let interval = intervalOverride ?? detector.pollingInterval
        loop = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard self?.isCurrent(generation) == true else { return }
                await self?.inspect(generation: generation)
                do { try await Task.sleep(for: interval) }
                catch { return }
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && self.generation == generation && activity?.isActive(at: now()) == true
    }

    private func inspect(generation: Int) async {
        guard isCurrent(generation), let activity else { return }
        let deadline = activity.operationDeadline(at: now())
        guard let application = actions.frontmostApplication() else { suppressed = nil; return }
        if suppressed?.target.application != application { suppressed = nil }
        let context = DetectionContext(session: activity, policy: policy, deadline: deadline, foregroundApplication: application)
        let detector = detector
        let report: DetectionReport
        do {
            report = try await detector.inspect(context)
        } catch is CancellationError {
            return
        } catch {
            report = .failure(DetectionFailure(error))
        }
        guard now() < context.deadline, isCurrent(generation), actions.frontmostApplication() == application else { return }
        switch report {
        case .findings(let findings):
            await enforce(findings, context: context, method: detector.method, generation: generation)
        case .unavailable(let capability):
            recordUnavailable(capability, context: context, method: detector.method)
        case .failure(let failure):
            let action: String
            if detector.method == .deterministic,
               let browser = policy.browsers.first(where: { $0.bundleID == application.bundleID }) {
                action = "inspect tabs in \(browser.name)"
            } else { action = "inspect distractions with \(detector.method.name)" }
            recordFailure(failure, target: .inspection(application, detector.method), action: action, method: detector.method)
        }
    }

    private func enforce(_ findings: [DistractionFinding], context: DetectionContext,
                         method: MonitoringMethod, generation: Int) async {
        let application = context.foregroundApplication
        guard now() < context.deadline, isCurrent(generation), actions.frontmostApplication() == application else { return }
        if let blocked = policy.applications.first(where: { $0.bundleID == application.bundleID }),
           findings.contains(.application(application)) {
            let target = SuppressionTarget.application(application)
            let report = suppressed?.target != target
            if report {
                log.record("Focus detection", "Detected blocked app \(blocked.name).")
                log.record("Focus block", "Closing \(blocked.name).")
            }
            guard now() < context.deadline, isCurrent(generation), actions.frontmostApplication() == application else { return }
            if actions.terminate(application) {
                log.record("Focus block", "Force-quit request sent for \(blocked.name).")
                suppressed = nil
            } else {
                if report { log.record("Focus block", "Could not send force-quit request for \(blocked.name). Will retry while it is in front.") }
                suppressed = SuppressedEvent(target: target, outcome: .terminationFailed)
            }
            return
        }
        var failedTargetStillPresent = false
        var hasActionableTab = false
        if !policy.applications.contains(where: { $0.bundleID == application.bundleID }), policy.inspectsBrowserTabs,
           let browser = policy.browsers.first(where: { $0.bundleID == application.bundleID }) {
            let tabs = findings.compactMap { finding in
                authorizedTab(finding, application: application, browser: browser)
            }
            hasActionableTab = !tabs.isEmpty
            // Safari identifies tabs by position. Descending positions keep remaining observations valid after a close.
            for blocked in tabs.sorted(by: { $0.tab.windowID == $1.tab.windowID ? $0.tab.index > $1.tab.index : $0.tab.windowID > $1.tab.windowID }) {
                let tab = blocked.tab
                guard now() < context.deadline, isCurrent(generation), actions.frontmostApplication() == application else { return }
                guard actions.canAutomate(browser) else {
                    recordUnavailable(.browserAutomation(browser), context: context, method: method)
                    return
                }
                guard let activity else { continue }
                let domain = blocked.label
                let deadline = min(context.deadline, activity.operationDeadline(at: now()))
                let target = SuppressionTarget.tab(application, browser, tab)
                let report = suppressed?.target != target
                if !report { failedTargetStillPresent = true }
                if report {
                    log.record("Focus detection", "Detected \(blocked.description) in \(browser.name).")
                    log.record("Focus block", "Closing \(domain) tab in \(browser.name).")
                }
                guard now() < context.deadline, isCurrent(generation), actions.frontmostApplication() == application, actions.canAutomate(browser) else { return }
                do {
                    let sent = try await actions.close(tab, in: browser, application: application, before: deadline)
                    guard now() < context.deadline, isCurrent(generation) else { return }
                    let stillEligible = actions.frontmostApplication() == application && actions.canAutomate(browser)
                    if sent {
                        log.record("Focus block", "Close command sent for \(domain) tab in \(browser.name).")
                        suppressed = nil
                    } else {
                        if report { log.record("Focus block", "Skipped \(domain) tab in \(browser.name) after revalidation.") }
                        suppressed = SuppressedEvent(target: target, outcome: .skipped)
                        failedTargetStillPresent = true
                    }
                    guard stillEligible else { suppressed = nil; return }
                } catch is CancellationError {
                    return
                } catch {
                    guard now() < context.deadline, isCurrent(generation), actions.frontmostApplication() == application else { return }
                    recordFailure(DetectionFailure(error), target: target, action: "close \(domain) tab in \(browser.name)")
                    return
                }
            }
        }
        if !hasActionableTab, findings.contains(.possibleDistraction(application)) {
            let event = SuppressedEvent(target: .observation(application, method), outcome: .observed)
            if suppressed != event {
                log.record("Focus detection", "Possible distraction observed by \(method.name). No exact blocked target was identified.")
                suppressed = event
            }
            return
        }
        if !failedTargetStillPresent { suppressed = nil }
    }

    private func authorizedTab(_ finding: DistractionFinding, application: ForegroundApplication,
                               browser: ScriptableBrowser) -> (tab: BrowserTab, label: String, description: String)? {
        let foundApplication: ForegroundApplication, foundBrowser: ScriptableBrowser, tab: BrowserTab
        let label: String, description: String
        switch finding {
        case .browserTab(let app, let source, let foundTab):
            guard let domain = policy.blockedDomain(for: foundTab.url) else { return nil }
            (foundApplication, foundBrowser, tab) = (app, source, foundTab)
            label = domain
            description = "blocked website \(domain)"
        case .youtubeCategoryTab(let app, let source, let foundTab, let categoryIDs):
            guard policy.youtubeCategories.blocks(foundTab.url, categoryIDs: categoryIDs) else { return nil }
            (foundApplication, foundBrowser, tab) = (app, source, foundTab)
            label = "YouTube"
            description = categoryIDs.isEmpty ? "YouTube tab with an unavailable category"
                : "YouTube tab outside the category whitelist"
        default: return nil
        }
        guard foundApplication == application, foundBrowser == browser,
              !tab.windowID.isEmpty, tab.index >= 0,
              browser != .chrome || tab.tabID?.isEmpty == false else { return nil }
        return (tab, label, description)
    }

    private func recordUnavailable(_ capability: DetectionCapability, context: DetectionContext, method: MonitoringMethod) {
        let application = context.foregroundApplication
        let message: String
        switch capability {
        case .browserAutomation(let browser):
            guard policy.inspectsBrowserTabs, browser.bundleID == application.bundleID,
                  !policy.applications.contains(where: { $0.bundleID == application.bundleID }),
                  policy.browsers.contains(browser), !actions.canAutomate(browser) else { return }
            message = "Cannot inspect or close blocked website tabs in \(browser.name). Allow Automation access in Focus permissions."
        case .screenRecording:
            message = "\(method.name) monitoring is unavailable. Allow Screen Recording access in Focus permissions."
        case .accessibility:
            message = "\(method.name) monitoring is unavailable. Allow Accessibility access in Focus permissions."
        }
        let event = SuppressedEvent(target: .capability(application, method, capability), outcome: .unavailable)
        if suppressed != event { log.record("Focus block", message); suppressed = event }
    }

    private func recordFailure(_ failure: DetectionFailure, target: SuppressionTarget, action: String,
                               method: MonitoringMethod? = nil) {
        let reason: String
        if let method, method != .deterministic {
            switch failure {
            case .timedOut: reason = "Detection timed out."
            case .failed: reason = "Detection failed."
            case .responseTooLarge: reason = "Detection exceeded the response size limit."
            case .unavailable: reason = "Check access in Focus permissions."
            }
        } else {
            switch failure {
            case .timedOut: reason = "Browser command timed out."
            case .failed: reason = "Browser command failed."
            case .responseTooLarge: reason = "Browser response exceeded the size limit."
            case .unavailable: reason = "Check browser access in Focus permissions."
            }
        }
        let event = SuppressedEvent(target: target, outcome: .failure(failure))
        if suppressed != event { log.record("Focus block", "Could not \(action). \(reason)"); suppressed = event }
    }
}
