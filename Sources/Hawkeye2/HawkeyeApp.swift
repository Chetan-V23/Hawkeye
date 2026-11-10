import SwiftUI
import AppKit
import Carbon

@main
struct HawkeyeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Hawkeye 2", systemImage: "eye") {
            HawkeyeMenu(delegate: delegate, startup: delegate.startup)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Hawkeye", action: delegate.showMainWindow).keyboardShortcut("o")
                Button("Close Window") { NSApplication.shared.keyWindow?.performClose(nil) }.keyboardShortcut("w")
            }
            CommandGroup(replacing: .appSettings) {
                Button("TickTick settings…") { delegate.showSettings() }.keyboardShortcut(",")
                Button("Focus permissions…") {
                    delegate.showMainWindow()
                    delegate.model.permissions.showSheet = true
                }
                Button("Blocked apps and websites…") {
                    delegate.showMainWindow()
                    delegate.model.showFocusConfiguration = true
                }
            }
            CommandMenu("Tasks") {
                SyncCommand(model: delegate.model)
            }
        }
    }
}

private struct SyncCommand: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button("Sync now") { model.syncNow() }.keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.connected || model.syncing)
    }
}

private struct HawkeyeMenu: View {
    let delegate: AppDelegate
    @ObservedObject var startup: LaunchAtLogin

    var body: some View {
        Button("Open Hawkeye", action: delegate.showMainWindow)
        Button("Settings…", action: delegate.showSettings)
        Divider()
        Toggle("Launch at login", isOn: Binding(get: { startup.isEnabled }, set: startup.setEnabled))
            .disabled(!startup.isAvailable)
        if startup.status == .requiresApproval {
            Button("Allow in Login Items…", action: startup.openSystemSettings)
        }
        if let error = startup.error { Text(error) }
        Divider()
        Button("Quit Hawkeye") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            .onAppear { startup.refresh() }
    }
}

enum AppLaunchMode: Equatable {
    case interactive
    case background

    init(arguments: [String], event: NSAppleEventDescriptor?) {
        let launchSource = event?.eventID == kAEOpenApplication
            ? event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue : nil
        self = arguments.contains("--background") || launchSource == keyAELaunchedAsLogInItem
            || launchSource == keyAELaunchedAsServiceItem ? .background : .interactive
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let startup = LaunchAtLogin.current()
    private var mainWindow: NSWindow?
    private var activityWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mode = AppLaunchMode(arguments: ProcessInfo.processInfo.arguments,
                                 event: NSAppleEventManager.shared().currentAppleEvent)
        NSApplication.shared.setActivationPolicy(.accessory)
        startup.configureOnFirstLaunch()
        model.activity.record("Startup", mode == .background ? "Started in the background." : "Opened interactively.")
        Task { await model.start(requestPermissions: false) }
        if mode == .interactive { showMainWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func showSettings() {
        showMainWindow()
        model.showSettings = true
    }

    func showMainWindow() {
        if mainWindow == nil {
            let root = HawkeyeRootView(model: model, startup: startup, showActivity: showActivityWindow)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Hawkeye 2"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentMinSize = NSSize(width: 1200, height: 760)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: root)
            window.center()
            mainWindow = window
        }
        NSApplication.shared.setActivationPolicy(.regular)
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.startInteractivePermissions()
    }

    private func showActivityWindow() {
        if activityWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Activity"
            window.contentMinSize = NSSize(width: 760, height: 400)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: ActivityLogView(log: model.activity).preferredColorScheme(.dark))
            window.center()
            activityWindow = window
        }
        activityWindow?.deminiaturize(nil)
        activityWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct HawkeyeRootView: View {
    @ObservedObject var model: AppModel
    let startup: LaunchAtLogin
    let showActivity: () -> Void

    var body: some View {
        ContentView().environmentObject(model)
            .environment(\.showActivityLog, showActivity)
            .preferredColorScheme(.dark)
            .frame(minWidth: 1200, minHeight: 760)
            .sheet(isPresented: $model.showSettings) {
                SettingsView().environmentObject(model).environmentObject(startup)
            }
            .sheet(isPresented: $model.showFocusConfiguration) {
                DistractionSettingsView(settings: model.distractions, permissions: model.permissions)
            }
            .modifier(FocusPermissionsPresentation(permissions: model.permissions))
    }
}

private struct ShowActivityLogKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var showActivityLog: () -> Void {
        get { self[ShowActivityLogKey.self] }
        set { self[ShowActivityLogKey.self] = newValue }
    }
}
