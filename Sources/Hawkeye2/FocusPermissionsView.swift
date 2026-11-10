import SwiftUI

struct FocusPermissionsPresentation: ViewModifier {
    @ObservedObject var permissions: FocusPermissions

    func body(content: Content) -> some View {
        content.sheet(isPresented: $permissions.showSheet) { FocusPermissionsView(permissions: permissions) }
    }
}

struct FocusPermissionsView: View {
    @ObservedObject var permissions: FocusPermissions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                Eyebrow(text: "Focus permissions")
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close focus permissions")
            }
            Text("Allow focus monitoring").font(.system(size: 30, design: .serif))
            Text("While a task or Pomodoro timer is active, Hawkeye quits blocked apps you bring to the front. It closes tabs on blocked websites and their subdomains in Safari and Google Chrome. Monitoring continues through Pomodoro breaks and task pauses while the timer is running.")
                .font(.system(size: 13)).lineSpacing(4)
            if let reason = permissions.disabledReason {
                Text(reason).font(.system(size: 12)).foregroundStyle(Palette.orange)
            }
            VStack(alignment: .leading, spacing: 15) {
                row("Notifications", status: permissions.notifications,
                    explanation: "Hawkeye sends alerts when tasks start and Pomodoro intervals change.") { permissions.openNotificationSettings() }
                row("Accessibility", status: permissions.accessibility,
                    explanation: "Allows Hawkeye to control your Mac and read browser text while a task or Pomodoro is active. Hawkeye saves page text and main content in the local activity log at the start of monitoring and every minute. It keeps up to 240 captures. Foreground app detection does not need this permission.") { permissions.openSettings("Privacy_Accessibility") }
                row("Screen Recording", status: permissions.screenRecording,
                    explanation: "Hawkeye checks each display and saves a screenshot thumbnail from each to your activity log every minute during monitoring. It keeps up to 240 thumbnails on this Mac.") { Task { await permissions.openScreenRecordingSettings() } }
                ForEach(permissions.policy.browsers) { browser in
                    VStack(alignment: .leading, spacing: 5) {
                        row("\(browser.name) Automation", status: permissions.automation[browser] ?? .unavailable,
                            explanation: "Hawkeye reads tab URLs and closes blocked tabs. Open this browser to grant access.") { permissions.openSettings("Privacy_Automation") }
                        Button("Allow \(browser.name)…") { Task { await permissions.requestAutomation(browser) } }
                            .font(.system(size: 11))
                            .disabled(!permissions.effectsEnabled || permissions.automation[browser] == .requesting
                                      || permissions.automation[browser] == .granted || permissions.automation[browser] == .notRunning
                                      || permissions.automation[browser] == .notInstalled)
                    }
                }
            }.padding(18).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
            Text("Each browser needs Automation permission separately from Accessibility and Screen Recording. Hawkeye does not open browsers during setup. It leaves unrelated Safari and Chrome tabs open unless you block the whole app. Firefox does not support tab inspection.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            HStack {
                Button("Refresh status") { Task { await permissions.refresh() } }.disabled(!permissions.effectsEnabled)
                Spacer()
                Button("Request access…") { Task { await permissions.requestAccess() } }
                    .disabled(!permissions.effectsEnabled || permissions.requesting)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 640)
            .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
            .task { await permissions.refresh() }
    }

    private func row(_ title: String, status: FocusPermissionStatus, explanation: String,
                     settings: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(status.rawValue).font(.system(size: 11)).foregroundStyle(status == .granted ? Palette.green : Palette.muted)
                Button("Settings…", action: settings).font(.system(size: 11)).disabled(!permissions.effectsEnabled)
            }
            Text(explanation).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}
