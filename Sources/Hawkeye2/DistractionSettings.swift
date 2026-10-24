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
        let domain = try Self.canonicalDomain(input)
        guard !policy.websiteDomains.contains(domain) else { throw DistractionSettingsError.duplicateDomain }
        try save(.init(applications: policy.applications, websiteDomains: policy.websiteDomains + [domain]))
    }

    func removeDomain(_ domain: String) throws {
        try save(.init(applications: policy.applications, websiteDomains: policy.websiteDomains.filter { $0 != domain }))
    }

    func addApplication(_ application: BlockedApplication) throws {
        guard !application.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !application.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DistractionSettingsError.invalidApplication }
        guard application.bundleID != Bundle.main.bundleIdentifier,
              !["com.hawkeye2.mac", "com.hawkeye2.mac.development"].contains(application.bundleID) else {
            throw DistractionSettingsError.ownApplication
        }
        guard !policy.applications.contains(where: { $0.bundleID == application.bundleID }) else { throw DistractionSettingsError.duplicateApplication }
        try save(.init(applications: policy.applications + [application], websiteDomains: policy.websiteDomains))
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
        try save(.init(applications: policy.applications.filter { $0.bundleID != application.bundleID }, websiteDomains: policy.websiteDomains))
    }

    nonisolated static func canonicalDomain(_ input: String) throws -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { throw DistractionSettingsError.invalidDomain }
        let source = input.contains("://") ? input : "https://" + input
        guard let components = URLComponents(string: source),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased() else { throw DistractionSettingsError.invalidDomain }
        let domain = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard domain.utf8.count <= 253, labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }) else { throw DistractionSettingsError.invalidDomain }
        return domain
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
