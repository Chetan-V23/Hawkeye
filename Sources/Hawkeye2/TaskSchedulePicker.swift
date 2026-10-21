import SwiftUI
import HawkeyeCore
import Darwin

struct TaskScheduleButton: View {
    @Binding var date: Date
    @State private var showingPicker = false

    var body: some View {
        Button { showingPicker = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "calendar").foregroundStyle(Palette.green).font(.system(size: 15))
                Text("\(dayLabel) · \(date.formatted(.dateTime.hour().minute()))")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 13).padding(.vertical, 12)
                .background(Palette.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
        }
        .buttonStyle(.plain).foregroundStyle(Palette.text)
        .accessibilityLabel("Task start date and time").accessibilityValue(Text(date, format: .dateTime.month().day().hour().minute()))
        .help("Choose a start date and time")
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            TaskSchedulePicker(date: $date)
        }
    }

    private var dayLabel: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

enum SchedulePickerTab: String, CaseIterable { case time = "Time", date = "Date" }
private enum ClockField { case hour, minute }

struct TaskSchedulePicker: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskScheduleSelection
    @State private var tab: SchedulePickerTab
    @State private var clockField: ClockField = .hour
    @State private var visibleMonth: Date
    @State private var now = Date()
    private let initialTab: SchedulePickerTab
    private let calendar = Calendar.current

    init(date: Binding<Date>, initialTab: SchedulePickerTab = .time) {
        _date = date
        _draft = State(initialValue: TaskScheduleSelection(date: date.wrappedValue))
        _visibleMonth = State(initialValue: TaskScheduleSelection.monthStart(containing: date.wrappedValue))
        _tab = State(initialValue: initialTab)
        self.initialTab = initialTab
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Make time for it.").font(.system(size: 24, design: .serif))
                Text(validationMessage ?? "Choose when this task starts.")
                    .font(.system(size: 12)).foregroundStyle(validationMessage == nil ? Palette.muted : Palette.orange)
            }.fixedSize(horizontal: false, vertical: true)
            tabs
            Group {
                if tab == .time { timeContent }
                else { dateContent }
            }.frame(maxWidth: .infinity).frame(height: 400)
            Rectangle().fill(Palette.line).frame(height: 1)
            footer
        }
        .padding(22).frame(width: 430, height: 680)
        .background(Palette.background).foregroundStyle(Palette.text).tint(Palette.green)
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .onAppear {
            now = Date()
            draft = TaskScheduleSelection(date: date)
            visibleMonth = TaskScheduleSelection.monthStart(containing: date)
            tab = initialTab
            clockField = .hour
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(SchedulePickerTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Label(item.rawValue, systemImage: item == .time ? "clock" : "calendar")
                        .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 36)
                        .foregroundStyle(tab == item ? Palette.background : Palette.muted)
                        .background(tab == item ? Palette.green : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }.padding(4).background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
    }

    private var timeContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                timeDigits(String(format: "%02d", draft.hour12), field: .hour)
                Text(":").font(.system(size: 42, weight: .light)).foregroundStyle(Palette.muted)
                timeDigits(String(format: "%02d", draft.minute), field: .minute)
                VStack(spacing: 4) {
                    meridiem("AM", afternoon: false)
                    meridiem("PM", afternoon: true)
                }
                .padding(.leading, 12)
            }
            Text(clockField == .hour ? "Choose an hour" : "Choose minutes · drag for an exact time")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            ClockFace(field: clockField, value: clockField == .hour ? draft.hour % 12 : draft.minute,
                onSelect: { value in
                    if clockField == .hour { draft.selectHour12(value == 0 ? 12 : value) }
                    else { draft.minute = value }
                }, onFinish: { if clockField == .hour { clockField = .minute } })
                .frame(width: 276, height: 276).padding(.top, 2)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timeDigits(_ text: String, field: ClockField) -> some View {
        Button { clockField = field } label: {
            Text(text).font(.system(size: 45, weight: .light, design: .rounded)).monospacedDigit()
                .frame(width: 82, height: 68)
                .foregroundStyle(clockField == field ? Palette.green : Palette.text)
                .background(clockField == field ? Palette.green.opacity(0.09) : Palette.card, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .accessibilityLabel(field == .hour ? "Choose hour" : "Choose minute").accessibilityValue(text)
            .accessibilityAddTraits(clockField == field ? .isSelected : [])
    }

    private func meridiem(_ text: String, afternoon: Bool) -> some View {
        Button { draft.selectAfternoon(afternoon) } label: {
            Text(text).font(.system(size: 12, weight: .semibold)).frame(width: 46, height: 30)
                .foregroundStyle(draft.isAfternoon == afternoon ? Palette.green : Palette.muted)
                .background(draft.isAfternoon == afternoon ? Palette.green.opacity(0.12) : Palette.card, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(draft.isAfternoon == afternoon ? .isSelected : [])
    }

    private var dateContent: some View {
        let days = TaskScheduleSelection.monthGrid(containing: visibleMonth, calendar: calendar)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                quickDay("Today", offset: 0, icon: "sun.max")
                quickDay("Tomorrow", offset: 1, icon: "sun.horizon")
            }
            HStack {
                Text(visibleMonth, format: .dateTime.month(.wide).year()).font(.system(size: 18, weight: .medium, design: .rounded))
                Spacer()
                monthArrow("chevron.left", offset: -1)
                monthArrow("chevron.right", offset: 1)
            }.frame(height: 36)
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdaySymbols[index]).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity).frame(height: 16)
                }
            }
            VStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { column in
                            let index = row * 7 + column
                            if days.indices.contains(index), let day = days[index] {
                                CalendarDayButton(day: day, selected: calendar.isDate(day, inSameDayAs: draft.day)) { draft.day = day }
                                    .disabled(day < calendar.startOfDay(for: now))
                                    .opacity(day < calendar.startOfDay(for: now) ? 0.3 : 1)
                            } else { Color.clear.frame(maxWidth: .infinity).frame(height: 40).accessibilityHidden(true) }
                        }
                    }
                }
            }.frame(height: 260)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    private func quickDay(_ title: String, offset: Int, icon: String) -> some View {
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
        let selected = calendar.isDate(day, inSameDayAs: draft.day)
        return Button {
            draft.day = day
            visibleMonth = TaskScheduleSelection.monthStart(containing: day)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(day, format: .dateTime.month(.abbreviated).day()).font(.system(size: 10)).opacity(0.7)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 13).frame(height: 52)
                .foregroundStyle(selected ? Palette.green : Palette.text)
                .background(selected ? Palette.green.opacity(0.10) : Palette.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Palette.green.opacity(0.35) : Palette.line))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func monthArrow(_ icon: String, offset: Int) -> some View {
        Button {
            if let month = calendar.date(byAdding: .month, value: offset, to: visibleMonth) { visibleMonth = month }
        } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 32, height: 32)
                .background(Palette.card, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(offset < 0 ? "Previous month" : "Next month")
    }

    private var validationMessage: String? {
        guard let selected = draft.resolved(calendar: calendar) else { return "This time is unavailable on the selected date." }
        return TaskScheduleSelection.isValidStart(selected, at: now) ? nil : "This time has passed. Choose a later date and time."
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.day, format: .dateTime.month(.abbreviated).day()).font(.system(size: 11)).foregroundStyle(Palette.muted)
                if let date = draft.resolved() {
                    Text(date, format: .dateTime.hour().minute()).font(.system(size: 14, weight: .medium))
                } else {
                    Text("Time unavailable on this date").font(.system(size: 10)).foregroundStyle(Palette.orange)
                }
            }
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted).keyboardShortcut(.cancelAction)
            Button {
                now = Date()
                guard let selected = draft.resolved(calendar: calendar),
                      TaskScheduleSelection.isValidStart(selected, at: now) else { return }
                date = selected
                dismiss()
            } label: {
                Text("Set start time").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 16).frame(height: 40)
                    .background(Palette.green, in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(Palette.background)
            }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(validationMessage != nil)
                .opacity(validationMessage != nil ? 0.4 : 1)
        }.frame(height: 44)
    }
}

