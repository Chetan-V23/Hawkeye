import SwiftUI
import AVFAudio
import HawkeyeCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingTask: TodoTask?
    @State private var deferringTask: TodoTask?
    @State private var filter: TaskFilter = .all

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 2)
            HStack(spacing: 0) {
                completedPane.frame(width: available * 2 / 7)
                Rectangle().fill(Palette.line).frame(width: 1)
                taskPane.frame(width: available * 4 / 7)
                Rectangle().fill(Palette.line).frame(width: 1)
                FocusPane().frame(width: available / 7)
            }
        }
        .background(Palette.background).foregroundStyle(Palette.text)
        .font(.system(size: 13)).tint(Palette.green)
        .sheet(item: $editingTask) { task in TaskEditor(task: task).environmentObject(model) }
        .sheet(item: $deferringTask) { task in DeferTaskView(task: task).environmentObject(model) }
        .alert("Something needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var completedPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "eye").font(.system(size: 25, weight: .medium)).foregroundStyle(Palette.green)
                Text("hawkeye").font(.system(size: 24, weight: .semibold, design: .rounded)).tracking(-1)
                Text("02").font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.green).padding(5)
                    .background(Palette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }.padding(.bottom, 46)
            Eyebrow(text: "THE DONE LIST")
            HStack(alignment: .firstTextBaseline) {
                Text("Look at you go.").font(.system(size: 25, weight: .medium, design: .serif))
                Spacer(minLength: 4)
                Text("\(model.completedTasks.count)").monospacedDigit().foregroundStyle(Palette.muted)
            }.padding(.top, 12)
            Text("Small wins. Real progress.").foregroundStyle(Palette.muted).padding(.top, 9).padding(.bottom, 25)
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.completedTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "checkmark.seal").font(.system(size: 28, weight: .ultraLight))
                            Text("Your first win belongs here.").font(.system(size: 14))
                            Text("Complete a task to start your done list.").font(.system(size: 12)).lineSpacing(4)
                        }.foregroundStyle(Palette.muted).padding(.top, 8)
                    }
                    ForEach(model.completedTasks) { task in
                        HStack(alignment: .top, spacing: 12) {
                            Button { model.reopen(task.id) } label: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green.opacity(0.7))
                            }.buttonStyle(.plain).disabled(model.saving)
                                .help("Move back to to-dos")
                                .accessibilityLabel("Reopen \(task.title)")
                            VStack(alignment: .leading, spacing: 7) {
                                Text(task.title).strikethrough().foregroundStyle(Palette.muted).lineLimit(3)
                                if let completedAt = task.completedAt {
                                    Text(completedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.7))
                                }
                                if model.isPending(task) { syncLabel("Sync pending", pending: true) }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "leaf").foregroundStyle(Palette.green)
                Text("A little further along.").font(.system(size: 21, design: .serif))
                Text("ONE THING AT A TIME.").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(Palette.muted)
            }.padding(21).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 7) {
                Circle().fill(Palette.green).frame(width: 5, height: 5)
                Text("Local by default.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(.top, 24)
        }
        .padding(.horizontal, 29).padding(.top, 37).padding(.bottom, 25)
        .background(Palette.sidebar)
    }

    private var taskPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.now, format: .dateTime.weekday(.wide).month(.wide).day())
                    .textCase(.uppercase).tracking(1.5).font(.system(size: 10, weight: .medium))
                Spacer()
            }.foregroundStyle(Palette.muted).padding(.bottom, 30)
            Text("Make room for\nwhat matters.")
                .font(.system(size: 46, weight: .regular, design: .serif)).tracking(-1.7).lineSpacing(-2)
            Text("One task. A little more space to think.")
                .foregroundStyle(Palette.muted).padding(.top, 13).padding(.bottom, 25)
            TaskComposer().environmentObject(model).disabled(!model.ready)
            HStack(spacing: 9) {
                Eyebrow(text: "ON YOUR HORIZON")
                Text("\(visibleTasks.count)").font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.card, in: Capsule()).foregroundStyle(Palette.muted)
                Spacer()
                Menu {
                    Picker("Show tasks", selection: $filter) {
                        ForEach(TaskFilter.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.inline)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundStyle(Palette.green).font(.system(size: 15))
                        Text(filter.rawValue).font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                    }.padding(.horizontal, 13).padding(.vertical, 12)
                        .background(Palette.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(Palette.text)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Filter tasks")
                    .accessibilityValue(filter.rawValue)
                    .help("Choose which tasks to show")
            }.padding(.top, 28).padding(.bottom, 14)
            ScrollView {
                LazyVStack(spacing: 9) {
                    if visibleTasks.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "leaf").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(Palette.green)
                            Text(filter == .all ? "A clear horizon." : "Nothing here just now.")
                                .font(.system(size: 23, design: .serif))
                            Text(filter == .all ? "Add one thing you'd like to make progress on." : "Choose All tasks to see the rest.")
                                .foregroundStyle(Palette.muted).font(.system(size: 12))
                        }.frame(maxWidth: .infinity).padding(.vertical, 34)
                    }
                    ForEach(visibleTasks) { task in
                        TaskRow(task: task, edit: { editingTask = task }, deferTask: { deferringTask = task })
                            .environmentObject(model)
                    }
                }.padding(.bottom, 8)
            }
            Rectangle().fill(Palette.line).frame(height: 1).padding(.top, 12)
            HStack(spacing: 9) {
                Circle().fill(model.connected ? Palette.green : Palette.muted).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.connected ? "TickTick connected" : "Your tasks, on your Mac")
                        .font(.system(size: 11, weight: .medium))
                    Text(model.syncStatus).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        .lineLimit(2).help(model.syncStatus)
                }
                Spacer()
                if model.connected {
                    Button { model.syncNow() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }.buttonStyle(.plain).disabled(model.syncing).help("Sync now")
                        .accessibilityLabel("Sync now").foregroundStyle(Palette.green)
                }
                Button { model.showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }.buttonStyle(.plain).foregroundStyle(Palette.muted).help("TickTick settings")
                    .accessibilityLabel("TickTick settings")
            }.padding(.top, 17)
        }.padding(.horizontal, 36).padding(.top, 39).padding(.bottom, 24)
    }

    private var visibleTasks: [TodoTask] {
        model.pendingTasks.filter { task in
            switch filter {
            case .all: return true
            case .due: return task.dueAt.map { $0 <= model.now } ?? false
            case .today:
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: model.now)) ?? model.now
                return task.dueAt.map { $0 < tomorrow } ?? false
            }
        }
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case all = "All tasks", due = "Due now", today = "Today"
    var id: Self { self }
}

