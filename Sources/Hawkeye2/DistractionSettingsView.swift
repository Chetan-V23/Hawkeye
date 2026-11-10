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
                Eyebrow(text: "Focus settings")
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close focus configuration")
            }
            Text("Blocked apps and websites").font(.system(size: 30, design: .serif))
            Text("Hawkeye saves changes on this Mac and applies them immediately during monitoring. Monitoring continues through Pomodoro breaks and task pauses while the timer is running.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Eyebrow(text: "Blocked apps")
                            Spacer()
                            Button("Add app…", action: chooseApplication).buttonStyle(QuietButton())
                        }
                        Text("Hawkeye quits blocked apps when you bring them to the front. This closes all their windows and tabs.")
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
                        Eyebrow(text: "Blocked websites")
                        Text("Hawkeye closes tabs that match blocked websites or their subdomains in Safari and Google Chrome. Firefox does not support tab inspection. Add Firefox to Blocked apps to quit it during monitoring.")
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
                    youtubeCategoriesSection
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

    private var youtubeCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(text: "Youtube Category")
                Spacer()
                Button {
                    perform { try settings.setYouTubeCategoriesEnabled(!settings.policy.youtubeCategories.isEnabled) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: settings.policy.youtubeCategories.isEnabled ? "largecircle.fill.circle" : "circle")
                        Text("Enable")
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Palette.green)
                .accessibilityLabel("Enable YouTube category whitelist")
                .accessibilityValue(settings.policy.youtubeCategories.isEnabled ? "Enabled" : "Disabled")
                .help("Turn YouTube category filtering on or off")
            }
            Text("Categories you want NOT blocked on youtube.")
                .font(.system(size: 13))
            Text("Note - if youtube.com is blocked above, this section is redundant. If the video is not categorized well, it might lead to unexpected behaviour.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            VStack(alignment: .leading, spacing: 12) {
                Menu {
                    ForEach(YouTubeCategory.choices) { category in
                        Button(category.name) { perform { try settings.addYouTubeCategory(category) } }
                            .disabled(YouTubeCategory.matchingIDs(for: category.name).isSubset(of: Set(settings.policy.youtubeCategories.whitelist)))
                    }
                } label: {
                    HStack {
                        Text("Add to whitelist")
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10))
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel("Add to whitelist")
                if settings.policy.youtubeCategories.whitelist.isEmpty { empty("No categories whitelisted. All YouTube tabs will close.") }
                ForEach(YouTubeCategory.whitelisted(in: settings.policy.youtubeCategories.whitelist)) { category in
                    HStack {
                        Text(category.name).font(.system(size: 13))
                        Spacer()
                        removeButton("Remove \(category.name) from whitelist") {
                            perform { try settings.removeYouTubeCategory(category.id) }
                        }
                    }
                }
                Text("Applies to YouTube video pages in Safari and Google Chrome. Homepage, search, and channel pages stay open. Videos without an available category close.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
            .disabled(!settings.policy.youtubeCategories.isEnabled)
            .opacity(settings.policy.youtubeCategories.isEnabled ? 1 : 0.65)
        }.padding(18).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
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
