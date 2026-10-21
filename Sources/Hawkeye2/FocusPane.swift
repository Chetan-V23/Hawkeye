import SwiftUI

struct FocusPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            EyeArtwork(focused: model.activeTaskID != nil)
                .padding(.bottom, 28)
            Text(model.userFocus.snooze != nil ? "Take a breath." : model.activeTaskID != nil ? "One thing." : "Room to breathe.")
                .font(.system(size: 20, design: .serif)).multilineTextAlignment(.center)
            if let snooze = model.userFocus.snooze {
                Text("Paused until \(snooze.until.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 12)
            } else if let task = model.activeTask {
                Text(task.title).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineLimit(4).multilineTextAlignment(.center).padding(.top, 12)
            }
            Spacer()
            #if DEBUG
            HStack {
                Spacer()
                Button { openWindow(id: "activity") } label: {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help("Open developer activity log").accessibilityLabel("Open activity log")
            }
            #endif
        }.padding(.horizontal, 18).padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.sidebar.opacity(0.45))
    }
}

struct EyeArtwork: View {
    let focused: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Palette.line, lineWidth: 1).frame(width: 90, height: 90)
            Circle().stroke(Palette.line.opacity(0.5), lineWidth: 1).frame(width: 116, height: 116)
            EyeOutline(open: focused)
                .stroke(Palette.green, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 65, height: 38)
            if focused {
                Circle().stroke(Palette.green, lineWidth: 1.7).frame(width: 20, height: 20)
                Circle().fill(Palette.green).frame(width: 7, height: 7)
            }
        }.frame(width: 116, height: 116)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(focused ? "Focused eye" : "Relaxed eye")
    }
}

private struct EyeOutline: Shape {
    let open: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: h * 0.5))
        if open {
            path.addCurve(to: CGPoint(x: w, y: h * 0.5), control1: CGPoint(x: w * 0.3, y: -h * 0.12), control2: CGPoint(x: w * 0.7, y: -h * 0.12))
            path.addCurve(to: CGPoint(x: 0, y: h * 0.5), control1: CGPoint(x: w * 0.7, y: h * 1.12), control2: CGPoint(x: w * 0.3, y: h * 1.12))
        } else {
            path.addCurve(to: CGPoint(x: w, y: h * 0.5), control1: CGPoint(x: w * 0.3, y: h * 1.05), control2: CGPoint(x: w * 0.7, y: h * 1.05))
            for x in [0.2, 0.5, 0.8] {
                let y = h * (x == 0.5 ? 0.9 : 0.77)
                path.move(to: CGPoint(x: w * x, y: y))
                path.addLine(to: CGPoint(x: w * x + (x - 0.5) * 12, y: y + 7))
            }
        }
        return path
    }
}
