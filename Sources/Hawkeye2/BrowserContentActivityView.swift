import SwiftUI

struct BrowserContentActivityView: View {
    let log: ActivityLog
    let attachment: ActivityBrowserContent
    @State private var expanded = false
    @State private var content: Content = .idle

    private enum Content {
        case idle, loading, unavailable
        case loaded(BrowserContentSnapshot)
    }

    var body: some View {
        DisclosureGroup("Browser text", isExpanded: $expanded) {
            switch content {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .unavailable:
                Text("Browser text is no longer available.").foregroundStyle(Palette.muted)
            case .loaded(let snapshot):
                BrowserContentDetailsView(snapshot: snapshot)
            }
        }
        .task(id: expanded) {
            guard expanded else { content = .idle; return }
            guard let url = log.retainedBrowserContentURL(attachment) else { content = .unavailable; return }
            content = .loading
            let read = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let data = try Data(contentsOf: url)
                let record = try JSONDecoder().decode(BrowserContentRecord.self, from: data)
                try Task.checkCancellation()
                return record.snapshot
            }
            do {
                let snapshot = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                try Task.checkCancellation()
                guard log.retainedBrowserContentURL(attachment) == url else { content = .unavailable; return }
                content = .loaded(snapshot)
            } catch is CancellationError {
            } catch { content = .unavailable }
        }
    }
}

struct BrowserContentDetailsView: View {
    let snapshot: BrowserContentSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = snapshot.pageTitle, !title.isEmpty { Text(title).fontWeight(.semibold) }
            if let url = snapshot.pageURL { Text(url.absoluteString).foregroundStyle(Palette.muted) }
            if snapshot.isTruncated {
                Text("Hawkeye could not read all the page text.").foregroundStyle(Palette.orange)
            }
            Text("Main content").fontWeight(.semibold)
            if let main = snapshot.mainContent {
                textPane(main.text)
            } else {
                Text("Hawkeye could not identify this page's main content.").foregroundStyle(Palette.muted)
            }
            DisclosureGroup("All page text") { textPane(snapshot.fullText) }
        }
        .font(.system(size: 12))
        .textSelection(.enabled)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func textPane(_ text: String) -> some View {
        ScrollView {
            Text(text).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: min(220, max(70, CGFloat(text.count / 60 + 1) * 18)))
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
    }
}
