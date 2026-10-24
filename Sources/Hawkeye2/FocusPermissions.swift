import AppKit
import ApplicationServices
import Carbon
import Combine
import CoreGraphics
import Foundation
import UserNotifications

enum FocusPermissionStatus: String, Equatable {
    case granted = "Granted"
    case needsAccess = "Needs access"
    case denied = "Denied"
    case notRunning = "Open browser to allow access"
    case notInstalled = "Not installed"
    case requesting = "Waiting for your response"
    case unavailable = "Unavailable in this session"
}

@MainActor
final class FocusPermissions: ObservableObject {
    @Published var showSheet = false
    @Published private(set) var notifications: FocusPermissionStatus = .unavailable
    @Published private(set) var accessibility: FocusPermissionStatus = .unavailable
    @Published private(set) var screenRecording: FocusPermissionStatus = .unavailable
    @Published private(set) var automation: [ScriptableBrowser: FocusPermissionStatus] = [:]
    @Published private(set) var requesting = false
    var policy: DistractionPolicy { settings.policy }
    let effectsEnabled: Bool
    let disabledReason: String?

    private let preferences: UserDefaults
    private let settings: DistractionSettings
    private let effectsRequested: Bool
    private let taskNotifications: TaskNotifications
    private var pendingBrowsers = Set<ScriptableBrowser>()
    private var observers: [NSObjectProtocol] = []
    private var settingsListener: AnyCancellable?
    private let setupKey = "focusPermissions.requested.v1"

    init(effectsRequested: Bool, preferences: UserDefaults, notifications: TaskNotifications,
         settings: DistractionSettings, isolated: Bool = false) {
        self.preferences = preferences
        self.effectsRequested = effectsRequested
        self.taskNotifications = notifications
        self.settings = settings
        effectsEnabled = effectsRequested && !isolated && Bundle.main.bundleURL.pathExtension == "app"
        if isolated { disabledReason = "This isolated session never requests permissions, inspects applications, or closes anything." }
        else if !effectsRequested { disabledReason = "System access is disabled in this test session." }
        else if !effectsEnabled { disabledReason = "Open the signed, packaged Hawkeye app to grant permissions and enable blocking. A swift run process cannot reliably own macOS permissions." }
        else { disabledReason = nil }
        settingsListener = settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        for browser in policy.browsers { automation[browser] = .unavailable }
        guard effectsEnabled else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh(requestNewBrowsers: true) }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() async {
        guard effectsEnabled else { showSheet = effectsRequested; return }
        await refresh()
        guard !preferences.bool(forKey: setupKey) else {
            await requestRunningBrowsers()
            return
        }
        showSheet = true
        preferences.set(true, forKey: setupKey)
        await requestAccess()
    }

    func requestAccess() async {
        guard effectsEnabled, !requesting else { return }
        requesting = true
        defer { requesting = false }
        await taskNotifications.requestAuthorization()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                _ = CGRequestScreenCaptureAccess()
                continuation.resume()
            }
        }
        await refresh()
        await requestRunningBrowsers()
    }

    func refresh(requestNewBrowsers: Bool = false) async {
        guard effectsEnabled else { return }
        notifications = await taskNotifications.authorizationStatus()
        accessibility = AXIsProcessTrusted() ? .granted : .needsAccess
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .needsAccess
        for browser in policy.browsers where !pendingBrowsers.contains(browser) {
            guard isInstalled(browser) else { automation[browser] = .notInstalled; continue }
            guard isRunning(browser) else { automation[browser] = .notRunning; continue }
            automation[browser] = await Self.automationStatus(browser, ask: false)
        }
        if requestNewBrowsers { await requestRunningBrowsers() }
    }

    func requestAutomation(_ browser: ScriptableBrowser) async {
        guard effectsEnabled, !pendingBrowsers.contains(browser) else { return }
        guard isInstalled(browser) else { automation[browser] = .notInstalled; return }
        guard isRunning(browser) else { automation[browser] = .notRunning; return }
        pendingBrowsers.insert(browser)
        preferences.set(true, forKey: automationKey(browser))
        automation[browser] = .requesting
        automation[browser] = await Self.automationStatus(browser, ask: true)
        pendingBrowsers.remove(browser)
    }

    func openSettings(_ pane: String) {
        guard effectsEnabled, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openNotificationSettings() {
        guard effectsEnabled, let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestRunningBrowsers() async {
        for browser in policy.browsers where !preferences.bool(forKey: automationKey(browser)) {
            await requestAutomation(browser)
        }
    }

    private func automationKey(_ browser: ScriptableBrowser) -> String { "focusPermissions.automation.\(browser.bundleID).v1" }
    private func isInstalled(_ browser: ScriptableBrowser) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil }
    private func isRunning(_ browser: ScriptableBrowser) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty }

    private nonisolated static func automationStatus(_ browser: ScriptableBrowser, ask: Bool) async -> FocusPermissionStatus {
        // macOS can wait indefinitely for a consent response. Keep this call off the main actor.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var target = AEAddressDesc()
                let bundleID = Array(browser.bundleID.utf8)
                let status = bundleID.withUnsafeBytes {
                    AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target)
                }
                guard status == noErr else { continuation.resume(returning: .needsAccess); return }
                defer { AEDisposeDesc(&target) }
                let result = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
                let permission: FocusPermissionStatus
                switch result {
                case noErr: permission = .granted
                case OSStatus(procNotFound): permission = .notRunning
                case OSStatus(errAEEventNotPermitted): permission = .denied
                default: permission = .needsAccess
                }
                continuation.resume(returning: permission)
            }
        }
    }
}
