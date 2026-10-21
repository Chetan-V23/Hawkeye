import SwiftUI
import AppKit

@main
struct HawkeyeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Hawkeye 2") {
            ContentView().environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1200, minHeight: 760)
                .task { await model.start() }
                .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
        }
        .defaultSize(width: 1400, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("TickTick settings…") { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("Tasks") {
                Button("Sync now") { model.syncNow() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.connected || model.syncing)
            }
        }
        #if DEBUG
        Window("Developer activity", id: "activity") {
            ActivityLogView(log: model.activity).preferredColorScheme(.dark)
                .frame(minWidth: 760, minHeight: 400)
        }.defaultSize(width: 900, height: 540)
        #endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
