#if DEBUG
import SwiftUI
import AppKit

struct ActivityLogView: View {
    @ObservedObject var log: ActivityLog

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Activity").font(.system(size: 28, design: .serif))
                Spacer()
                Button("Open log file") { NSWorkspace.shared.open(log.fileURL) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([log.fileURL]) }
            }
            Text(log.fileURL.path).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.muted).textSelection(.enabled)
            if let error = log.fileError {
                Text("Could not write log file. \(error)").foregroundStyle(Palette.orange)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(log.entries) { entry in
                            HStack(alignment: .top, spacing: 14) {
                                Text(entry.date, format: .dateTime.hour().minute().second()).foregroundStyle(Palette.muted)
                                    .frame(width: 88, alignment: .leading)
                                Text(entry.category).foregroundStyle(Palette.green).frame(width: 100, alignment: .leading)
                                Text(entry.message).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(entry.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: log.entries.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }.onAppear {
                    if let id = log.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }.padding(24).background(Palette.background).foregroundStyle(Palette.text)
    }
}
#endif
