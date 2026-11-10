import XCTest
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class YouTubeCategoryTests: XCTestCase {
    private let application = ForegroundApplication(bundleID: "com.apple.Safari", processID: 100)
    private let videoID = "abcdefghijk"

    func testCatalogDefaultsAndAmbiguousCategoryNames() {
        XCTAssertEqual(YouTubeCategory.all.count, 32)
        XCTAssertEqual(Set(YouTubeCategory.all.map(\.id)).count, 32)
        XCTAssertEqual(YouTubeCategory.whitelisted(in: ["27"]).map(\.name), ["Education"])
        let names = YouTubeCategory.choices.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(DistractionPolicy.standard.youtubeCategories.isEnabled)
        XCTAssertEqual(DistractionPolicy.standard.youtubeCategories.whitelist, ["27"])
        let comedy = YouTubeCategory.matchingIDs(for: "Comedy")
        XCTAssertEqual(comedy, ["23", "34"])
        XCTAssertTrue(YouTubeCategoryPolicy(isEnabled: true, whitelist: ["23"]).blocks(videoURL, categoryIDs: comedy))
        XCTAssertFalse(YouTubeCategoryPolicy(isEnabled: true, whitelist: ["23", "34"]).blocks(videoURL, categoryIDs: comedy))
    }

    func testOldSavedPolicyLoadsWithCategoryFilteringDisabled() throws {
        let data = Data(#"{"applications":[],"websiteDomains":["example.com"]}"#.utf8)
        let oldPolicy = try JSONDecoder().decode(DistractionPolicy.self, from: data)
        XCTAssertEqual(oldPolicy.websiteDomains, ["example.com"])
        XCTAssertFalse(oldPolicy.youtubeCategories.isEnabled)
        XCTAssertEqual(oldPolicy.youtubeCategories.whitelist, ["27"])
    }

    func testOneComedyChoiceAddsAndRemovesBothInternalIDs() throws {
        let settings = DistractionSettings(preferences: try makePreferences())
        let comedy = try XCTUnwrap(YouTubeCategory.choices.first { $0.name == "Comedy" })
        try settings.addYouTubeCategory(comedy)
        XCTAssertTrue(Set(["23", "34"]).isSubset(of: Set(settings.policy.youtubeCategories.whitelist)))
        XCTAssertEqual(YouTubeCategory.whitelisted(in: settings.policy.youtubeCategories.whitelist).map(\.name), ["Comedy", "Education"])
        XCTAssertEqual(YouTubeCategory.whitelisted(in: ["34"]).map(\.name), ["Comedy"])
        try settings.removeYouTubeCategory(comedy.id)
        XCTAssertEqual(settings.policy.youtubeCategories.whitelist, ["27"])
    }

    func testWhitelistPersistsAndEveryOtherSettingsEditPreservesIt() throws {
        let preferences = try makePreferences()
        let settings = DistractionSettings(preferences: preferences)
        try settings.setYouTubeCategoriesEnabled(true)
        let music = try XCTUnwrap(YouTubeCategory.all.first { $0.id == "10" })
        try settings.addYouTubeCategory(music)
        try settings.addYouTubeCategory(music)
        try settings.removeYouTubeCategory("27")
        let expected = YouTubeCategoryPolicy(isEnabled: true, whitelist: ["10"])
        let custom = BlockedApplication(bundleID: "test.example.game", name: "Game")
        try settings.addApplication(custom)
        XCTAssertEqual(settings.policy.youtubeCategories, expected)
        try settings.removeApplication(custom)
        XCTAssertEqual(settings.policy.youtubeCategories, expected)
        try settings.addDomain("example.com")
        XCTAssertEqual(settings.policy.youtubeCategories, expected)
        try settings.removeDomain("example.com")
        XCTAssertEqual(DistractionSettings(preferences: preferences).policy.youtubeCategories, expected)
        try settings.setYouTubeCategoriesEnabled(false)
        XCTAssertEqual(settings.policy.youtubeCategories.whitelist, ["10"])
        try settings.removeYouTubeCategory("10")
        let reloaded = DistractionSettings(preferences: preferences)
        XCTAssertEqual(reloaded.policy.youtubeCategories.whitelist, [])
        XCTAssertFalse(reloaded.policy.youtubeCategories.isEnabled)
    }

    func testYouTubeURLFormsAndImpostorHosts() {
        for url in [videoURL, "https://m.youtube.com/watch?v=\(videoID)&x=1", "https://youtu.be/\(videoID)",
                    "https://www.youtube.com/shorts/\(videoID)", "https://youtube.com/live/\(videoID)",
                    "https://youtube-nocookie.com/embed/\(videoID)", "https://YOUTUBE.COM./watch?v=\(videoID)"] {
            XCTAssertTrue(YouTubeLocation(url).isYouTube, url)
            XCTAssertEqual(YouTubeLocation(url).videoID, videoID, url)
        }
        for url in ["https://notyoutube.com/watch?v=\(videoID)", "https://youtube.com.evil.com/watch?v=\(videoID)",
                    "https://youtube.com@example.org/", "https://example.org/?next=youtube.com", "file://youtube.com/watch"] {
            XCTAssertFalse(YouTubeLocation(url).isYouTube, url)
        }
        XCTAssertNil(YouTubeLocation("https://youtube.com/watch?v=bad").videoID)
        XCTAssertTrue(YouTubeLocation("https://youtube.com/").isYouTube)
        XCTAssertNil(YouTubeLocation("https://youtube.com/").videoID)
    }

    func testParserRequiresMatchingVideoIDAndRecognizedCategory() throws {
        XCTAssertEqual(try YouTubeCategoryResolver.categoryIDs(in: html("Education"), videoID: videoID), ["27"])
        XCTAssertEqual(try YouTubeCategoryResolver.categoryIDs(in: html("Comedy"), videoID: videoID), ["23", "34"])
        for source in [html("Education", id: "differentID"), html("Unknown category"), "<html>consent</html>",
                       "ytInitialPlayerResponse = {broken", "ytInitialPlayerResponse = null;"] {
            XCTAssertThrowsError(try YouTubeCategoryResolver.categoryIDs(in: source, videoID: videoID))
        }
    }

    func testBrowserSourceIsFirstAndSuccessSkipsNetworkThenCaches() async throws {
        let source = CategorySource(html: html("Education"))
        let network = CategoryNetwork(html: html("Music"))
        let resolver = YouTubeCategoryResolver(sourceReader: source, fetchHTML: { url, _ in try await network.fetch(url) })
        let first = try await resolver.categoryIDs(for: tab(), in: .safari, application: application, before: deadline)
        let second = try await resolver.categoryIDs(for: tab(), in: .safari, application: application, before: deadline)
        XCTAssertEqual(first, ["27"])
        XCTAssertEqual(second, ["27"])
        XCTAssertEqual(source.reads, 1)
        let requests = await network.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSourceFailureOrStaleMetadataFallsBackToYouTubeLookup() async throws {
        for sourceHTML in [nil, "unavailable", html("Music", id: "differentID")] {
            let source = CategorySource(html: sourceHTML)
            let network = CategoryNetwork(html: html("Education"))
            let resolver = YouTubeCategoryResolver(sourceReader: source, fetchHTML: { url, _ in try await network.fetch(url) })
            let ids = try await resolver.categoryIDs(for: tab(), in: .safari, application: application, before: deadline)
            XCTAssertEqual(ids, ["27"])
            XCTAssertEqual(source.reads, 1)
            let requests = await network.requests
            XCTAssertEqual(requests.map(\.absoluteString), ["https://www.youtube.com/watch?v=\(videoID)&hl=en"])
        }
    }

    func testFailedFallbackClosesButStaleTabAndCancellationDoNotBecomeFailures() async throws {
        let source = CategorySource(html: nil)
        let network = CategoryNetwork(html: nil)
        let resolver = YouTubeCategoryResolver(sourceReader: source, fetchHTML: { url, _ in try await network.fetch(url) })
        let ids = try await resolver.categoryIDs(for: tab(), in: .safari, application: application, before: deadline)
        XCTAssertTrue(ids.isEmpty)
        let stale = CategorySource(html: nil)
        stale.failure = YouTubeCategoryLookupError.staleTab
        let staleResolver = YouTubeCategoryResolver(sourceReader: stale, fetchHTML: { url, _ in try await network.fetch(url) })
        do {
            _ = try await staleResolver.categoryIDs(for: tab(), in: .safari, application: application, before: deadline)
            XCTFail("A stale tab should abort lookup")
        } catch YouTubeCategoryLookupError.staleTab {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await network.requests
        XCTAssertEqual(requests.count, 1)
        let cancelled = Task {
            try Task.checkCancellation()
            return try await resolver.categoryIDs(for: tab(), in: .safari, application: application, before: deadline)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation should propagate") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDisabledDoesNotInspectTabsOrResolveCategories() async throws {
        let effects = CategoryEffects(application: application, tabs: [tab()])
        let resolver = CategoryResolver(ids: ["10"])
        let detector = DeterministicDistractionDetector(observations: effects, youtubeCategories: resolver)
        let context = context(policy: .init(applications: [], websiteDomains: []))
        let report = try await detector.inspect(context)
        XCTAssertEqual(report, .findings([]))
        XCTAssertEqual(effects.reads, 0)
        let calls = await resolver.calls
        XCTAssertEqual(calls, 0)
    }

    func testBrowsingPagesStayOpenWithoutCategoryLookup() async throws {
        let urls = ["https://www.youtube.com/", "https://www.youtube.com/results?search_query=swift",
                    "https://www.youtube.com/@education", "https://www.youtube.com/playlist?list=example",
                    "https://www.youtube.com/feed/subscriptions", "https://www.youtube.com/watch"]
        var policy = enabledPolicy
        policy.youtubeCategories.whitelist = []
        let effects = CategoryEffects(application: application, tabs: urls.enumerated().map { tab(index: $0.offset, url: $0.element) })
        let resolver = CategoryResolver()
        let detector = DeterministicDistractionDetector(observations: effects, youtubeCategories: resolver)
        let report = try await detector.inspect(context(policy: policy))
        XCTAssertEqual(report, .findings([]))
        let calls = await resolver.calls
        XCTAssertEqual(calls, 0)
        for url in urls { XCTAssertFalse(policy.youtubeCategories.blocks(url, categoryIDs: []), url) }
    }

    func testMonitoringClosesUnlistedAndUnknownVideosButKeepsEducationAndBrowsingPages() async throws {
        for browser in ScriptableBrowser.allCases {
            let app = ForegroundApplication(bundleID: browser.bundleID, processID: 100)
            let education = tab(index: 0)
            let music = tab(index: 1, url: "https://youtube.com/watch?v=musicvideo1")
            let unknown = tab(index: 2, url: "https://youtube.com/watch?v=unknownvid1")
            let home = tab(index: 3, url: "https://youtube.com/")
            let safe = tab(index: 4, url: "https://example.com/")
            let search = tab(index: 5, url: "https://www.youtube.com/results?search_query=education")
            let channel = tab(index: 6, url: "https://www.youtube.com/@education")
            let effects = CategoryEffects(application: app, tabs: [education, music, unknown, home, safe, search, channel])
            let resolver = CategoryResolver(idsByURL: [education.url: ["27"], music.url: ["10"]])
            let monitor = DistractionMonitor(policy: enabledPolicy,
                detector: DeterministicDistractionDetector(observations: effects, youtubeCategories: resolver),
                actions: effects, log: makeLog(), interval: .milliseconds(10))
            monitor.update(session: activeSession)
            await eventually { effects.closed.count == 2 }
            monitor.update(session: nil)
            XCTAssertEqual(effects.closed.map(\.index), [2, 1])
            XCTAssertEqual(effects.openTabs, [education, home, safe, search, channel])
        }
    }

    func testWebsiteAndWholeAppBlocksTakePrecedenceWithoutCategoryLookup() async throws {
        let home = tab(index: 1, url: "https://www.youtube.com/")
        let effects = CategoryEffects(application: application, tabs: [tab(), home])
        let resolver = CategoryResolver(ids: ["27"])
        let detector = DeterministicDistractionDetector(observations: effects, youtubeCategories: resolver)
        var policy = enabledPolicy
        policy.websiteDomains = ["youtube.com"]
        let websiteReport = try await detector.inspect(context(policy: policy))
        XCTAssertEqual(websiteReport, .findings([.browserTab(application, .safari, tab()), .browserTab(application, .safari, home)]))
        policy.applications = [.init(bundleID: application.bundleID, name: "Safari")]
        let appReport = try await detector.inspect(context(policy: policy))
        XCTAssertEqual(appReport, .findings([.application(application)]))
        let calls = await resolver.calls
        XCTAssertEqual(calls, 0)
    }

    func testLookupBudgetExpiryPreservesEarlierFindings() async throws {
        let first = tab()
        let effects = CategoryEffects(application: application, tabs: [first, tab(index: 1)])
        let detector = DeterministicDistractionDetector(observations: effects, youtubeCategories: ExpiringCategoryResolver())
        let report = try await detector.inspect(context(policy: enabledPolicy))
        XCTAssertEqual(report, .findings([.youtubeCategoryTab(application, .safari, first, categoryIDs: ["10"])]))
    }

    func testDisablingOrWhitelistingDuringLookupPreventsStaleClose() async throws {
        for disable in [true, false] {
            let effects = CategoryEffects(application: application, tabs: [tab()])
            let gate = CategoryGate()
            let monitor = DistractionMonitor(policy: enabledPolicy,
                detector: DeterministicDistractionDetector(observations: effects, youtubeCategories: gate),
                actions: effects, log: makeLog(), interval: .milliseconds(10))
            monitor.update(session: activeSession)
            while await gate.calls == 0 { await Task.yield() }
            var updated = enabledPolicy
            if disable { updated.youtubeCategories.isEnabled = false }
            else { updated.youtubeCategories.whitelist.append("10") }
            monitor.update(policy: updated)
            await gate.resume()
            await eventually { effects.reads >= (disable ? 1 : 2) }
            try await Task.sleep(for: .milliseconds(30))
            monitor.update(session: nil)
            XCTAssertTrue(effects.closed.isEmpty)
        }
    }

    private var videoURL: String { "https://www.youtube.com/watch?v=\(videoID)" }
    private var deadline: Date { Date().addingTimeInterval(20) }
    private var enabledPolicy: DistractionPolicy {
        .init(applications: [], websiteDomains: [], youtubeCategories: .init(isEnabled: true))
    }
    private var activeSession: MonitoringSession {
        .task(TodoTask(title: "Focus", dueAt: Date().addingTimeInterval(-1), duration: 60))
    }
    private func tab(index: Int = 0, url: String? = nil) -> BrowserTab {
        .init(windowID: "1", index: index, tabID: String(index), url: url ?? videoURL)
    }
    private func context(policy: DistractionPolicy) -> DetectionContext {
        .init(session: activeSession, policy: policy, deadline: deadline, foregroundApplication: application)
    }
    private func html(_ category: String, id: String? = nil) -> String {
        let player: [String: Any] = ["videoDetails": ["videoId": id ?? videoID, "title": "Braces } and escaped \"{\""],
            "microformat": ["playerMicroformatRenderer": ["category": category]]]
        let data = try! JSONSerialization.data(withJSONObject: player)
        return "<script>var ytInitialPlayerResponse = " + String(decoding: data, as: UTF8.self) + ";</script>"
    }
    private func makePreferences() throws -> UserDefaults {
        let suite = "youtube-category-test-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        return preferences
    }
    private func makeLog() -> ActivityLog {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("youtube-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ActivityLog(fileURL: directory.appendingPathComponent("activity.log"))
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private final class CategorySource: YouTubePageSourceReading {
    let html: String?
    var failure: Error = YouTubeCategoryLookupError.unavailable
    var reads = 0
    init(html: String?) { self.html = html }
    func youtubePageSource(for tab: BrowserTab, in browser: ScriptableBrowser,
                           application: ForegroundApplication, before deadline: Date) async throws -> String {
        reads += 1
        guard let html else { throw failure }
        return html
    }
}

private actor CategoryNetwork {
    let html: String?
    var requests: [URL] = []
    init(html: String?) { self.html = html }
    func fetch(_ url: URL) throws -> String {
        requests.append(url)
        guard let html else { throw YouTubeCategoryLookupError.unavailable }
        return html
    }
}

private actor CategoryResolver: YouTubeCategoryResolving {
    let ids: Set<String>
    let idsByURL: [String: Set<String>]
    var calls = 0
    init(ids: Set<String> = [], idsByURL: [String: Set<String>] = [:]) { self.ids = ids; self.idsByURL = idsByURL }
    func categoryIDs(for tab: BrowserTab, in browser: ScriptableBrowser,
                     application: ForegroundApplication, before deadline: Date) async throws -> Set<String> {
        calls += 1
        return idsByURL[tab.url] ?? ids
    }
}

private actor CategoryGate: YouTubeCategoryResolving {
    var calls = 0
    var continuation: CheckedContinuation<Set<String>, Never>?
    func categoryIDs(for tab: BrowserTab, in browser: ScriptableBrowser,
                     application: ForegroundApplication, before deadline: Date) async throws -> Set<String> {
        calls += 1
        if calls > 1 { return ["10"] }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(returning: ["10"]); continuation = nil }
}

private actor ExpiringCategoryResolver: YouTubeCategoryResolving {
    var calls = 0
    func categoryIDs(for tab: BrowserTab, in browser: ScriptableBrowser,
                     application: ForegroundApplication, before deadline: Date) async throws -> Set<String> {
        calls += 1
        if calls > 1 { throw YouTubeCategoryLookupError.expired }
        return ["10"]
    }
}

@MainActor
private final class CategoryEffects: DeterministicObservation, DistractionActions {
    let application: ForegroundApplication
    var openTabs: [BrowserTab]
    var closed: [BrowserTab] = []
    var reads = 0
    init(application: ForegroundApplication, tabs: [BrowserTab]) { self.application = application; openTabs = tabs }
    func frontmostApplication() -> ForegroundApplication? { application }
    func canAutomate(_ browser: ScriptableBrowser) -> Bool { true }
    func terminate(_ application: ForegroundApplication) -> Bool { false }
    func tabs(in browser: ScriptableBrowser, application: ForegroundApplication, before deadline: Date) async throws -> [BrowserTab] {
        reads += 1
        return openTabs
    }
    func close(_ tab: BrowserTab, in browser: ScriptableBrowser, application: ForegroundApplication, before deadline: Date) async throws -> Bool {
        guard openTabs.contains(tab) else { return false }
        closed.append(tab)
        openTabs.removeAll { $0 == tab }
        return true
    }
}
