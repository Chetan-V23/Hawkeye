import Foundation
import HawkeyeCore

struct BlockedApplication: Codable, Equatable, Identifiable, Sendable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

enum ScriptableBrowser: String, Codable, CaseIterable, Identifiable, Sendable {
    case safari, chrome

    var id: String { bundleID }
    var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        }
    }
    var name: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        }
    }
}

struct BlockedWebsiteRule: Equatable, Sendable {
    let domain: String
    let path: String

    var value: String { domain + path }

    init?(input: String) {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { return nil }
        let source = input.contains("://") ? input : "https://" + input
        guard let components = URLComponents(string: source),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased() else { return nil }

        let domain = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard domain.utf8.count <= 253, labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }) else { return nil }

        self.domain = domain
        self.path = Self.normalizedPath(components.percentEncodedPath)
    }

    func matches(_ components: URLComponents) -> Bool {
        guard let host = components.host?.lowercased(), !host.isEmpty else { return false }
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let domainMatches = normalizedHost == domain || normalizedHost.hasSuffix("." + domain)
        guard domainMatches, !path.isEmpty else { return domainMatches }

        let urlPath = Self.normalizedPath(components.percentEncodedPath)
        return urlPath == path || urlPath.hasPrefix(path + "/")
    }

    private static func normalizedPath(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path == "/" ? "" : path
    }
}

struct DistractionPolicy: Codable, Equatable, Sendable {
    var applications: [BlockedApplication]
    var websiteDomains: [String]
    var youtubeCategories: YouTubeCategoryPolicy
    var browsers: [ScriptableBrowser] { ScriptableBrowser.allCases }
    var inspectsBrowserTabs: Bool { !websiteDomains.isEmpty || youtubeCategories.isEnabled }

    init(applications: [BlockedApplication], websiteDomains: [String],
         youtubeCategories: YouTubeCategoryPolicy = .init()) {
        self.applications = applications
        self.websiteDomains = websiteDomains
        self.youtubeCategories = youtubeCategories
    }

    private enum CodingKeys: String, CodingKey { case applications, websiteDomains, youtubeCategories }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        applications = try values.decode([BlockedApplication].self, forKey: .applications)
        websiteDomains = try values.decode([String].self, forKey: .websiteDomains)
        youtubeCategories = try values.decodeIfPresent(YouTubeCategoryPolicy.self, forKey: .youtubeCategories) ?? .init()
    }

    static let standard = DistractionPolicy(
        applications: [.init(bundleID: "com.apple.Chess", name: "Chess"),
                       .init(bundleID: "org.mozilla.firefox", name: "Firefox")],
        websiteDomains: ["instagram.com"])

    func blockedDomain(for rawURL: String) -> String? {
        guard let url = URLComponents(string: rawURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return websiteDomains.first { value in
            guard let rule = BlockedWebsiteRule(input: value) else { return false }
            return rule.matches(url)
        }
    }
}

struct ForegroundApplication: Equatable, Sendable {
    let bundleID: String
    let processID: Int32
}

struct BrowserTab: Codable, Equatable, Sendable {
    let windowID: String
    let index: Int
    let tabID: String?
    let url: String
}

enum MonitoringMethod: Equatable, Sendable {
    case deterministic, ocr, vlm

    var name: String {
        switch self {
        case .deterministic: return "Deterministic"
        case .ocr: return "OCR"
        case .vlm: return "VLM"
        }
    }
}

struct DetectionContext: Sendable {
    let session: MonitoringSession
    let policy: DistractionPolicy
    let deadline: Date
    let foregroundApplication: ForegroundApplication
}

enum DistractionFinding: Equatable, Sendable {
    case application(ForegroundApplication)
    case browserTab(ForegroundApplication, ScriptableBrowser, BrowserTab)
    case youtubeCategoryTab(ForegroundApplication, ScriptableBrowser, BrowserTab, categoryIDs: Set<String>)
    case possibleDistraction(ForegroundApplication)
}

enum DetectionCapability: Equatable, Sendable {
    case browserAutomation(ScriptableBrowser)
    case screenRecording
    case accessibility
}

enum DetectionFailure: Error, Equatable, Sendable {
    case timedOut, failed, responseTooLarge, unavailable

    init(_ error: Error) {
        if let failure = error as? DetectionFailure { self = failure; return }
        switch error as? CommandFailure {
        case .timedOut: self = .timedOut
        case .failed: self = .failed
        case .outputTooLarge: self = .responseTooLarge
        case nil: self = .unavailable
        }
    }
}

enum DetectionReport: Equatable, Sendable {
    case findings([DistractionFinding])
    case unavailable(DetectionCapability)
    case failure(DetectionFailure)
}

protocol DistractionDetecting: Sendable {
    var method: MonitoringMethod { get }
    var pollingInterval: Duration { get }
    func inspect(_ context: DetectionContext) async throws -> DetectionReport
}

@MainActor
protocol DeterministicObservation: AnyObject, Sendable {
    func canAutomate(_ browser: ScriptableBrowser) -> Bool
    func tabs(in browser: ScriptableBrowser, application: ForegroundApplication, before deadline: Date) async throws -> [BrowserTab]
}

@MainActor
protocol DistractionActions: AnyObject {
    func frontmostApplication() -> ForegroundApplication?
    func canAutomate(_ browser: ScriptableBrowser) -> Bool
    func terminate(_ application: ForegroundApplication) -> Bool
    func close(_ tab: BrowserTab, in browser: ScriptableBrowser, application: ForegroundApplication, before deadline: Date) async throws -> Bool
}
