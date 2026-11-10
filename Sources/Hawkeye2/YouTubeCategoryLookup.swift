import Foundation

enum YouTubeCategoryLookupError: Error {
    case unavailable, staleTab, responseTooLarge, expired
}

@MainActor
protocol YouTubePageSourceReading: Sendable {
    func youtubePageSource(for tab: BrowserTab, in browser: ScriptableBrowser,
                           application: ForegroundApplication, before deadline: Date) async throws -> String
}

protocol YouTubeCategoryResolving: Sendable {
    func categoryIDs(for tab: BrowserTab, in browser: ScriptableBrowser,
                     application: ForegroundApplication, before deadline: Date) async throws -> Set<String>
}

actor YouTubeCategoryResolver: YouTubeCategoryResolving {
    typealias FetchHTML = @Sendable (URL, Date) async throws -> String
    private struct CachedCategory {
        let ids: Set<String>
        let expiresAt: Date
    }
    private let sourceReader: any YouTubePageSourceReading
    private let fetchHTML: FetchHTML
    private var cache: [String: CachedCategory] = [:]

    init(sourceReader: any YouTubePageSourceReading,
         fetchHTML: @escaping FetchHTML = { url, deadline in
             try await YouTubeCategoryResolver.fetchYouTubeHTML(url, before: deadline)
         }) {
        self.sourceReader = sourceReader
        self.fetchHTML = fetchHTML
    }

    func categoryIDs(for tab: BrowserTab, in browser: ScriptableBrowser,
                     application: ForegroundApplication, before deadline: Date) async throws -> Set<String> {
        try Task.checkCancellation()
        guard Date() < deadline else { throw YouTubeCategoryLookupError.expired }
        guard let videoID = YouTubeLocation(tab.url).videoID else { return [] }
        if let saved = cache[videoID], Date() < saved.expiresAt { return saved.ids }
        let lookupDeadline = min(deadline, Date().addingTimeInterval(4))
        var ids: Set<String> = []
        do {
            let html = try await sourceReader.youtubePageSource(for: tab, in: browser,
                application: application, before: min(lookupDeadline, Date().addingTimeInterval(1.5)))
            ids = try Self.categoryIDs(in: html, videoID: videoID)
        } catch YouTubeCategoryLookupError.staleTab {
            throw YouTubeCategoryLookupError.staleTab
        } catch {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        if ids.isEmpty, Date() < lookupDeadline {
            do {
                // Same no-key YouTube watch-page lookup as category_lookup.py's default source.
                let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=en")!
                let html = try await fetchBeforeDeadline(url, before: lookupDeadline)
                ids = try Self.categoryIDs(in: html, videoID: videoID)
            } catch {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        guard Date() < deadline else { throw YouTubeCategoryLookupError.expired }
        cache = cache.filter { Date() < $0.value.expiresAt }
        if cache.count >= 128, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        // Briefly retain failed lookups too, so many unavailable tabs cannot starve later tabs.
        cache[videoID] = CachedCategory(ids: ids, expiresAt: Date().addingTimeInterval(ids.isEmpty ? 15 : 300))
        return ids
    }

    private func fetchBeforeDeadline(_ url: URL, before deadline: Date) async throws -> String {
        let fetchHTML = fetchHTML
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await fetchHTML(url, deadline) }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                throw YouTubeCategoryLookupError.unavailable
            }
            defer { group.cancelAll() }
            guard let html = try await group.next() else { throw YouTubeCategoryLookupError.unavailable }
            return html
        }
    }

    nonisolated static func categoryIDs(in html: String, videoID: String) throws -> Set<String> {
        // Extract one balanced JSON object; braces inside strings must not end the response.
        let pattern = #"\bytInitialPlayerResponse\s*=\s*"#
        guard let marker = html.range(of: pattern, options: .regularExpression),
              marker.upperBound < html.endIndex, html[marker.upperBound] == "{" else {
            throw YouTubeCategoryLookupError.unavailable
        }
        let start = marker.upperBound
        var depth = 0, quoted = false, escaped = false
        for index in html[start...].indices {
            let character = html[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else {
                if character == "\"" { quoted = true }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let json = Data(html[start...index].utf8)
                        let player = try JSONDecoder().decode(PlayerResponse.self, from: json)
                        guard player.videoDetails?.videoId == videoID,
                              let category = player.microformat?.playerMicroformatRenderer?.category else {
                            throw YouTubeCategoryLookupError.unavailable
                        }
                        let ids = YouTubeCategory.matchingIDs(for: category)
                        guard !ids.isEmpty else { throw YouTubeCategoryLookupError.unavailable }
                        return ids
                    }
                }
            }
        }
        throw YouTubeCategoryLookupError.unavailable
    }

    private struct PlayerResponse: Decodable {
        struct Details: Decodable { let videoId: String? }
        struct Microformat: Decodable {
            struct Renderer: Decodable { let category: String? }
            let playerMicroformatRenderer: Renderer?
        }
        let videoDetails: Details?
        let microformat: Microformat?
    }

    private nonisolated static func fetchYouTubeHTML(_ url: URL, before deadline: Date) async throws -> String {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw YouTubeCategoryLookupError.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: min(2.5, remaining))
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw YouTubeCategoryLookupError.unavailable
        }
        let maximumBytes = 8 * 1024 * 1024
        guard response.expectedContentLength <= maximumBytes else { throw YouTubeCategoryLookupError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard Date() < deadline else { throw YouTubeCategoryLookupError.unavailable }
            guard data.count < maximumBytes else { throw YouTubeCategoryLookupError.responseTooLarge }
            if data.count.isMultiple(of: 65536) { try Task.checkCancellation() }
            data.append(byte)
        }
        try Task.checkCancellation()
        return String(decoding: data, as: UTF8.self)
    }
}
