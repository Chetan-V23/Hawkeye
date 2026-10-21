import SwiftUI

struct TaskDurationButton: View {
    @Binding var minutes: Int
    @State private var showingCustomDuration = false
    private let presets = [20, 30, 60, 90, 120]

    var body: some View {
        Menu {
            Picker("Task duration", selection: $minutes) {
                Text("Default · 30 minutes").tag(0)
                ForEach(presets, id: \.self) { value in
                    Text(label(for: value)).tag(value)
                }
                if minutes > 0 && !presets.contains(minutes) {
                    Text("\(label(for: minutes)) (custom)").tag(minutes)
                }
            }.pickerStyle(.inline)
            Divider()
            Button("Custom…") {
                DispatchQueue.main.async { showingCustomDuration = true }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "clock").foregroundStyle(Palette.green).font(.system(size: 15))
                Text(minutes == 0 ? "30 min" : compactLabel)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 13).padding(.vertical, 12)
                .background(Palette.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Task duration").accessibilityValue(minutes == 0 ? "Default, 30 minutes" : label(for: minutes))
        .help("Choose a task duration")
        .background {
            Color.clear.popover(isPresented: $showingCustomDuration, arrowEdge: .bottom) {
                CustomTaskDurationPicker(minutes: $minutes, isPresented: $showingCustomDuration)
            }
        }
    }

    private var compactLabel: String {
        if minutes < 60 { return "\(minutes) min" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(remainder) min"
    }

    private func label(for value: Int) -> String {
        let hours = value / 60
        let remainder = value % 60
        let hourLabel = "\(hours) \(hours == 1 ? "hour" : "hours")"
        let minuteLabel = "\(remainder) \(remainder == 1 ? "minute" : "minutes")"
        if hours == 0 { return minuteLabel }
        return remainder == 0 ? hourLabel : "\(hourLabel) \(minuteLabel)"
    }
}

private struct CustomTaskDurationPicker: View {
    @Binding var minutes: Int
    @Binding var isPresented: Bool
    @State private var draft: String
    @FocusState private var inputFocused: Bool

    init(minutes: Binding<Int>, isPresented: Binding<Bool>) {
        _minutes = minutes
        _isPresented = isPresented
        _draft = State(initialValue: String(minutes.wrappedValue > 0 ? minutes.wrappedValue : 30))
    }

    private var validatedMinutes: Int? {
        guard let value = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...1440).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom duration").font(.system(size: 23, design: .serif))
            HStack(spacing: 10) {
                TextField("Minutes", text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .focused($inputFocused).onSubmit(apply)
                    .accessibilityLabel("Custom duration in minutes")
                Text("minutes").foregroundStyle(Palette.muted)
            }
            Text("Enter 1 to 1,440 minutes, up to 24 hours.")
                .font(.system(size: 11))
                .foregroundStyle(validatedMinutes == nil ? Palette.orange : Palette.muted)
            HStack {
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Set duration", action: apply)
                    .buttonStyle(QuietButton()).keyboardShortcut(.defaultAction)
                    .disabled(validatedMinutes == nil)
            }
        }.padding(20).frame(width: 290)
            .background(Palette.background).foregroundStyle(Palette.text)
            .preferredColorScheme(.dark)
            .onAppear { inputFocused = true }
    }

    private func apply() {
        guard let value = validatedMinutes else { return }
        minutes = value
        isPresented = false
    }
}
