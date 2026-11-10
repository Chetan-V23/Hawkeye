import AppKit
import ApplicationServices
import Foundation

final class MacBrowserContentCapture: BrowserContentCapturing, @unchecked Sendable {
    private let effectsEnabled: Bool
    private let worker = BrowserAccessibilityWorker()

    init(effectsEnabled: Bool) {
        self.effectsEnabled = effectsEnabled && Bundle.main.bundleURL.pathExtension == "app"
    }

    func capture(before deadline: Date) async throws -> BrowserContentSnapshot? {
        guard effectsEnabled else { throw BrowserContentFailure.disabled }
        try Task.checkCancellation()
        let boundedDeadline = min(deadline, Date().addingTimeInterval(3))
        guard boundedDeadline > Date() else { throw BrowserContentFailure.timedOut }
        guard let application = await Self.foregroundApplication(),
              let family = BrowserFamily(bundleID: application.bundleID) else { return nil }
        let snapshot = try await worker.run(before: boundedDeadline) { cancellation in
            guard AXIsProcessTrusted() else { throw BrowserContentFailure.permissionDenied }
            return try BrowserAXReader(deadline: boundedDeadline, cancellation: cancellation)
                .capture(application: application, family: family)
        }
        try Task.checkCancellation()
        guard Date() < boundedDeadline else { throw BrowserContentFailure.timedOut }
        let currentApplication = await Self.foregroundApplication()
        try Task.checkCancellation()
        guard Date() < boundedDeadline else { throw BrowserContentFailure.timedOut }
        guard currentApplication == application else { throw BrowserContentFailure.pageChanged }
        return snapshot
    }

    @MainActor private static func foregroundApplication() -> BrowserApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else { return nil }
        return BrowserApplication(bundleID: bundleID, processID: app.processIdentifier)
    }
}

private struct BrowserApplication: Equatable, Sendable {
    let bundleID: String
    let processID: Int32
}

private enum BrowserFamily: Sendable {
    case safari, chromium

    init?(bundleID: String) {
        switch bundleID {
        case "com.apple.Safari": self = .safari
        case "com.google.Chrome": self = .chromium
        default: return nil
        }
    }
}

final class BrowserAccessibilityWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Hawkeye.browser-accessibility", qos: .utility)
    private let lock = NSLock()
    private var occupied = false

    func run<Value: Sendable>(before deadline: Date,
        operation: @escaping @Sendable (BrowserAccessibilityCancellation) throws -> Value) async throws -> Value {
        let request = BrowserAccessibilityRequest<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard deadline > Date() else { request.finish(.failure(BrowserContentFailure.timedOut)); return }
                guard acquire() else { request.finish(.failure(BrowserContentFailure.busy)); return }
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow))
                timer.setEventHandler { request.finish(.failure(BrowserContentFailure.timedOut)) }
                request.setTimer(timer)
                timer.resume()
                queue.async {
                    defer { self.release() }
                    do {
                        try request.check()
                        request.finish(.success(try operation(request)))
                    } catch { request.finish(.failure(error)) }
                }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
    }

    private func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !occupied else { return false }
        occupied = true
        return true
    }

    private func release() {
        lock.lock(); defer { lock.unlock() }
        occupied = false
    }
}

protocol BrowserAccessibilityCancellation: Sendable {
    func check() throws
}

private final class BrowserAccessibilityRequest<Value: Sendable>: BrowserAccessibilityCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var timer: DispatchSourceTimer?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }

    func setTimer(_ timer: DispatchSourceTimer) {
        lock.lock()
        if result == nil { self.timer = timer; lock.unlock() }
        else { lock.unlock(); timer.cancel() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
    }

    func check() throws {
        lock.lock(); let result = result; lock.unlock()
        if case .failure(let error) = result { throw error }
    }
}

private final class BrowserAXReader {
    private let deadline: Date
    private let cancellation: BrowserAccessibilityCancellation
    private var visited = 0
    private var textBytes = 0
    private var truncated = false
    private let maximumNodes = 12_000
    private let maximumDepth = 80
    private let maximumTextBytes = 1_000_000
    private let childBatchSize = 64

