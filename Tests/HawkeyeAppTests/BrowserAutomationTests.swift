import XCTest
@testable import Hawkeye2

final class BrowserAutomationTests: XCTestCase {
    func testSafariReadAndClosePreserveOtherTabsAndRevalidateExactURL() async throws {
        let script = fixture + BrowserAutomation.operation + #"""
        function run() {
            const observations = browserOperation(app, 'safari', function() { return true; }, null);
            const expected = observations[1];
            list[1].currentURL = 'https://safe.example/changed';
            const stale = browserOperation(app, 'safari', function() { return true; }, expected);
            list[1].currentURL = expected.url;
            const closedTab = browserOperation(app, 'safari', function() { return true; }, expected);
            return JSON.stringify({ observations: observations, stale: stale, closedTab: closedTab, closed: closed });
        }
        """#
        let result = try await execute(script)
        let observations = try XCTUnwrap(result["observations"] as? [[String: Any]])
        XCTAssertEqual(observations.count, 3)
        XCTAssertEqual(observations[0]["windowID"] as? String, "1")
        XCTAssertEqual(result["stale"] as? Bool, false)
        XCTAssertEqual(result["closedTab"] as? Bool, true)
        XCTAssertEqual(result["closed"] as? [String], ["20"])
    }

    func testChromeClosesByStableIDAfterReorderingAndRejectsUnknownIDs() async throws {
        let script = fixture + BrowserAutomation.operation + #"""
        function run() {
            const observations = browserOperation(app, 'chrome', function() { return true; }, null);
            const expected = observations[1];
            list.reverse();
            const closedTab = browserOperation(app, 'chrome', function() { return true; }, expected);
            expected.tabID = 'missing';
            const missing = browserOperation(app, 'chrome', function() { return true; }, expected);
            return JSON.stringify({ tabID: observations[0].tabID, closedTab: closedTab, missing: missing, closed: closed });
        }
        """#
        let result = try await execute(script)
        XCTAssertEqual(result["tabID"] as? String, "10")
        XCTAssertEqual(result["closedTab"] as? Bool, true)
        XCTAssertEqual(result["missing"] as? Bool, false)
        XCTAssertEqual(result["closed"] as? [String], ["20"])
    }

    func testCloseRechecksPermissionToActImmediatelyBeforeCommand() async throws {
        let script = fixture + BrowserAutomation.operation + #"""
        function run() {
            const expected = { windowID: '1', index: 1, tabID: '20', url: 'https://instagram.com/p' };
            let checks = 0;
            const closedTab = browserOperation(app, 'chrome', function() { return ++checks === 1; }, expected);
            return JSON.stringify({ closedTab: closedTab, closed: closed, checks: checks });
        }
        """#
        let result = try await execute(script)
        XCTAssertEqual(result["closedTab"] as? Bool, false)
        XCTAssertEqual(result["closed"] as? [String], [])
        XCTAssertEqual(result["checks"] as? Int, 2)
    }

    func testProductionJXAScriptCompilesWithoutExecutingOrAccessingApplications() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-script-\(UUID()).scpt")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await BoundedCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/osacompile"),
                                                arguments: ["-l", "JavaScript", "-o", url.path, "-e", BrowserAutomation.script])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func execute(_ script: String) async throws -> [String: Any] {
        let data = try await BoundedCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                                                       arguments: ["-l", "JavaScript", "-e", script])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let fixture = #"""
    const closed = [];
    function makeTab(id, url) {
        return { id: function() { return id; }, currentURL: url,
                 url: function() { return this.currentURL; }, close: function() { closed.push(String(id)); } };
    }
    const list = [makeTab('10', 'https://safe.example/'), makeTab('20', 'https://instagram.com/p'), makeTab('30', 'https://other.example/')];
    const tabs = function() { return list; };
    tabs.byId = function(id) { return list.filter(function(t) { return t.id() === id; })[0]; };
    for (let i = 0; i < list.length; i++) Object.defineProperty(tabs, String(i), { get: function() { return list[i]; } });
    const window = { id: function() { return 1; }, tabs: tabs };
    const windows = function() { return [window]; };
    windows.byId = function(id) { return id === window.id() ? window : null; };
    const app = { windows: windows };

    """#
}
