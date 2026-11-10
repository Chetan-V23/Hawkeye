import Carbon
import ServiceManagement
import XCTest
@testable import Hawkeye2

@MainActor
final class StartupTests: XCTestCase {
    func testFirstLaunchEnablesLoginOnceAndRespectsLaterSystemChanges() throws {
        let preferences = try makePreferences()
        let service = FakeLoginItem()
        let startup = LaunchAtLogin(service: service, preferences: preferences, automaticallyEnable: true)
        startup.configureOnFirstLaunch()
        XCTAssertEqual(startup.status, .enabled)
        XCTAssertEqual(service.registrations, 1)
        service.status = .notRegistered
        let nextLaunch = LaunchAtLogin(service: service, preferences: preferences, automaticallyEnable: true)
        nextLaunch.configureOnFirstLaunch()
        XCTAssertEqual(nextLaunch.status, .disabled)
        XCTAssertEqual(service.registrations, 1)
    }

    func testExplicitTogglePersistsOptOutAndAllowsOptIn() throws {
        let preferences = try makePreferences()
        let service = FakeLoginItem()
        let startup = LaunchAtLogin(service: service, preferences: preferences, automaticallyEnable: true)
        startup.setEnabled(false)
        startup.configureOnFirstLaunch()
        XCTAssertEqual(service.registrations, 0)
        XCTAssertFalse(startup.isEnabled)
        startup.setEnabled(true)
        XCTAssertTrue(startup.isEnabled)
        startup.setEnabled(false)
        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertFalse(startup.isEnabled)
    }

    func testFirstLaunchRegistersWhenMacOSHasNoRecordOfThisAppYet() throws {
        let service = FakeLoginItem()
        service.status = .notFound
        let startup = LaunchAtLogin(service: service, preferences: try makePreferences(), automaticallyEnable: true)
        startup.configureOnFirstLaunch()
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(startup.status, .enabled)
    }

    func testExistingApprovalStateDoesNotRegisterAgainAndRefreshReflectsSystemChanges() throws {
        let service = FakeLoginItem()
        service.status = .requiresApproval
        let startup = LaunchAtLogin(service: service, preferences: try makePreferences(), automaticallyEnable: true)
        startup.configureOnFirstLaunch()
        XCTAssertEqual(startup.status, .requiresApproval)
        XCTAssertTrue(startup.isEnabled)
        XCTAssertEqual(service.registrations, 0)
        service.status = .enabled
        startup.refresh()
        XCTAssertEqual(startup.status, .enabled)
        service.status = .notRegistered
        startup.refresh()
        XCTAssertFalse(startup.isEnabled)
    }

    func testRegistrationFailureIsVisibleAndCanBeRetriedExplicitly() throws {
        let service = FakeLoginItem()
        service.failure = NSError(domain: "StartupTests", code: 1)
        let startup = LaunchAtLogin(service: service, preferences: try makePreferences(), automaticallyEnable: true)
        startup.configureOnFirstLaunch()
        XCTAssertNotNil(startup.error)
        XCTAssertFalse(startup.isEnabled)
        startup.configureOnFirstLaunch()
        XCTAssertEqual(service.registrations, 1)
        service.failure = nil
        startup.setEnabled(true)
        XCTAssertNil(startup.error)
        XCTAssertTrue(startup.isEnabled)
    }

    func testIsolatedSessionsNeverRegisterEvenWithExplicitToggle() throws {
        let service = FakeLoginItem()
        let startup = LaunchAtLogin(service: service, preferences: try makePreferences(),
            unavailableReason: "Isolated session", automaticallyEnable: true)
        startup.configureOnFirstLaunch()
        startup.setEnabled(true)
        startup.setEnabled(false)
        XCTAssertFalse(startup.isAvailable)
        XCTAssertEqual(startup.status, .unavailable("Isolated session"))
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
    }

    func testDevelopmentBuildRequiresExplicitOptIn() throws {
        let service = FakeLoginItem()
        let startup = LaunchAtLogin(service: service, preferences: try makePreferences(), automaticallyEnable: false)
        startup.configureOnFirstLaunch()
        XCTAssertEqual(service.registrations, 0)
        startup.setEnabled(true)
        XCTAssertTrue(startup.isEnabled)
    }

    func testEligibilityRejectsBareBinaryAndBothIsolationFormsIncludingMissingArgument() {
        let app = URL(fileURLWithPath: "/Applications/Hawkeye 2.app")
        XCTAssertNil(LaunchAtLogin.eligibility(bundleURL: app, bundleIdentifier: "com.hawkeye2.mac",
            arguments: [], hasDataDirectory: false))
        XCTAssertNotNil(LaunchAtLogin.eligibility(bundleURL: app, bundleIdentifier: "com.hawkeye2.mac",
            arguments: ["--data-directory"], hasDataDirectory: false))
        XCTAssertNotNil(LaunchAtLogin.eligibility(bundleURL: app, bundleIdentifier: "com.hawkeye2.mac",
            arguments: [], hasDataDirectory: true))
        XCTAssertNotNil(LaunchAtLogin.eligibility(bundleURL: URL(fileURLWithPath: "/tmp/Hawkeye2"),
            bundleIdentifier: nil, arguments: [], hasDataDirectory: false))
    }

    func testLoginEventAndBackgroundArgumentStartQuietlyButNormalLaunchIsInteractive() {
        XCTAssertEqual(AppLaunchMode(arguments: [], event: nil), .interactive)
        XCTAssertEqual(AppLaunchMode(arguments: ["--background"], event: nil), .background)
        for source in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
            let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(enumCode: source), forKeyword: keyAEPropData)
            XCTAssertEqual(AppLaunchMode(arguments: [], event: event), .background)
        }
    }

    private func makePreferences() throws -> UserDefaults {
        let name = "com.hawkeye2.tests.startup.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { preferences.removePersistentDomain(forName: name) }
        return preferences
    }
}

@MainActor
private final class FakeLoginItem: LoginItemServicing {
    var status: SMAppService.Status = .notRegistered
    var failure: Error?
    var registrations = 0
    var unregistrations = 0
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = .enabled
    }
    func unregister() throws {
        unregistrations += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}
