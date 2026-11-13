import SwiftUI
import HawkeyeCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var startup: LaunchAtLogin
    @Environment(\.dismiss) private var dismiss
    @State private var provider: TaskProviderID = .ticktick
    @State private var token = ""
    @State private var destinationID = ""
    @State private var catalog = ConnectionCatalog(destinations: [])
    @State private var editingToken = false
    @State private var checking = false
    @State private var message: String?
    @State private var showPermissions = false
    @State private var titlePropertyID = ""
    @State private var statusPropertyID = ""
    @State private var duePropertyID = ""
    @State private var descriptionPropertyID = ""
    @State private var openStatus = ""
    @State private var completedStatus = ""
    @State private var pageIDs: [UUID: String] = [:]

    private var enteringToken: Bool { !model.connected || provider != model.providerID || editingToken }
    private var selectedDestination: TaskDestination? { catalog.destinations.first { $0.id == destinationID } }
    private var source: NotionDataSource? { catalog.notionDataSources.first { $0.id == destinationID } }
    private var statusProperty: NotionProperty? { source?.properties.first { $0.id == statusPropertyID } }
    private var mapping: NotionTaskMapping? {
        guard provider == .notion, let source, let statusProperty else { return nil }
        let value = NotionTaskMapping(titlePropertyID: titlePropertyID, statusPropertyID: statusPropertyID,
                                     statusType: statusProperty.type, openStatus: openStatus, completedStatus: completedStatus,
                                     duePropertyID: duePropertyID,
                                     descriptionPropertyID: descriptionPropertyID.isEmpty ? nil : descriptionPropertyID)
        return (try? value.validate(in: source)) == nil ? nil : value
    }
    private var canSave: Bool {
        !checking && selectedDestination != nil && (provider != .notion || mapping != nil)
            && (enteringToken || destinationID != model.projectID || mapping != model.connection?.notionMapping)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: "Third Party App")
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close settings")
            }.padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.connected ? "Third Party App connected" : "Connect a Third Party App")
                        .font(.system(size: 29, design: .serif))
                    Picker("Task app", selection: Binding(get: { provider }, set: { provider = $0; resetDraft() })) {
                        ForEach(TaskProviderID.allCases) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented).disabled(checking)
                        .accessibilityLabel("Third Party App")
                    Text("Connect one app at a time. Changing this selection takes effect only when you save a validated connection.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                    if enteringToken { tokenEntry }
                    else { savedToken }
                    if let url = model.tokenFileURL(for: provider) {
                        Text(url.path).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if !catalog.destinations.isEmpty { destinationPicker }
                    if provider == .notion, source != nil { notionMapping }
                    Text("All saved tasks, including imported tasks, stay in Hawkeye with their dates, completion, durations, and focus history. Switching apps discards the previous connection's credentials and sync data. It leaves tasks in the previous app untouched. Retained tasks will sync to the new app.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                    if let message {
                        Text(message).font(.system(size: 12)).foregroundStyle(Palette.orange)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.uncertainNotionTasks.isEmpty { uncertainCreations }
                    Rectangle().fill(Palette.line).frame(height: 1)
                    StartupSettingsView(startup: startup)
                    Label("Syncs every minute while Hawkeye is running.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Button("Focus permissions…") { showPermissions = true }
                        .buttonStyle(.plain).foregroundStyle(Palette.green).font(.system(size: 12))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 5)
            }
            HStack {
                if model.connected {
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.plain).foregroundStyle(Palette.orange).disabled(checking)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(enteringToken ? "Connect and sync" : "Save connection") { save() }
                    .buttonStyle(QuietButton()).disabled(!canSave)
            }.padding(.top, 20)
        }.padding(28).frame(width: 590, height: 700)
            .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
            .task {
                provider = model.providerID
                if model.connected { await loadCatalog() }
            }
            .sheet(isPresented: $showPermissions) { FocusPermissionsView(permissions: model.permissions) }
    }

    private var savedToken: some View {
        HStack {
            Label(model.tokenStorageDescription, systemImage: model.tokenFileURL == nil ? "lock.shield" : "doc.text")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Spacer()
            Button("Change token") {
                editingToken = true
                token = ""
                clearCatalog()
            }.buttonStyle(QuietButton()).disabled(checking)
        }.padding(17).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste your \(provider.displayName) personal access token. \(model.tokenStorageExplanation)")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            Text(tokenInstructions).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            Eyebrow(text: "Personal access token")
            SecureField("Paste your \(provider.displayName) token", text: Binding(get: { token }, set: { token = $0; clearCatalog() }))
                .textFieldStyle(.roundedBorder).accessibilityLabel("\(provider.displayName) personal access token")
                .disabled(checking)
            HStack {
                if provider == .notion {
                    Link("Create a Notion PAT", destination: URL(string: "https://www.notion.so/developers/tokens")!)
                } else {
                    Link("\(provider.displayName) API documentation", destination: documentationURL)
                }
                Spacer()
                Button(checking ? "Checking…" : "Check token") { Task { await loadCatalog() } }
                    .buttonStyle(QuietButton()).disabled(checking || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.system(size: 11)).foregroundStyle(Palette.green)
            if editingToken && provider == model.providerID {
                Button("Keep saved token") { editingToken = false; token = ""; Task { await loadCatalog() } }
                    .buttonStyle(.plain).foregroundStyle(Palette.green).font(.system(size: 11)).disabled(checking)
            }
        }.padding(17).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
    }

    private var tokenInstructions: String {
        switch provider {
        case .ticktick: return "In TickTick on the web, open Settings, then Account, then API Token."
        case .todoist: return "In Todoist, open Settings, then Integrations, then Developer, and copy your API token."
        case .notion: return "Create a personal access token with the Notion API capability. It uses your existing page access. Choose an existing task database, then map its properties below."
        }
    }

    private var documentationURL: URL {
        switch provider {
        case .ticktick: return URL(string: "https://developer.ticktick.com/docs/index.html#/openapi")!
        case .todoist: return URL(string: "https://developer.todoist.com/api/v1/")!
        case .notion: return URL(string: "https://developers.notion.com/guides/connections-and-tokens/personal-access-tokens")!
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(provider == .notion ? "Task database" : "New tasks go to", selection: $destinationID) {
                    Text(provider == .notion ? "Choose a database / data source" : "Choose a destination").tag("")
                    ForEach(catalog.destinations) { Text($0.name).tag($0.id) }
                }.accessibilityLabel("\(provider.displayName) destination").disabled(checking)
                    .onChange(of: destinationID) { _, _ in resetMapping() }
                if checking { ProgressView().controlSize(.small) }
                else {
                    Button { Task { await loadCatalog() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(Palette.green).accessibilityLabel("Refresh destinations")
                }
            }
            if provider == model.providerID && provider != .notion && model.connected {
                Text("Changing the destination applies to new tasks. Tasks already synced stay in their current lists or projects.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }
        }
    }

    private var notionMapping: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Database properties")
            propertyPicker("Title", selection: $titlePropertyID, types: ["title"])
            propertyPicker("Completion", selection: $statusPropertyID, types: ["status", "select", "checkbox"])
                .onChange(of: statusPropertyID) { _, _ in
                    if !(statusProperty?.options.contains(openStatus) ?? false) { openStatus = "" }
                    if !(statusProperty?.options.contains(completedStatus) ?? false) { completedStatus = "" }
                }
            if let property = statusProperty, property.type != "checkbox" {
                Picker("Open status", selection: $openStatus) {
                    Text("Choose open status").tag("")
                    ForEach(property.options, id: \.self) { Text($0).tag($0) }
                }
                Picker("Completed status", selection: $completedStatus) {
                    Text("Choose completed status").tag("")
                    ForEach(property.options, id: \.self) { Text($0).tag($0) }
                }
            }
            propertyPicker("Due date", selection: $duePropertyID, types: ["date"])
            propertyPicker("Description", selection: $descriptionPropertyID, types: ["rich_text"], optional: true)
            Text("Checkbox checked means completed. Status and select properties need distinct open and completed options. Description is optional; Hawkeye only edits mapped properties and leaves page content untouched. Changing the database resets sync links while keeping saved tasks. Property mapping changes keep existing page links.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            Link("Notion personal access token guide", destination: documentationURL)
                .font(.system(size: 11)).foregroundStyle(Palette.green)
        }.disabled(checking).padding(17).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
    }

    private func propertyPicker(_ label: String, selection: Binding<String>, types: [String], optional: Bool = false) -> some View {
        Picker(label, selection: selection) {
            Text(optional ? "Keep description only in Hawkeye" : "Choose a property").tag("")
            ForEach(source?.properties.filter { types.contains($0.type) } ?? []) { Text($0.name).tag($0.id) }
        }
    }

    private var uncertainCreations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Check Notion creations")
            Text("Notion may have created these tasks before the connection was interrupted. Check your database. Attach the existing page ID, or retry only after confirming no page was created.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            ForEach(model.uncertainNotionTasks) { task in
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title).font(.system(size: 12))
                    TextField("Existing Notion page ID", text: Binding(get: { pageIDs[task.id] ?? "" }, set: { pageIDs[task.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Attach existing page") {
                            perform { try await model.attachNotionCreation(task.id, pageID: pageIDs[task.id] ?? "") }
                        }.disabled((pageIDs[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("No page exists. Retry creation") { perform { try await model.retryNotionCreation(task.id) } }
                    }.font(.system(size: 11))
                }
            }
        }.disabled(checking).padding(17).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
    }

    private func clearCatalog() {
        catalog = ConnectionCatalog(destinations: [])
        destinationID = ""
        message = nil
    }

    private func resetDraft() {
        token = ""
        editingToken = false
        clearCatalog()
        if provider == model.providerID && model.connected { Task { await loadCatalog() } }
    }

    private func resetMapping() {
        let saved = destinationID == model.projectID && provider == model.providerID ? model.connection?.notionMapping : nil
        titlePropertyID = saved?.titlePropertyID ?? source?.properties.first { $0.type == "title" }?.id ?? ""
        statusPropertyID = saved?.statusPropertyID ?? source?.properties.first { ["status", "select", "checkbox"].contains($0.type) }?.id ?? ""
        duePropertyID = saved?.duePropertyID ?? source?.properties.first { $0.type == "date" }?.id ?? ""
        descriptionPropertyID = saved?.descriptionPropertyID ?? ""
        openStatus = saved?.openStatus ?? ""
        completedStatus = saved?.completedStatus ?? ""
    }

    private func loadCatalog() async {
        checking = true
        message = nil
        do {
            catalog = try await model.discover(provider: provider, token: enteringToken ? token : nil)
            if provider == model.providerID && catalog.destinations.contains(where: { $0.id == model.projectID }) {
                destinationID = model.projectID
            } else if catalog.destinations.count == 1 { destinationID = catalog.destinations[0].id }
            else { destinationID = "" }
            resetMapping()
            if catalog.destinations.isEmpty {
                message = provider == .notion ? "No accessible task databases found. Check the PAT's page access and refresh."
                    : "No writable destinations found. Create a list or project in \(provider.displayName), then check again."
            }
        } catch { message = error.localizedDescription }
        checking = false
    }

    private func save() {
        guard let destination = selectedDestination else { return }
        perform {
            try await model.connect(provider: provider, token: enteringToken ? token : nil,
                                    destination: destination, notionMapping: mapping)
            dismiss()
        }
    }

    private func disconnect() {
        perform { try await model.disconnect(); dismiss() }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        checking = true
        message = nil
        Task {
            do { try await action() }
            catch { message = error.localizedDescription }
            checking = false
        }
    }
}
