import AppKit
import Combine
import ServiceManagement

@MainActor
protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct MainAppLoginItem: LoginItemServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LaunchAtLogin: ObservableObject {
    enum Status: Equatable {
        case unavailable(String)
        case disabled
        case enabled
        case requiresApproval
        case notFound
    }

    @Published private(set) var status: Status
    @Published private(set) var error: String?
    private let service: any LoginItemServicing
    private let preferences: UserDefaults
    private let automaticallyEnable: Bool
    private let configuredKey = "startup.configured.v1"

    init(service: any LoginItemServicing, preferences: UserDefaults,
         unavailableReason: String? = nil, automaticallyEnable: Bool) {
        self.service = service
        self.preferences = preferences
        self.automaticallyEnable = automaticallyEnable
        status = unavailableReason.map(Status.unavailable) ?? .disabled
        refresh()
    }

    static func eligibility(bundleURL: URL, bundleIdentifier: String?, arguments: [String],
                            hasDataDirectory: Bool) -> String? {
        if arguments.contains("--data-directory") || hasDataDirectory {
            return "Launch at login is disabled in isolated sessions."
        }
        guard bundleURL.pathExtension == "app",
              ["com.hawkeye2.mac", "com.hawkeye2.mac.development"].contains(bundleIdentifier) else {
            return "Open the signed Hawkeye app to configure launch at login."
        }
        return nil
    }

    static func current() -> LaunchAtLogin {
        #if DEBUG
        let preferences = UserDefaults(suiteName: "com.hawkeye2.mac.development") ?? .standard
        let automaticallyEnable = false
        #else
        let preferences = UserDefaults.standard
        let automaticallyEnable = true
        #endif
        return LaunchAtLogin(service: MainAppLoginItem(), preferences: preferences,
            unavailableReason: eligibility(bundleURL: Bundle.main.bundleURL,
                bundleIdentifier: Bundle.main.bundleIdentifier, arguments: ProcessInfo.processInfo.arguments,
                hasDataDirectory: Bundle.main.object(forInfoDictionaryKey: "HawkeyeDataDirectory") != nil),
            automaticallyEnable: automaticallyEnable)
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var isAvailable: Bool {
        if case .unavailable = status { return false }
        return true
    }
    var explanation: String {
        switch status {
        case .unavailable(let reason): return reason
        case .disabled: return "Start Hawkeye in the menu bar when you log in to your Mac."
        case .enabled: return "Hawkeye starts in the menu bar without opening a window when you log in."
        case .requiresApproval: return "To allow Hawkeye, open System Settings, then General, then Login Items & Extensions."
        case .notFound: return "macOS could not find this app. Keep the signed app in a permanent location and try again."
        }
    }

    func configureOnFirstLaunch() {
        guard isAvailable, automaticallyEnable, !preferences.bool(forKey: configuredKey) else { return }
        preferences.set(true, forKey: configuredKey)
        refresh()
        if status == .disabled || status == .notFound { setEnabled(true) }
    }

    func refresh() {
        guard isAvailable else { return }
        switch service.status {
        case .notRegistered: status = .disabled
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = .notFound
        @unknown default: status = .notFound
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        preferences.set(true, forKey: configuredKey)
        error = nil
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
        } catch { self.error = error.localizedDescription }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
