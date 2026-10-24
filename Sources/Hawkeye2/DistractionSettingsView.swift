import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DistractionSettingsView: View {
    @ObservedObject var settings: DistractionSettings
    @ObservedObject var permissions: FocusPermissions
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var message: String?
    @State private var showPermissions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Eyebrow(text: "YOUR FOCUS RULES")
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close focus configuration")
            }
            Text("Make room to focus.").font(.system(size: 30, design: .serif))
            Text("Changes save on this Mac and apply immediately during an active task. Pausing your task pauses every block.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Eyebrow(text: "BLOCKED APPS")
                            Spacer()
                            Button("Add app…", action: chooseApplication).buttonStyle(QuietButton())
                        }
                        Text("Blocked apps close completely when you bring them to the front, including their other windows and tabs.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                        if settings.policy.applications.isEmpty { empty("No apps blocked.") }
                        ForEach(settings.policy.applications) { application in
                            HStack {
                                Text(application.name).font(.system(size: 13))
                                Spacer()
                                removeButton("Remove \(application.name)") { perform { try settings.removeApplication(application) } }
                            }
                        }
                    }.padding(18).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "BLOCKED WEBSITES")
                        Text("Safari and Google Chrome close only matching tabs, including subdomains. Firefox does not support tab inspection. Add it above to block the whole app.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                        HStack {
                            TextField("Website domain or URL", text: $domain).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Blocked website domain or URL")
                                .onSubmit(addDomain)
                            Button("Add", action: addDomain).buttonStyle(QuietButton())
                                .disabled(domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if settings.policy.websiteDomains.isEmpty { empty("No websites blocked.") }
                        ForEach(settings.policy.websiteDomains, id: \.self) { website in
                            HStack {
                                Text(website).font(.system(size: 13))
                                Spacer()
                                removeButton("Remove \(website)") { perform { try settings.removeDomain(website) } }
                            }
                        }
                    }.padding(18).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
                }
            }.frame(maxHeight: 440)
            if let message = message ?? settings.error {
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.orange).accessibilityLabel(message)
            }
            HStack {
                Button("Focus permissions…") { showPermissions = true }
                    .buttonStyle(.plain).foregroundStyle(Palette.green)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.font(.system(size: 12))
        }.padding(28).frame(width: 600)
            .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
            .sheet(isPresented: $showPermissions) { FocusPermissionsView(permissions: permissions) }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 4)
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle").font(.system(size: 15)) }
            .buttonStyle(.plain).foregroundStyle(Palette.muted).help(label).accessibilityLabel(label)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to block while focusing"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            perform { try settings.addApplication(at: url) }
        }
    }

    private func addDomain() { perform { try settings.addDomain(domain); domain = "" } }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); message = nil }
        catch { message = error.localizedDescription }
    }
}
