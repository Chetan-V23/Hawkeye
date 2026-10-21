import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var projectID = ""
    @State private var projects: [ProjectOption] = []
    @State private var editingToken = false
    @State private var checking = false
    @State private var message: String?

    private var enteringToken: Bool { !model.connected || editingToken }
    private var selectedProject: ProjectOption? { projects.first { $0.id == projectID } }
    private var canSave: Bool {
        !checking && selectedProject != nil && (enteringToken || projectID != model.projectID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack {
                Eyebrow(text: "YOUR TASKS, TOGETHER")
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close settings")
            }
            Text(enteringToken ? (model.connected ? "Change your token." : "Connect TickTick.") : "TickTick connected.")
                .font(.system(size: 32, design: .serif))
            if enteringToken {
                tokenEntry
            } else {
                HStack {
                    Label(model.tokenStorageDescription, systemImage: model.tokenFileURL == nil ? "lock.shield" : "doc.text")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Change token") {
                        editingToken = true
                        token = ""
                        projects = []
                        message = nil
                    }.buttonStyle(QuietButton()).disabled(checking)
                }.padding(19).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
            }
            if let url = model.tokenFileURL {
                Text(url.path).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
            if !enteringToken || !projects.isEmpty { destinationPicker }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.orange).textSelection(.enabled)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            Label("Syncs every minute while Hawkeye is running.", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                if model.connected {
                    Button("Disconnect") {
                        checking = true
                        Task {
                            do { try await model.disconnect(); dismiss() }
                            catch { message = error.localizedDescription }
                            checking = false
                        }
                    }.buttonStyle(.plain).foregroundStyle(Palette.orange).disabled(checking)
                }
                Spacer()
                if editingToken {
                    Button("Cancel") {
                        editingToken = false
                        token = ""
                        Task { await loadSavedProjects() }
                    }.disabled(checking)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(enteringToken ? "Connect & sync" : "Save destination") { save() }
                    .buttonStyle(QuietButton()).disabled(!canSave)
            }
        }.padding(30).frame(width: 560)
            .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
            .task { if model.connected { await loadSavedProjects() } }
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste your personal access token. \(model.tokenStorageExplanation)")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5)
            Text("Create a token in TickTick on the web under Settings → Account → API Token.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            VStack(alignment: .leading, spacing: 11) {
                Eyebrow(text: "PERSONAL ACCESS TOKEN")
                SecureField(model.connected ? "Paste your replacement token" : "Paste your TickTick token", text: $token)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("TickTick personal access token")
                    .disabled(checking)
                    .onChange(of: token) { _, _ in projects = []; projectID = ""; message = nil }
                HStack {
                    Link("TickTick API documentation", destination: URL(string: "https://developer.ticktick.com/docs/index.html#/openapi")!)
                        .foregroundStyle(Palette.green)
                    Spacer()
                    Button(checking ? "Checking…" : "Check token") { checkToken() }
                        .buttonStyle(QuietButton()).disabled(checking || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.font(.system(size: 11))
            }.padding(19).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("New tasks go to", selection: $projectID) {
                    Text("Choose a TickTick list").tag("")
                    if !enteringToken && !model.projectID.isEmpty && !projects.contains(where: { $0.id == model.projectID }) {
                        Text(model.projectName).tag(model.projectID)
                    }
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }.accessibilityLabel("TickTick destination list")
                    .disabled(checking || projects.isEmpty)
                if checking { ProgressView().controlSize(.small) }
                else if !enteringToken {
                    Button { Task { await loadSavedProjects() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.buttonStyle(.plain).foregroundStyle(Palette.green)
                        .accessibilityLabel("Refresh TickTick lists")
                }
            }
            Text(model.connected
                 ? "This applies to new tasks. Tasks already synced stay in their current TickTick lists."
                 : "Existing local tasks will also sync to this list. Tasks from your other lists appear here too.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
        }
    }

    private func loadSavedProjects() async {
        checking = true
        message = nil
        projectID = model.projectID
        do {
            projects = try await model.availableProjects()
            if projects.isEmpty { message = "No writable task lists found. Create a list in TickTick, then refresh." }
        } catch { message = error.localizedDescription }
        checking = false
    }

    private func checkToken() {
        checking = true
        message = nil
        Task {
            do {
                projects = try await model.checkToken(token)
                if projects.contains(where: { $0.id == model.projectID }) { projectID = model.projectID }
                else if projects.count == 1 { projectID = projects[0].id }
                if projects.isEmpty { message = "No writable task lists found. Create a list in TickTick, then check again." }
            } catch { message = error.localizedDescription }
            checking = false
        }
    }

    private func save() {
        guard let project = selectedProject else { return }
        checking = true
        Task {
            do {
                if enteringToken { try await model.connect(token: token, project: project) }
                else { try await model.changeDestination(to: project) }
                dismiss()
            } catch { message = error.localizedDescription }
            checking = false
        }
    }
}
