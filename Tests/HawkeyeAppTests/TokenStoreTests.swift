import XCTest
@testable import Hawkeye2

final class TokenStoreTests: XCTestCase {
    func testFileTokenSurvivesReplacementAndIsReadableByAnotherInstance() throws {
        let url = try temporaryTokenURL()
        let store = TokenStore.file(url)
        XCTAssertNil(try store.read())
        try store.save("first-test-token")
        XCTAssertEqual(try TokenStore.file(url).read(), "first-test-token")
        try store.save("replacement-test-token")
        XCTAssertEqual(try TokenStore.file(url).read(), "replacement-test-token")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFileReadTrimsNewlinesAndTreatsBlankAsDisconnected() throws {
        let url = try temporaryTokenURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "  manually-pasted-token\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try TokenStore.file(url).read(), "manually-pasted-token")
        try " \n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(try TokenStore.file(url).read())
    }

    func testRemovingFileTokenDoesNotRemoveSiblingFilesAndIsRepeatable() throws {
        let url = try temporaryTokenURL()
        let store = TokenStore.file(url)
        try store.save("test-token")
        let sibling = url.deletingLastPathComponent().appendingPathComponent("tasks.json")
        try Data("task-fixture".utf8).write(to: sibling)
        try store.remove()
        try store.remove()
        XCTAssertNil(try store.read())
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testInvalidFileLocationsFailWithoutReadingAnotherCredentialStore() throws {
        let url = try temporaryTokenURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = TokenStore.file(url)
        XCTAssertThrowsError(try store.read())
        XCTAssertThrowsError(try store.save("test-token"))
    }

    func testBuildSelectsItsCredentialStorage() {
        #if DEBUG
        guard case .file = TokenStore.defaultStore else {
            return XCTFail("Debug launches must not access Keychain.")
        }
        #else
        guard case .keychain = TokenStore.defaultStore else {
            return XCTFail("Release launches must use Keychain.")
        }
        #endif
    }

    func testProviderFilesKeepLegacyTickTickPathAndIsolateRemoval() throws {
        let legacyURL = try temporaryTokenURL()
        let base = TokenStore.file(legacyURL)
        let todoist = base.scoped(to: .todoist)
        let notion = base.scoped(to: .notion)
        XCTAssertEqual(base.scoped(to: .ticktick).fileURL, legacyURL)
        XCTAssertEqual(todoist.fileURL?.lastPathComponent, "todoist-pat.txt")
        XCTAssertEqual(notion.fileURL?.lastPathComponent, "notion-pat.txt")
        try base.save("ticktick-test-token")
        try todoist.save("todoist-test-token")
        try notion.save("notion-test-token")
        try todoist.remove()
        XCTAssertEqual(try base.read(), "ticktick-test-token")
        XCTAssertEqual(try notion.read(), "notion-test-token")
        XCTAssertNil(try todoist.read())
    }

    private func temporaryTokenURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-token-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("credentials/token.txt")
    }
}