func syncLabel(_ title: String, pending: Bool = false) -> some View {
    Label(title, systemImage: pending ? "arrow.triangle.2.circlepath" : "checkmark.circle")
        .font(.system(size: 9)).foregroundStyle(pending ? Palette.orange : Palette.blue)
}

struct TaskRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completionPhase: CompletionPhase = .idle
    let task: TodoTask
    let edit: () -> Void
    let deferTask: () -> Void

    private enum CompletionPhase {
        case idle, striking, popping
    }

    private static let completionSound: AVAudioPlayer? = {
        let resources = Bundle.main.url(forResource: "Hawkeye2_Hawkeye2", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? .module
        let sound = resources.url(forResource: "coin", withExtension: "wav")
            .flatMap { try? AVAudioPlayer(contentsOf: $0) }
        sound?.volume = 0.65
        sound?.prepareToPlay()
        return sound
    }()

    private var active: Bool { model.isActive(task) }
    private var overdue: Bool { task.isOverdue(at: model.now) }

    private func complete() {
        guard completionPhase == .idle else { return }
        Self.completionSound?.currentTime = 0
        Self.completionSound?.play()

        if reduceMotion {
            completionPhase = .striking
            saveCompletion()
            return
        }

        withAnimation(.linear(duration: 0.2), completionCriteria: .removed) {
            completionPhase = .striking
        } completion: {
            withAnimation(.easeIn(duration: 0.1), completionCriteria: .removed) {
                completionPhase = .popping
            } completion: {
                saveCompletion()
            }
        }
    }

    private func saveCompletion() {
        model.complete(task.id) { success in
            if !success { completionPhase = .idle }
        }
    }

    private var title: some View {
        Text(task.title).font(.system(size: 14, weight: .medium)).lineLimit(3)
    }

    @ViewBuilder
    private var taskOptions: some View {
        if !active {
            Button("Start Now") { model.startNow(task) }
                .disabled(model.activeTaskID != nil)
                .help(model.activeTaskID != nil ? "Another task is active." : "Start this task now and sync its new start time to TickTick.")
            if model.activeTaskID != nil {
                Text("Another task is active").font(.caption)
            }
        }
        if model.canPause(task) {
            Menu("Pause") {
                ForEach([2, 3, 5], id: \.self) { minutes in
                    Button("\(minutes) minutes") { model.pause(task.id, minutes: minutes) }
                }
            }
        }
        Button("Defer", action: deferTask)
        if !active && !model.userFocus.snoozedTaskIDs.contains(task.id) {
            Button("Edit task", action: edit)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Button(action: complete) {
                Image(systemName: completionPhase == .idle ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .ultraLight))
                    .foregroundStyle(completionPhase != .idle || active ? Palette.green : Palette.muted)
            }.buttonStyle(.plain).padding(.top, 1).help("Complete task")
                .accessibilityLabel("Complete \(task.title)")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if active {
                        Circle().fill(Palette.green).frame(width: 6, height: 6)
                            .accessibilityLabel("Active task")
                    }
                    title.overlay(alignment: .leading) {
                        title.strikethrough(true, color: Palette.green)
                            .mask {
                                Rectangle().scaleEffect(x: completionPhase == .idle ? 0 : 1, anchor: .leading)
                            }
                            .accessibilityHidden(true)
                    }
                }
                if !task.taskDescription.isEmpty {
                    Text(task.taskDescription).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let due = task.dueAt {
                        Label {
                            Text(due, format: .dateTime.month(.abbreviated).day().hour().minute())
                        } icon: { Image(systemName: "calendar") }
                        .foregroundStyle(overdue ? Palette.orange : Palette.muted)
                    } else {
                        Label("Anytime", systemImage: "calendar").foregroundStyle(Palette.muted)
                    }
                    Label("\(Int(task.effectiveDuration / 60)) min", systemImage: "clock").foregroundStyle(Palette.muted)
                    if active {
                        Text("Active").foregroundStyle(Palette.green)
                    } else if overdue {
                        Text("Overdue").foregroundStyle(Palette.orange)
                    } else if task.isWithinScheduledWindow(at: model.now) {
                        Text(model.userFocus.snooze != nil ? "Paused" : "Waiting").foregroundStyle(Palette.muted)
                    }
                    if model.isPending(task) { syncLabel("Pending", pending: true) }
                    else if model.isRemote(task) { syncLabel("TickTick") }
                }.font(.system(size: 10))
            }.frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: edit)
            Menu {
                taskOptions
            } label: { Image(systemName: "ellipsis").foregroundStyle(Palette.muted) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Options for \(task.title)")
        }.padding(17)
            .background(active ? Palette.green.opacity(0.055) : Palette.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Palette.green.opacity(0.3) : Palette.line))
            .contextMenu { taskOptions }
            .disabled(completionPhase != .idle || model.saving)
            .scaleEffect(completionPhase == .popping ? 0.01 : 1)
            .opacity(completionPhase == .popping ? 0 : 1)
            .onAppear { _ = Self.completionSound }
    }
}
