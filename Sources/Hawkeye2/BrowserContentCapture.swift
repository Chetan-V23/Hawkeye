import Foundation

struct BrowserMainContent: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case mainLandmark, article }
    let text: String
    let source: Source
}

struct BrowserContentSnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let browserBundleID: String
    let processID: Int32
    let pageTitle: String?
    let pageURL: URL?
    let fullText: String
    let mainContent: BrowserMainContent?
    let isTruncated: Bool
}

protocol BrowserContentCapturing: Sendable {
    func capture(before deadline: Date) async throws -> BrowserContentSnapshot?
}

enum BrowserContentFailure: Error, Equatable, Sendable {
    case disabled, permissionDenied, noPage, pageChanged, timedOut, busy, captureFailed, persistenceFailed
    var message: String {
        switch self {
        case .disabled: return "Browser text capture is disabled."
        case .permissionDenied: return "Accessibility access is required to read browser text."
        case .noPage: return "The foreground browser has no selected page to capture."
        case .pageChanged: return "The page in the foreground browser changed during capture."
        case .timedOut: return "Browser text capture timed out."
        case .busy: return "The previous browser text capture is still running."
        case .captureFailed: return "Hawkeye could not read browser text."
        case .persistenceFailed: return "Hawkeye could not save browser text."
        }
    }
}

struct BrowserTextNode: Equatable, Sendable {
    let role: String
    var subrole: String? = nil
    var text: String = ""
    var children: [BrowserTextNode] = []

    var hasDirectTextValue: Bool {
        switch role {
        case "AXStaticText", "AXTextField", "AXTextArea", "AXComboBox": return true
        default: return false
        }
    }
}

enum BrowserContentExtraction {
    static func extract(_ root: BrowserTextNode, isTruncated: Bool = false)
        -> (fullText: String, mainContent: BrowserMainContent?) {
        let fullText = text(in: root)
        guard !isTruncated else { return (fullText, nil) }
        var mains: [BrowserTextNode] = []
        var articles: [BrowserTextNode] = []
        func visit(_ node: BrowserTextNode) {
            guard !isSecure(node) else { return }
            if node.subrole == "AXLandmarkMain" || node.role == "AXLandmarkMain" {
                mains.append(node)
            }
            if node.subrole == "AXDocumentArticle" || node.role == "AXDocumentArticle" {
                articles.append(node)
            }
            node.children.forEach(visit)
        }
        visit(root)
        let candidates = mains.isEmpty ? articles : mains
        guard candidates.count == 1 else { return (fullText, nil) }
        let mainText = text(in: candidates[0])
        guard !mainText.isEmpty else { return (fullText, nil) }
        return (fullText, BrowserMainContent(text: mainText,
            source: mains.isEmpty ? .article : .mainLandmark))
    }

    private static func text(in node: BrowserTextNode) -> String {
        guard !isSecure(node) else { return "" }
        if node.hasDirectTextValue, !node.text.isEmpty {
            return node.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let childText = node.children.map { text(in: $0) }.filter { !$0.isEmpty }
        if !node.children.isEmpty { return childText.joined(separator: "\n") }
        return node.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func isSecure(_ node: BrowserTextNode) -> Bool {
        node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField"
            || node.subrole == "AXProtectedTextField"
    }
}
