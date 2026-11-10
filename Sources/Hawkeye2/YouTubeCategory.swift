import Foundation

struct YouTubeCategory: Equatable, Identifiable, Sendable {
    let id: String
    let name: String

    // Catalog from hawkeye_llm_eval/YTCategorychecker/youtube_categories.txt.
    static let all: [Self] = [
        .init(id: "1", name: "Film & Animation"),
        .init(id: "2", name: "Autos & Vehicles"),
        .init(id: "10", name: "Music"),
        .init(id: "15", name: "Pets & Animals"),
        .init(id: "17", name: "Sports"),
        .init(id: "19", name: "Travel & Events"),
        .init(id: "20", name: "Gaming"),
        .init(id: "22", name: "People & Blogs"),
        .init(id: "23", name: "Comedy"),
        .init(id: "24", name: "Entertainment"),
        .init(id: "25", name: "News & Politics"),
        .init(id: "26", name: "Howto & Style"),
        .init(id: "27", name: "Education"),
        .init(id: "28", name: "Science & Technology"),
        .init(id: "29", name: "Nonprofits & Activism"),
        .init(id: "18", name: "Short Movies"),
        .init(id: "21", name: "Videoblogging"),
        .init(id: "30", name: "Movies"),
        .init(id: "31", name: "Anime/Animation"),
        .init(id: "32", name: "Action/Adventure"),
        .init(id: "33", name: "Classics"),
        .init(id: "34", name: "Comedy"),
        .init(id: "35", name: "Documentary"),
        .init(id: "36", name: "Drama"),
        .init(id: "37", name: "Family"),
        .init(id: "38", name: "Foreign"),
        .init(id: "39", name: "Horror"),
        .init(id: "40", name: "Sci-Fi/Fantasy"),
        .init(id: "41", name: "Thriller"),
        .init(id: "42", name: "Shorts"),
        .init(id: "43", name: "Shows"),
        .init(id: "44", name: "Trailers")
    ]

    static let choices: [Self] = all.reduce(into: [Self]()) { categories, category in
        if !categories.contains(where: { $0.name == category.name }) { categories.append(category) }
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    static func whitelisted(in ids: [String]) -> [Self] {
        let whitelist = Set(ids)
        return choices.filter { !matchingIDs(for: $0.name).isDisjoint(with: whitelist) }
    }

    static func matchingIDs(for name: String) -> Set<String> {
        Set(all.filter { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }.map(\.id))
    }
}

struct YouTubeCategoryPolicy: Codable, Equatable, Sendable {
    var isEnabled = false
    var whitelist: [String] = ["27"]

    func blocks(_ rawURL: String, categoryIDs: Set<String>) -> Bool {
        let location = YouTubeLocation(rawURL)
        guard isEnabled, location.videoID != nil else { return false }
        // Names can identify multiple historical IDs (e.g. Comedy). Require all candidates.
        return categoryIDs.isEmpty || !categoryIDs.isSubset(of: Set(whitelist))
    }
}

struct YouTubeLocation: Sendable {
    let isYouTube: Bool
    let videoID: String?

    init(_ rawURL: String) {
        guard let url = URLComponents(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let rawHost = url.host?.lowercased() else {
            isYouTube = false; videoID = nil; return
        }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let shortLink = host == "youtu.be" || host == "www.youtu.be"
        isYouTube = shortLink || host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
        guard isYouTube else { videoID = nil; return }
        let parts = url.path.split(separator: "/")
        let candidate: String?
        if shortLink, parts.count == 1 { candidate = String(parts[0]) }
        else if url.path == "/watch" { candidate = url.queryItems?.first { $0.name == "v" }?.value }
        else if parts.count == 2, ["shorts", "live", "embed", "v"].contains(String(parts[0])) { candidate = String(parts[1]) }
        else { candidate = nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        videoID = candidate.flatMap { value in
            value.utf8.count == 11 && value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
        }
    }
}
