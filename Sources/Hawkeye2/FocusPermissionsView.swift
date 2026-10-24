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
                Eyebrow(text: "FOCUS PERMISSIONS")
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close focus permissions")
            }
            Text("Protect your task time.").font(.system(size: 30, design: .serif))
            Text("While a task is active, Hawkeye closes your blocked apps when brought to the front. In Safari and Google Chrome, it closes tabs on your blocked websites and their subdomains. Pausing a task pauses blocking.")
                .font(.system(size: 13)).lineSpacing(4)
            if let reason = permissions.disabledReason {
                Text(reason).font(.system(size: 12)).foregroundStyle(Palette.orange)
            }
            VStack(alignment: .leading, spacing: 15) {
                row("Notifications", status: permissions.notifications,
                    explanation: "Shows an alert when your task starts.") { permissions.openNotificationSettings() }
                row("Accessibility", status: permissions.accessibility,
                    explanation: "Allows computer control for focus assistance. Foreground app detection works without it.") { permissions.openSettings("Privacy_Accessibility") }
                row("Screen Recording", status: permissions.screenRecording,
                    explanation: "Allows screen reading for focus assistance. This version does not capture or read your screen.") { permissions.openSettings("Privacy_ScreenCapture") }
                ForEach(permissions.policy.browsers) { browser in
                    VStack(alignment: .leading, spacing: 5) {
                        row("\(browser.name) Automation", status: permissions.automation[browser] ?? .unavailable,
                            explanation: "Reads tab URLs and closes blocked tabs. Open this browser to grant access.") { permissions.openSettings("Privacy_Automation") }
                        Button("Allow \(browser.name)…") { Task { await permissions.requestAutomation(browser) } }
                            .font(.system(size: 11))
                            .disabled(!permissions.effectsEnabled || permissions.automation[browser] == .requesting
                                      || permissions.automation[browser] == .granted || permissions.automation[browser] == .notRunning
                                      || permissions.automation[browser] == .notInstalled)
                    }
                }
            }.padding(18).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
            Text("Browser access is separate from Accessibility and Screen Recording. Hawkeye never opens browsers for setup. Safari and Chrome keep unrelated tabs unless you block the whole app. Firefox has no tab inspection support.")
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
