import Foundation

struct DeterministicDistractionDetector: DistractionDetecting {
    let method = MonitoringMethod.deterministic
    let pollingInterval = Duration.seconds(1)
    let observations: any DeterministicObservation
    var youtubeCategories: (any YouTubeCategoryResolving)? = nil

    func inspect(_ context: DetectionContext) async throws -> DetectionReport {
        try Task.checkCancellation()
        let application = context.foregroundApplication
        if context.policy.applications.contains(where: { $0.bundleID == application.bundleID }) {
            return .findings([.application(application)])
        }
        guard context.policy.inspectsBrowserTabs,
              let browser = context.policy.browsers.first(where: { $0.bundleID == application.bundleID }) else {
            return .findings([])
        }
        guard await observations.canAutomate(browser) else { return .unavailable(.browserAutomation(browser)) }
        do {
            try Task.checkCancellation()
            let tabs = try await observations.tabs(in: browser, application: application, before: context.deadline)
            try Task.checkCancellation()
            let websiteFindings: [DistractionFinding] = tabs.filter { context.policy.blockedDomain(for: $0.url) != nil }.map {
                .browserTab(application, browser, $0)
            }
            // Close explicit website blocks first, without waiting for category lookups.
            if !websiteFindings.isEmpty { return .findings(websiteFindings) }
            guard context.policy.youtubeCategories.isEnabled else { return .findings([]) }
            var findings: [DistractionFinding] = []
            let lookupDeadline = min(context.deadline.addingTimeInterval(-0.25), Date().addingTimeInterval(8))
            for tab in tabs where YouTubeLocation(tab.url).videoID != nil {
                try Task.checkCancellation()
                guard Date() < lookupDeadline else { break }
                let ids: Set<String>
                do {
                    ids = try await youtubeCategories?.categoryIDs(for: tab, in: browser,
                        application: application, before: lookupDeadline) ?? []
                } catch is CancellationError {
                    throw CancellationError()
                } catch YouTubeCategoryLookupError.staleTab {
                    continue
                } catch YouTubeCategoryLookupError.expired {
                    break
                } catch {
                    ids = []
                }
                try Task.checkCancellation()
                if context.policy.youtubeCategories.blocks(tab.url, categoryIDs: ids) {
                    findings.append(.youtubeCategoryTab(application, browser, tab, categoryIDs: ids))
                }
            }
            return .findings(findings)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(DetectionFailure(error))
        }
    }
}
