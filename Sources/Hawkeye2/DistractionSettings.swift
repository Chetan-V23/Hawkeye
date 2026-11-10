import AppKit
import Foundation

enum DistractionSettingsError: LocalizedError {
    case invalidDomain, duplicateDomain, invalidApplication, ownApplication, duplicateApplication

    var errorDescription: String? {
        switch self {
        case .invalidDomain: return "Enter a website domain or an http or https URL, such as instagram.com."
        case .duplicateDomain: return "That website is already blocked."
        case .invalidApplication: return "Choose a Mac application with a bundle identifier."
        case .ownApplication: return "Hawkeye cannot block itself."
        case .duplicateApplication: return "That application is already blocked."
        }
    }
}

@MainActor
final class DistractionSettings: ObservableObject {
    @Published private(set) var policy: DistractionPolicy
    @Published private(set) var error: String?
    private let preferences: UserDefaults
    private let fileURL: URL?
    private let key = "focusBlacklist.v1"

    init(preferences: UserDefaults, fileURL: URL? = nil) {
        self.preferences = preferences
        self.fileURL = fileURL
        policy = .standard
        do {
            let data: Data?
            if let fileURL {
                data = FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : nil
            } else { data = preferences.data(forKey: key) }
            if let data { policy = try JSONDecoder().decode(DistractionPolicy.self, from: data) }
        } catch { self.error = "Could not read your blacklist. Default blocks are in use. \(error.localizedDescription)" }
    }

    func addDomain(_ input: String) throws {
        let websiteRule = try Self.canonicalWebsiteRule(input)
        guard !policy.websiteDomains.contains(websiteRule) else { throw DistractionSettingsError.duplicateDomain }
        try update { $0.websiteDomains.append(websiteRule) }
    }

    func removeDomain(_ domain: String) throws {
        try update { $0.websiteDomains.removeAll { $0 == domain } }
    }

    func addApplication(_ application: BlockedApplication) throws {
        guard !application.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !application.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DistractionSettingsError.invalidApplication }
        guard application.bundleID != Bundle.main.bundleIdentifier,
              !["com.hawkeye2.mac", "com.hawkeye2.mac.development"].contains(application.bundleID) else {
            throw DistractionSettingsError.ownApplication
        }
        guard !policy.applications.contains(where: { $0.bundleID == application.bundleID }) else { throw DistractionSettingsError.duplicateApplication }
        try update { $0.applications.append(application) }
    }

    func addApplication(at url: URL) throws {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier else { throw DistractionSettingsError.invalidApplication }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        try addApplication(.init(bundleID: identifier, name: name))
    }

    func removeApplication(_ application: BlockedApplication) throws {
        try update { $0.applications.removeAll { $0.bundleID == application.bundleID } }
    }

    func setYouTubeCategoriesEnabled(_ enabled: Bool) throws {
        try update { $0.youtubeCategories.isEnabled = enabled }
    }

    func addYouTubeCategory(_ category: YouTubeCategory) throws {
        guard YouTubeCategory.all.contains(category) else { return }
        let additions = YouTubeCategory.all.filter {
            $0.name == category.name && !policy.youtubeCategories.whitelist.contains($0.id)
        }.map(\.id)
        guard !additions.isEmpty else { return }
        try update { $0.youtubeCategories.whitelist.append(contentsOf: additions) }
    }

    func removeYouTubeCategory(_ id: String) throws {
        let ids = YouTubeCategory.all.first { $0.id == id }.map { YouTubeCategory.matchingIDs(for: $0.name) } ?? [id]
        try update { $0.youtubeCategories.whitelist.removeAll { ids.contains($0) } }
    }

    nonisolated static func canonicalWebsiteRule(_ input: String) throws -> String {
        guard let rule = BlockedWebsiteRule(input: input) else { throw DistractionSettingsError.invalidDomain }
        return rule.value
    }

    private func update(_ change: (inout DistractionPolicy) -> Void) throws {
        var updated = policy
        change(&updated)
        try save(updated)
    }

    private func save(_ policy: DistractionPolicy) throws {
        do {
            let data = try JSONEncoder().encode(policy)
            if let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } else { preferences.set(data, forKey: key) }
            self.policy = policy
            error = nil
        } catch {
            self.error = "Could not save your blacklist. \(error.localizedDescription)"
            throw error
        }
    }
}
