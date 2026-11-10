import XCTest
@testable import Hawkeye2

@MainActor
final class DistractionSettingsTests: XCTestCase {
    func testDomainRulesMatchOnlyActualHTTPHosts() throws {
        let policy = DistractionPolicy.standard
        let matches = ["https://instagram.com", "http://www.instagram.com/a", "HTTPS://INSTAGRAM.COM.:8443/p",
                       "https://sub.instagram.com/?next=example.org", "https://name@instagram.com"]
        for url in matches { XCTAssertEqual(policy.blockedDomain(for: url), "instagram.com", url) }
        let allowed = ["https://notinstagram.com", "https://instagram.com.evil.org", "https://example.org/instagram.com",
                       "https://instagram.com@example.org", "https://example.org/?q=instagram.com", "file://instagram.com/a",
                       "ftp://instagram.com", "instagram.com", "https://instagram.com..", "garbage"]
        for url in allowed { XCTAssertNil(policy.blockedDomain(for: url), url) }
        let second = DistractionPolicy(applications: [], websiteDomains: ["example.com"])
        XCTAssertEqual(second.blockedDomain(for: "https://news.example.com:443/path"), "example.com")
        XCTAssertNil(second.blockedDomain(for: "https://instagram.com"))
    }

    func testConfigurationPersistsApplicationAndCanonicalDomainAndRemoval() throws {
        let preferences = try makePreferences()
        let settings = DistractionSettings(preferences: preferences)
        XCTAssertEqual(settings.policy, .standard)
        let application = BlockedApplication(bundleID: "com.example.game", name: "A game")
        try settings.addApplication(application)
        try settings.addDomain(" HTTPS://NEWS.Example.COM.:8443/path?q=1 ")
        XCTAssertEqual(settings.policy.websiteDomains, ["instagram.com", "news.example.com/path"])
        let reloaded = DistractionSettings(preferences: preferences)
        XCTAssertEqual(reloaded.policy, settings.policy)
        try reloaded.removeApplication(application)
        try reloaded.removeDomain("instagram.com")
        let final = DistractionSettings(preferences: preferences)
        XCTAssertEqual(final.policy.applications, DistractionPolicy.standard.applications)
        XCTAssertEqual(final.policy.websiteDomains, ["news.example.com/path"])
    }

    func testConfigurationRejectsInvalidDuplicateAndOwnApplicationEntries() throws {
        let settings = DistractionSettings(preferences: try makePreferences())
        for domain in ["", ".", "...", "hello world.com", "https://", "ftp://example.com", "user@example.com",
                       "https://user@example.com", "-bad.example.com", "bad..example.com", "localhost"] {
            XCTAssertThrowsError(try settings.addDomain(domain), domain)
        }
        XCTAssertThrowsError(try settings.addDomain("INSTAGRAM.COM."))
        XCTAssertThrowsError(try settings.addApplication(.init(bundleID: "com.hawkeye2.mac", name: "Hawkeye")))
        XCTAssertThrowsError(try settings.addApplication(.init(bundleID: "com.hawkeye2.mac.development", name: "Hawkeye Dev")))
        XCTAssertThrowsError(try settings.addApplication(DistractionPolicy.standard.applications[0]))
        XCTAssertEqual(settings.policy, .standard)
    }

    func testIsolatedSettingsUseOnlyTheirOwnFileAndKeepNormalPreferencesUntouched() throws {
        let preferences = try makePreferences()
        let normal = DistractionSettings(preferences: preferences)
        try normal.addDomain("normal.example")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-policy-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("focus-policy.json")
        let isolated = DistractionSettings(preferences: preferences, fileURL: file)
        XCTAssertEqual(isolated.policy, .standard)
        try isolated.addDomain("isolated.example")
        let reloaded = DistractionSettings(preferences: preferences, fileURL: file)
        XCTAssertTrue(reloaded.policy.websiteDomains.contains("isolated.example"))
        let unchanged = DistractionSettings(preferences: preferences)
        XCTAssertEqual(unchanged.policy, normal.policy)
        XCTAssertFalse(unchanged.policy.websiteDomains.contains("isolated.example"))
    }

    func testDisabledPermissionSessionNeverRequestsOrEnablesSystemEffects() async throws {
        let preferences = try makePreferences()
        let log = ActivityLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).log"))
        let notifications = TaskNotifications(log: log, effectsEnabled: false)
        let permissions = FocusPermissions(effectsRequested: true, preferences: preferences, notifications: notifications,
                                           settings: DistractionSettings(preferences: preferences), isolated: true)
        await permissions.start()
        await permissions.requestAccess()
        await permissions.openScreenRecordingSettings()
        await permissions.requestAutomation(.safari)
        await permissions.refresh(requestNewBrowsers: true)
        XCTAssertFalse(permissions.effectsEnabled)
        XCTAssertTrue(permissions.showSheet)
        XCTAssertEqual(permissions.notifications, .unavailable)
        XCTAssertEqual(permissions.accessibility, .unavailable)
        XCTAssertEqual(permissions.screenRecording, .unavailable)
        XCTAssertEqual(permissions.automation[.safari], .unavailable)
        XCTAssertFalse(preferences.bool(forKey: "focusPermissions.requested.v1"))
        let effects = MacDistractionEffects(permissions: permissions)
        XCTAssertNil(effects.frontmostApplication())
        XCTAssertFalse(effects.canAutomate(.safari))
        let app = ForegroundApplication(bundleID: "com.apple.Chess", processID: 1)
        XCTAssertFalse(effects.terminate(app))
        let tabs = try await effects.tabs(in: .safari, application: app, before: Date().addingTimeInterval(1))
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertTrue(log.entries.isEmpty)
    }

    private func makePreferences() throws -> UserDefaults {
        let suite = "hawkeye-policy-test-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        return preferences
    }
}