private struct CalendarDayButton: View {
    let day: Date
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(day, format: .dateTime.day()).font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.background : Palette.text)
                .frame(width: 38, height: 38)
                .background(selected ? Palette.green : hovered ? Palette.card : .clear, in: Circle())
                .overlay(Circle().stroke(Calendar.current.isDateInToday(day) && !selected ? Palette.green.opacity(0.55) : .clear))
                .frame(maxWidth: .infinity).frame(height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).month(.wide).day().year()))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ClockFace: View {
    let field: ClockField
    let value: Int
    let onSelect: (Int) -> Void
    let onFinish: () -> Void
    private var divisions: Int { field == .hour ? 12 : 60 }
    private var selectedText: String { field == .hour ? String(value == 0 ? 12 : value) : String(format: "%02d", value) }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: size / 2, y: size / 2)
            let radius = size / 2 - 27
            let selection = position(index: value, divisions: divisions, center: center, radius: radius)
            ZStack {
                Circle().fill(Palette.card)
                ForEach(0..<60, id: \.self) { tick in
                    Capsule().fill(Palette.muted.opacity(tick % 5 == 0 ? 0.35 : 0.12))
                        .frame(width: 1, height: tick % 5 == 0 ? 5 : 2)
                        .offset(y: -size / 2 + 9).rotationEffect(.degrees(Double(tick) * 6))
                }
                Path { path in
                    path.move(to: center)
                    path.addLine(to: selection)
                }
                    .stroke(Palette.green, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                ForEach(0..<12, id: \.self) { index in
                    let number = field == .hour ? index : index * 5
                    let text = field == .hour ? String(index == 0 ? 12 : index) : String(format: "%02d", number)
                    Text(text).font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(number == value ? .clear : Palette.text)
                        .position(position(index: index, divisions: 12, center: center, radius: radius))
                }
                Circle().fill(Palette.green).frame(width: 42, height: 42)
                    .overlay(Text(selectedText).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Palette.background))
                    .position(selection)
                Circle().fill(Palette.green).frame(width: 7, height: 7)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                select(at: gesture.location, center: center)
            }.onEnded { gesture in
                if select(at: gesture.location, center: center) { onFinish() }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(field == .hour ? "Hour clock" : "Minute clock").accessibilityValue(selectedText)
            .accessibilityAdjustableAction { direction in
                if direction == .increment { adjust(1) }
                if direction == .decrement { adjust(-1) }
            }
            .focusable()
            .onKeyPress(.rightArrow) {
                adjust(1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                adjust(1)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                adjust(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                adjust(-1)
                return .handled
            }
        }
    }

    private func position(index: Int, divisions: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = Double(index) / Double(divisions) * 2 * Double.pi - Double.pi / 2
        return CGPoint(x: center.x + CGFloat(Darwin.cos(angle)) * radius,
                       y: center.y + CGFloat(Darwin.sin(angle)) * radius)
    }
    @discardableResult private func select(at point: CGPoint, center: CGPoint) -> Bool {
        let dx = point.x - center.x, dy = point.y - center.y
        guard hypot(dx, dy) >= 24,
              let index = TaskScheduleSelection.dialIndex(dx: dx, dy: dy, divisions: divisions) else { return false }
        onSelect(index)
        return true
    }
    private func adjust(_ step: Int) { onSelect((value + step + divisions) % divisions) }
}
