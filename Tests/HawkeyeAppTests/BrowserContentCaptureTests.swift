import XCTest
@testable import Hawkeye2

final class BrowserContentCaptureTests: XCTestCase {
    private func text(_ value: String) -> BrowserTextNode { .init(role: "AXStaticText", text: value) }
    private func main(_ children: [BrowserTextNode]) -> BrowserTextNode {
        .init(role: "AXGroup", subrole: "AXLandmarkMain", children: children)
    }
    private func article(_ children: [BrowserTextNode]) -> BrowserTextNode {
        .init(role: "AXGroup", subrole: "AXDocumentArticle", children: children)
    }

    func testMainIncludesItsEntireExposedRegionAndNestedArticle() {
        let root = BrowserTextNode(role: "AXWebArea", children: [text("Header"), main([
            .init(role: "AXGroup", subrole: "AXLandmarkNavigation", children: [text("Navigation")]),
            article([text("Article body")]), text("Footer inside main")
        ]), text("Page footer")])
        let result = BrowserContentExtraction.extract(root)
        XCTAssertEqual(result.fullText, "Header\nNavigation\nArticle body\nFooter inside main\nPage footer")
        XCTAssertEqual(result.mainContent, .init(text: "Navigation\nArticle body\nFooter inside main", source: .mainLandmark))
    }

    func testSingleArticleAndMissingSemanticRegions() {
        XCTAssertEqual(BrowserContentExtraction.extract(article([text("Body")])).mainContent,
                       .init(text: "Body", source: .article))
        let result = BrowserContentExtraction.extract(.init(role: "AXWebArea", children: [text("Body")]))
        XCTAssertEqual(result.fullText, "Body")
        XCTAssertNil(result.mainContent)
        XCTAssertNil(BrowserContentExtraction.extract(main([])).mainContent)
    }

    func testAmbiguousMainDoesNotFallThroughToSingleArticle() {
        let root = BrowserTextNode(role: "AXWebArea", children: [main([text("One")]), main([text("Two")]), article([text("Body")])])
        XCTAssertNil(BrowserContentExtraction.extract(root).mainContent)
        let articles = BrowserTextNode(role: "AXWebArea", children: [article([text("One")]), article([text("Two")])])
        XCTAssertNil(BrowserContentExtraction.extract(articles).mainContent)
    }

    func testAggregateParentValuesAreDiscardedButMeaningfulRepetitionRemains() {
        let root = BrowserTextNode(role: "AXWebArea", text: "Repeat Repeat", children: [
            .init(role: "AXGroup", text: "Repeat", children: [text("  Repeat \n")]), text("Repeat")
        ])
        XCTAssertEqual(BrowserContentExtraction.extract(root).fullText, "Repeat\nRepeat")
    }

    func testSecureSubtreeAndItsParentAggregateCannotLeak() {
        let secure = BrowserTextNode(role: "AXTextField", subrole: "AXSecureTextField", text: "secret",
                                     children: [text("nested secret")])
        let root = BrowserTextNode(role: "AXWebArea", text: "secret", children: [
            secure, .init(role: "AXTextField", text: "ordinary form value"), text("Public")
        ])
        XCTAssertEqual(BrowserContentExtraction.extract(root).fullText, "ordinary form value\nPublic")
        XCTAssertEqual(BrowserContentExtraction.extract(.init(role: "AXGroup", text: "secret", children: [secure])).fullText, "")
    }

    func testTextControlsRetainTheirCompleteValueWhenChildrenExposeOnlyPart() {
        let root = BrowserTextNode(role: "AXWebArea", children: [
            .init(role: "AXTextField", text: "Complete field value", children: [.init(role: "AXButton")]),
            .init(role: "AXTextArea", text: "Complete editor text", children: [text("Complete")]),
            .init(role: "AXStaticText", text: "Complete paragraph", children: [text("paragraph")])
        ])
        XCTAssertEqual(BrowserContentExtraction.extract(root).fullText,
                       "Complete field value\nComplete editor text\nComplete paragraph")
    }

    func testTruncatedTreeRetainsTextWithoutClaimingMainContent() {
        let result = BrowserContentExtraction.extract(main([text("Partial body 👋")]), isTruncated: true)
        XCTAssertEqual(result.fullText, "Partial body 👋")
        XCTAssertNil(result.mainContent)
    }