    init(deadline: Date, cancellation: BrowserAccessibilityCancellation) {
        self.deadline = deadline
        self.cancellation = cancellation
    }

    func capture(application: BrowserApplication, family: BrowserFamily) throws -> BrowserContentSnapshot {
        try check()
        let app = AXUIElementCreateApplication(application.processID)
        if family == .chromium {
            try prepare(app)
            // Chromium may not expose its document tree until native accessibility is enabled.
            if try bool(app, "AXEnhancedUserInterface") != true {
                try prepare(app)
                let result = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                guard result == .success || result == .attributeUnsupported || result == .notImplemented else {
                    throw BrowserContentFailure.captureFailed
                }
            }
        }
        guard let window = try element(app, kAXFocusedWindowAttribute),
              try bool(window, kAXMinimizedAttribute) != true else { throw BrowserContentFailure.noPage }
        let page = try selectedWebArea(in: window)
        let metadata = try metadata(page: page, window: window, family: family)
        let tree = try read(page, depth: 0)
        guard let currentWindow = try element(app, kAXFocusedWindowAttribute), CFEqual(window, currentWindow) else {
            throw BrowserContentFailure.pageChanged
        }
        do {
            let currentPage = try selectedWebArea(in: currentWindow)
            guard CFEqual(page, currentPage), try self.metadata(page: currentPage, window: currentWindow, family: family) == metadata else {
                throw BrowserContentFailure.pageChanged
            }
        } catch is CancellationError { throw CancellationError() }
        catch BrowserContentFailure.timedOut { throw BrowserContentFailure.timedOut }
        catch { throw BrowserContentFailure.pageChanged }
        try check()
        let extracted = BrowserContentExtraction.extract(tree, isTruncated: truncated)
        guard !extracted.fullText.isEmpty else { throw BrowserContentFailure.noPage }
        return BrowserContentSnapshot(capturedAt: Date(), browserBundleID: application.bundleID,
            processID: application.processID, pageTitle: metadata.title, pageURL: metadata.url,
            fullText: extracted.fullText, mainContent: extracted.mainContent, isTruncated: truncated)
    }

    private struct Metadata: Equatable {
        let title: String?
        let url: URL?
    }

    private func metadata(page: AXUIElement, window: AXUIElement, family: BrowserFamily) throws -> Metadata {
        let pageTitle = try string(page, kAXTitleAttribute)
        let title = try pageTitle ?? string(window, kAXTitleAttribute)
        let pageURL = try url(page, "AXURL")
        let location = try pageURL ?? (family == .safari ? url(window, kAXDocumentAttribute) : nil)
        return Metadata(title: title, url: location)
    }

    private func selectedWebArea(in window: AXUIElement) throws -> AXUIElement {
        var roots: [AXUIElement] = []
        var count = 0
        func visit(_ element: AXUIElement, depth: Int) throws {
            try check()
            count += 1
            guard count <= 1_500, depth <= 40 else { throw BrowserContentFailure.noPage }
            if try bool(element, "AXHidden") == true || bool(element, "AXVisible") == false { return }
            guard let role = try string(element, kAXRoleAttribute) else { throw BrowserContentFailure.captureFailed }
            if role == "AXWebArea" {
                roots.append(element)
                guard roots.count <= 1 else { throw BrowserContentFailure.noPage }
                return
            }
            try forEachChild(element, maximum: 1_500 - count, requireAll: true) { child in try visit(child, depth: depth + 1) }
        }
        try visit(window, depth: 0)
        guard roots.count == 1 else { throw BrowserContentFailure.noPage }
        return roots[0]
    }

