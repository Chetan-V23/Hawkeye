import SwiftUI
import HawkeyeCore

struct DeferTaskView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let task: TodoTask
    @State private var start = TaskScheduleSelection.nextHalfHour()
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Eyebrow(text: "Task schedule")
            Text("Reschedule task").font(.system(size: 30, design: .serif))
            Text(task.title).font(.system(size: 14, weight: .medium)).lineLimit(3)
            TaskScheduleButton(date: $start).accessibilityLabel("New task start time")
            Text("Duration: \(Int(task.effectiveDuration / 60)) minutes. The new start time syncs to the connected app.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            if start <= now {
                Text("Choose a start time in the future.").font(.system(size: 12)).foregroundStyle(Palette.orange)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Defer task") {
                    model.deferTask(task, to: start) { success in if success { dismiss() } }
                }.buttonStyle(QuietButton()).keyboardShortcut(.defaultAction)
                    .disabled(model.saving || start <= now)
            }
        }.padding(30).frame(width: 470)
            .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}
