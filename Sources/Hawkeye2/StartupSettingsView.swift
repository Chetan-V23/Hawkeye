import SwiftUI

struct StartupSettingsView: View {
    @ObservedObject var startup: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(get: { startup.isEnabled }, set: startup.setEnabled))
                .disabled(!startup.isAvailable)
            Text(startup.explanation).font(.system(size: 11)).foregroundStyle(Palette.muted)
            if startup.status == .requiresApproval || startup.status == .notFound {
                Button("Open Login Items settings…", action: startup.openSystemSettings)
                    .buttonStyle(.plain).foregroundStyle(Palette.green)
            }
            if let error = startup.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.orange).textSelection(.enabled)
            }
        }.font(.system(size: 12))
            .onAppear { startup.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                startup.refresh()
            }
    }
}