    func testNativeTextByteLimitPreservesValidUnicodeAndBounds() {
        XCTAssertEqual(browserTextPrefix("😀tail", maximumUTF8Bytes: 3), "")
        XCTAssertEqual(browserTextPrefix("x😀tail", maximumUTF8Bytes: 4), "x")
        XCTAssertEqual(browserTextPrefix("x😀tail", maximumUTF8Bytes: 5), "x😀")
        XCTAssertEqual(browserTextPrefix("éabc", maximumUTF8Bytes: 1), "")
        XCTAssertEqual(browserTextPrefix("text", maximumUTF8Bytes: 0), "")
    }

    func testDisabledNativeCaptureFailsBeforeInspectingSystem() async {
        do {
            _ = try await MacBrowserContentCapture(effectsEnabled: false).capture(before: .distantPast)
            XCTFail("Disabled capture must stop at its effects boundary.")
        } catch { XCTAssertEqual(error as? BrowserContentFailure, .disabled) }
    }

    func testFailureMessagesArePresentAndDoNotContainCapturedData() {
        let failures: [BrowserContentFailure] = [.disabled, .permissionDenied, .noPage, .pageChanged, .timedOut, .busy, .captureFailed, .persistenceFailed]
        XCTAssertTrue(failures.allSatisfy { !$0.message.isEmpty && !$0.message.contains("http") })
    }
}

final class BrowserAccessibilityWorkerTests: XCTestCase {
    func testDeadlineReturnsWhileSynchronousCallStaysBusyThenRecovers() async throws {
        let worker = BrowserAccessibilityWorker()
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "Synchronous call entered")
        let exited = expectation(description: "Synchronous call exited")
        let operation = Task {
            try await worker.run(before: Date().addingTimeInterval(0.08)) { _ in
                started.fulfill()
                gate.wait()
                exited.fulfill()
                return 7
            }
        }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await operation.value; XCTFail("Deadline must finish the waiter.") }
        catch { XCTAssertEqual(error as? BrowserContentFailure, .timedOut) }
        for _ in 0..<5 {
            do {
                _ = try await worker.run(before: Date().addingTimeInterval(1)) { _ in
                    XCTFail("Busy operations must never be queued.")
                    return 1
                }
                XCTFail("The blocked worker must remain occupied.")
            } catch { XCTAssertEqual(error as? BrowserContentFailure, .busy) }
        }
        gate.signal()
        await fulfillment(of: [exited], timeout: 2)
        try await Task.sleep(for: .milliseconds(20))
        let recovered = try await worker.run(before: Date().addingTimeInterval(1)) { _ in 9 }
        XCTAssertEqual(recovered, 9)
    }

    func testCancellationReturnsBeforeNativeCallExitsAndDiscardsLateSuccess() async throws {
        let worker = BrowserAccessibilityWorker()
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "Synchronous call entered")
        let exited = expectation(description: "Synchronous call exited")
        let operation = Task {
            try await worker.run(before: Date().addingTimeInterval(5)) { cancellation in
                started.fulfill()
                gate.wait()
                defer { exited.fulfill() }
                try cancellation.check()
                return 7
            }
        }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancellation must finish the waiter.") }
        catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await worker.run(before: Date().addingTimeInterval(1)) { _ in 1 }
            XCTFail("Cancellation must retain the busy gate.")
        } catch { XCTAssertEqual(error as? BrowserContentFailure, .busy) }
        gate.signal()
        await fulfillment(of: [exited], timeout: 2)
        try await Task.sleep(for: .milliseconds(20))
        let recovered = try await worker.run(before: Date().addingTimeInterval(1)) { _ in 11 }
        XCTAssertEqual(recovered, 11)
    }

    func testExpiredDeadlineDoesNotRunOperationAndDoesNotOccupyWorker() async throws {
        let worker = BrowserAccessibilityWorker()
        do {
            _ = try await worker.run(before: Date().addingTimeInterval(-1)) { _ in
                XCTFail("Expired work must never execute.")
                return 1
            }
            XCTFail("An expired deadline must fail.")
        } catch { XCTAssertEqual(error as? BrowserContentFailure, .timedOut) }
        let value = try await worker.run(before: Date().addingTimeInterval(1)) { _ in 2 }
        XCTAssertEqual(value, 2)
    }

    func testCancellationRacingCompletionResumesExactlyOnce() async throws {
        for _ in 0..<100 {
            let worker = BrowserAccessibilityWorker()
            let operation = Task { try await worker.run(before: Date().addingTimeInterval(1)) { _ in 3 } }
            operation.cancel()
            do { let result = try await operation.value; XCTAssertEqual(result, 3) }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }
}
