import Foundation

struct DeterministicDistractionDetector: DistractionDetecting {
    let method = MonitoringMethod.deterministic
    let pollingInterval = Duration.seconds(1)
    let observations: any DeterministicObservation

    func inspect(_ context: DetectionContext) async throws -> DetectionReport {
        try Task.checkCancellation()
        let application = context.foregroundApplication
        if context.policy.applications.contains(where: { $0.bundleID == application.bundleID }) {
            return .findings([.application(application)])
        }
        guard !context.policy.websiteDomains.isEmpty,
              let browser = context.policy.browsers.first(where: { $0.bundleID == application.bundleID }) else {
            return .findings([])
        }
        guard await observations.canAutomate(browser) else { return .unavailable(.browserAutomation(browser)) }
        do {
            try Task.checkCancellation()
            let tabs = try await observations.tabs(in: browser, application: application, before: context.deadline)
            try Task.checkCancellation()
            return .findings(tabs.filter { context.policy.blockedDomain(for: $0.url) != nil }.map {
                .browserTab(application, browser, $0)
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(DetectionFailure(error))
        }
    }
}
