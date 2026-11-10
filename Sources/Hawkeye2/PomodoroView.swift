import SwiftUI
import HawkeyeCore

struct PomodoroView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showDurations = false

    private var running: Bool { model.pomodoro.session != nil }
    private var onBreak: Bool { model.pomodoro.interval?.phase == .breakTime }
    private var accent: Color { onBreak ? Palette.blue : Palette.green }
    private var configuration: PomodoroConfiguration {
        model.pomodoro.session?.configuration ?? model.pomodoro.configuration
    }
    private var remaining: TimeInterval {
        model.pomodoro.interval?.remaining(at: model.now) ?? configuration.duration(for: .focus)
    }
    private var progress: Double {
        guard let interval = model.pomodoro.interval else { return 1 }
        return min(1, remaining / interval.endsAt.timeIntervalSince(interval.startedAt))
    }
    private var countdown: String {
        let seconds = Int(ceil(remaining))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 4) {
                Eyebrow(text: "Pomodoro")
                Spacer(minLength: 0)
                Button { showDurations = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                        .frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help("Configure focus and break durations")
                    .accessibilityLabel("Pomodoro durations")
                    .popover(isPresented: $showDurations) {
                        PomodoroDurationsView(configuration: model.pomodoro.configuration, running: running) {
                            model.configurePomodoro($0)
                            showDurations = false
                        } cancel: { showDurations = false }
                    }
            }
            ZStack {
                Circle().stroke(Palette.line, lineWidth: 4)
                Circle().trim(from: 0, to: progress)
                    .stroke(accent.opacity(running ? 0.85 : 0.3), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 7) {
                    Text(onBreak ? "Break" : "Focus")
                        .font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(accent)
                    Text(countdown).font(.system(size: 30, weight: .light, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
            }.frame(width: 128, height: 128)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(onBreak ? "Pomodoro break remaining" : "Pomodoro focus remaining")
                .accessibilityValue(countdown)
            Text("\(configuration.focusMinutes) min focus · \(configuration.breakMinutes) min break")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                .lineLimit(1).minimumScaleFactor(0.75)
            Button {
                if running { model.stopPomodoro() } else { model.startPomodoro() }
            } label: {
                Label(running ? "Stop timer" : "Start focus", systemImage: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).foregroundStyle(accent)
                .accessibilityLabel(running ? "Stop Pomodoro" : "Start Pomodoro")
            if onBreak {
                Label("Drink a glass of water.", systemImage: "drop")
                    .font(.system(size: 11)).foregroundStyle(Palette.blue)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Circle().fill(model.isMonitoringActive ? Palette.green : Palette.muted).frame(width: 5, height: 5)
                Text(model.isMonitoringActive ? "Monitoring active" : "Monitoring idle")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.accessibilityElement(children: .combine)
        }
    }
}

private struct PomodoroDurationsView: View {
    let running: Bool
    let save: (PomodoroConfiguration) -> Void
    let cancel: () -> Void
    @State private var focus: String
    @State private var rest: String

    init(configuration: PomodoroConfiguration, running: Bool,
         save: @escaping (PomodoroConfiguration) -> Void, cancel: @escaping () -> Void) {
        self.running = running
        self.save = save
        self.cancel = cancel
        _focus = State(initialValue: String(configuration.focusMinutes))
        _rest = State(initialValue: String(configuration.breakMinutes))
    }

    private var configuration: PomodoroConfiguration? {
        guard let focus = Int(focus.trimmingCharacters(in: .whitespaces)),
              let rest = Int(rest.trimmingCharacters(in: .whitespaces)) else { return nil }
        return PomodoroConfiguration(focusMinutes: focus, breakMinutes: rest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pomodoro durations").font(.system(size: 18, design: .serif))
            durationField("Focus", text: $focus, range: PomodoroConfiguration.focusRange)
            durationField("Break", text: $rest, range: PomodoroConfiguration.breakRange)
            if configuration == nil {
                Text("Enter whole minutes within the ranges above.")
                    .font(.system(size: 11)).foregroundStyle(Palette.orange)
            }
            Text(running ? "Changes apply the next time you start the timer." : "Focus and break repeat until you stop the timer.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.plain).foregroundStyle(Palette.muted)
                Spacer()
                Button("Save") { if let configuration { save(configuration) } }
                    .buttonStyle(QuietButton()).disabled(configuration == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 280)
            .foregroundStyle(Palette.text).background(Palette.sidebar)
    }

    private func durationField(_ title: String, text: Binding<String>, range: ClosedRange<Int>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text("\(range.lowerBound) to \(range.upperBound) min").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer()
            TextField("Minutes", text: text).textFieldStyle(.roundedBorder).frame(width: 58)
                .accessibilityLabel("\(title) minutes")
            Text("min").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}
