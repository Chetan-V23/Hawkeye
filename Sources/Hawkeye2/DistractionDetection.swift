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

struct DistractionPolicy: Codable, Equatable, Sendable {
    let applications: [BlockedApplication]
    let websiteDomains: [String]
    var browsers: [ScriptableBrowser] { ScriptableBrowser.allCases }

    static let standard = DistractionPolicy(
        applications: [.init(bundleID: "com.apple.Chess", name: "Chess"),
                       .init(bundleID: "org.mozilla.firefox", name: "Firefox")],
        websiteDomains: ["instagram.com"])

    func blockedDomain(for rawURL: String) -> String? {
        guard let url = URLComponents(string: rawURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        return websiteDomains.first { domain in
            let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !domain.isEmpty && (normalized == domain || normalized.hasSuffix("." + domain))
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
    let task: TodoTask
    let policy: DistractionPolicy
    let deadline: Date
    let foregroundApplication: ForegroundApplication
}

enum DistractionFinding: Equatable, Sendable {
    case application(ForegroundApplication)
    case browserTab(ForegroundApplication, ScriptableBrowser, BrowserTab)
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
