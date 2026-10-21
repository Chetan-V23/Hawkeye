import SwiftUI
import HawkeyeCore

struct TaskComposer: View {
    @EnvironmentObject private var model: AppModel
    @State private var title = ""
    @State private var taskDescription = ""
    @State private var hasDueDate = true
    @State private var dueAt = TaskScheduleSelection.nextHalfHour()
    @State private var hasSuggestedDueDate = true
    @State private var durationMinutes = 0
    @State private var showDetails = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("What would you like to do?", text: $title)
                .font(.system(size: 16)).textFieldStyle(.plain)
                .focused($titleFocused).onSubmit(addTask)
                .accessibilityLabel("New task title")
                .onChange(of: title) { _, _ in refreshStaleSuggestion() }
                .onChange(of: titleFocused) { _, focused in
                    if focused { refreshStaleSuggestion() }
                }
            if showDetails {
                TextField("Add a description", text: $taskDescription, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel("New task description")
                Toggle("Start time", isOn: $hasDueDate).toggleStyle(.checkbox)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 12) {
                if hasDueDate {
                    TaskScheduleButton(date: Binding(get: { dueAt }, set: {
                        dueAt = $0
                        hasSuggestedDueDate = false
                    }))
                        .accessibilityLabel("New task start date and time")
                } else {
                    Label("No start time", systemImage: "calendar").foregroundStyle(Palette.muted)
                }
                TaskDurationButton(minutes: $durationMinutes)
                Spacer(minLength: 4)
                Button { showDetails.toggle() } label: {
                    Image(systemName: showDetails ? "chevron.up" : "slider.horizontal.3")
                }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help(showDetails ? "Hide details" : "Description and start time")
                    .accessibilityLabel("Task details")
                Button(action: addTask) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .medium))
                        .frame(width: 33, height: 33)
                        .background(canAdd ? Palette.green : Palette.muted.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Palette.background)
                }.buttonStyle(.plain).disabled(!canAdd || model.saving)
                    .help("Add task · Return").accessibilityLabel("Add task")
            }.font(.system(size: 11))
        }.padding(19).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
            .onAppear {
                if hasSuggestedDueDate { dueAt = TaskScheduleSelection.nextHalfHour() }
            }
    }

    private var canAdd: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func refreshStaleSuggestion() {
        let now = Date()
        if hasSuggestedDueDate, dueAt <= now {
            dueAt = TaskScheduleSelection.nextHalfHour(after: now)
        }
    }

    private func addTask() {
        guard canAdd, !model.saving else { return }
        refreshStaleSuggestion()
        let submittedTitle = title
        let submittedDescription = taskDescription
        let submittedDueAt = hasDueDate ? dueAt : nil
        let submittedDuration = durationMinutes > 0 ? TimeInterval(durationMinutes * 60) : nil
        model.add(title: submittedTitle, description: submittedDescription, dueAt: submittedDueAt,
                  duration: submittedDuration) { succeeded in
            if succeeded {
                title = ""
                taskDescription = ""
                dueAt = TaskScheduleSelection.nextHalfHour()
                hasSuggestedDueDate = true
                titleFocused = true
            }
        }
    }
}

struct TaskEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let task: TodoTask
    @State private var title: String
    @State private var taskDescription: String
    @State private var dueAt: Date
    @State private var hasDueDate: Bool
    @State private var durationMinutes: Int

    init(task: TodoTask) {
        self.task = task
        _title = State(initialValue: task.title)
        _taskDescription = State(initialValue: task.taskDescription)
        _dueAt = State(initialValue: task.dueAt ?? TaskScheduleSelection.nextHalfHour())
        _hasDueDate = State(initialValue: task.dueAt != nil)
        _durationMinutes = State(initialValue: Int((task.duration ?? 0) / 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Eyebrow(text: "A LITTLE ADJUSTMENT")
            Text("Edit your task.").font(.system(size: 30, design: .serif))
            Form {
                TextField("Title", text: $title).accessibilityLabel("Edit task title")
                TextField("Description", text: $taskDescription, axis: .vertical).lineLimit(3...5)
                Toggle("Start time", isOn: $hasDueDate)
                if hasDueDate {
                    TaskScheduleButton(date: $dueAt)
                        .accessibilityLabel("Edit task start date and time")
                }
                Stepper("Duration · \(durationMinutes == 0 ? "\(Int(task.effectiveDuration / 60)) min by default" : "\(durationMinutes) min")",
                        value: $durationMinutes, in: 0...1440, step: 5)
                Text("Created \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save changes") {
                    model.update(task, title: title, description: taskDescription,
                                 dueAt: hasDueDate ? dueAt : nil,
                                 duration: durationMinutes == 0 ? nil : TimeInterval(durationMinutes * 60)) { success in
                        if success { dismiss() }
                    }
                }.buttonStyle(QuietButton()).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.saving)
            }
        }.padding(30).frame(width: 510)
            .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
    }
}