    private func read(_ element: AXUIElement, depth: Int) throws -> BrowserTextNode {
        try check()
        guard visited < maximumNodes, depth <= maximumDepth else {
            truncated = true
            return BrowserTextNode(role: "AXGroup")
        }
        visited += 1
        guard let role = try string(element, kAXRoleAttribute) else { throw BrowserContentFailure.captureFailed }
        let subrole = try string(element, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" || subrole == "AXProtectedTextField" {
            return BrowserTextNode(role: "AXSecureTextField")
        }
        if try bool(element, "AXProtectedContent") == true {
            return BrowserTextNode(role: "AXSecureTextField")
        }
        if try bool(element, "AXHidden") == true { return BrowserTextNode(role: role, subrole: subrole) }
        let node = BrowserTextNode(role: role, subrole: subrole)
        if node.hasDirectTextValue, let value = try string(element, kAXValueAttribute) {
            return boundedTextNode(node, text: value)
        }
        var children: [BrowserTextNode] = []
        let childCount = try forEachChild(element,
            maximum: depth < maximumDepth ? maximumNodes - visited : 0,
            shouldContinue: { self.visited < self.maximumNodes && self.textBytes < self.maximumTextBytes }) { child in
                children.append(try read(child, depth: depth + 1))
            }
        if childCount == 0 {
            let value = try string(element, kAXValueAttribute)
            let text = try value ?? string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
            return boundedTextNode(node, text: text)
        }
        return BrowserTextNode(role: role, subrole: subrole, children: children)
    }

    private func boundedTextNode(_ node: BrowserTextNode, text: String) -> BrowserTextNode {
        var result = node
        let separatorBytes = textBytes == 0 ? 0 : 1
        let remaining = max(0, maximumTextBytes - textBytes - separatorBytes)
        result.text = browserTextPrefix(text, maximumUTF8Bytes: remaining)
        if result.text.utf8.count < text.utf8.count { truncated = true }
        if !result.text.isEmpty { textBytes += result.text.utf8.count + separatorBytes }
        return result
    }

    private func check() throws {
        try cancellation.check()
        guard deadline > Date() else { throw BrowserContentFailure.timedOut }
    }

    private func prepare(_ element: AXUIElement) throws {
        try check()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw BrowserContentFailure.timedOut }
        guard AXUIElementSetMessagingTimeout(element, Float(min(0.15, remaining))) == .success else {
            throw BrowserContentFailure.captureFailed
        }
    }

    private func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        try prepare(element)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch result {
        case .success: return value
        case .attributeUnsupported, .noValue: return nil
        default: try check(); throw BrowserContentFailure.captureFailed
        }
    }

    private func string(_ element: AXUIElement, _ attribute: String) throws -> String? {
        guard let value = try value(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) throws -> Bool? {
        guard let value = try value(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func url(_ element: AXUIElement, _ attribute: String) throws -> URL? {
        guard let value = try value(element, attribute) else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() { return value as? URL }
        guard let text = value as? String else { return nil }
        return URL(string: text)
    }

    private func element(_ parent: AXUIElement, _ attribute: String) throws -> AXUIElement? {
        guard let value = try value(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    @discardableResult
    private func forEachChild(_ element: AXUIElement, maximum: Int, requireAll: Bool = false,
                              shouldContinue: () -> Bool = { true },
                              body: (AXUIElement) throws -> Void) throws -> Int {
        try prepare(element)
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        if result == .attributeUnsupported || result == .noValue { return 0 }
        guard result == .success, count >= 0 else { try check(); throw BrowserContentFailure.captureFailed }
        if count > maximum {
            if requireAll { throw BrowserContentFailure.noPage }
            truncated = true
        }
        let limit = min(count, max(0, maximum))
        var offset = 0
        while offset < limit {
            guard shouldContinue() else { truncated = true; return count }
            try prepare(element)
            let length = min(childBatchSize, limit - offset)
            var values: CFArray?
            let result = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, offset, length, &values)
            guard result == .success, let values, CFArrayGetCount(values) == length else {
                try check(); throw BrowserContentFailure.captureFailed
            }
            for index in 0..<length {
                guard shouldContinue() else { truncated = true; return count }
                guard let pointer = CFArrayGetValueAtIndex(values, index) else { throw BrowserContentFailure.captureFailed }
                let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw BrowserContentFailure.captureFailed }
                try body(unsafeBitCast(value, to: AXUIElement.self))
            }
            offset += length
        }
        return count
    }
}

func browserTextPrefix(_ text: String, maximumUTF8Bytes: Int) -> String {
    var bytes = Array(text.utf8.prefix(max(0, maximumUTF8Bytes)))
    while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    return String(decoding: bytes, as: UTF8.self)
}
