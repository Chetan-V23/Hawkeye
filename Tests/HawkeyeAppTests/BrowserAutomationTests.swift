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

    func testYouTubeSourceReadsExactSafariTabAndRejectsNavigationDuringRead() async throws {
        let script = fixture + YouTubePageSourceAutomation.operation + #"""
        function run() {
            const expected = { windowID: '1', index: 1, tabID: null, url: list[1].url() };
            list[1].source = function() { return '<html>metadata</html>'; };
            const good = youtubePageSource(app, 'safari', function() { return true; }, expected);
            list[1].source = function() { this.currentURL = 'https://example.com/'; return '<html>old</html>'; };
            const changed = youtubePageSource(app, 'safari', function() { return true; }, expected);
            return JSON.stringify({ good: good, changed: changed, closed: closed });
        }
        """#
        let result = try await execute(script)
        XCTAssertEqual((result["good"] as? [String: Any])?["html"] as? String, "<html>metadata</html>")
        XCTAssertEqual((result["changed"] as? [String: Any])?["stale"] as? Bool, true)
        XCTAssertEqual(result["closed"] as? [String], [])
    }

    func testYouTubeChromeSourceUsesStableIDAndUnavailableSourceCanFallBack() async throws {
        let script = fixture + YouTubePageSourceAutomation.operation + #"""
        function run() {
            const expected = { windowID: '1', index: 1, tabID: '20', url: list[1].url() };
            const target = list[1];
            target.execute = function(args) { return args.javascript === 'document.documentElement.outerHTML' ? 'chrome HTML' : ''; };
            list.reverse();
            const good = youtubePageSource(app, 'chrome', function() { return true; }, expected);
            target.execute = function() { throw Error('JavaScript from Apple Events is disabled'); };
            const unavailable = youtubePageSource(app, 'chrome', function() { return true; }, expected);
            const revoked = youtubePageSource(app, 'chrome', function() { return false; }, expected);
            return JSON.stringify({ good: good, unavailable: unavailable, revoked: revoked });
        }
        """#
        let result = try await execute(script)
        XCTAssertEqual((result["good"] as? [String: Any])?["html"] as? String, "chrome HTML")
        XCTAssertEqual((result["unavailable"] as? [String: Any])?["stale"] as? Bool, false)
        XCTAssertTrue((result["unavailable"] as? [String: Any])?["html"] is NSNull)
        XCTAssertEqual((result["revoked"] as? [String: Any])?["stale"] as? Bool, true)
    }

    func testYouTubeSourceProductionScriptCompilesWithoutApplicationAccess() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-youtube-source-\(UUID()).scpt")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await BoundedCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/osacompile"),
            arguments: ["-l", "JavaScript", "-o", url.path, "-e", YouTubePageSourceAutomation.script])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testVisibleSafariResolvesOnlySelectedTabAndRevalidatesURLAndSelection() async throws {
        let script = visibleFixture + VisibleBrowserAutomation.operation + #"""
        function run() {
            const allow = function() { return true; }, bounds = [100, 20, 800, 600];
            const expected = visibleBrowserOperation(app, 'safari', allow, bounds, null);
            list[1].currentURL = 'https://changed.example/';
            const changedURL = visibleBrowserOperation(app, 'safari', allow, bounds, expected);
            list[1].currentURL = expected.url;
            selectedIndex = 0;
            const changedSelection = visibleBrowserOperation(app, 'safari', allow, bounds, expected);
            selectedIndex = 1;
            const closedTab = visibleBrowserOperation(app, 'safari', allow, bounds, expected);
            return JSON.stringify({ expected: expected, changedURL: changedURL, changedSelection: changedSelection, closedTab: closedTab, closed: closed });
        }
        """#
        let result = try await execute(script)
        let expected = try XCTUnwrap(result["expected"] as? [String: Any])
        XCTAssertEqual(expected["windowID"] as? String, "77")
        XCTAssertEqual(expected["index"] as? Int, 1)
        XCTAssertEqual(result["changedURL"] as? Bool, false)
        XCTAssertEqual(result["changedSelection"] as? Bool, false)
        XCTAssertEqual(result["closedTab"] as? Bool, true)
        XCTAssertEqual(result["closed"] as? [String], ["20"])
    }

    func testVisibleChromeRejectsAmbiguousMovedOrUnsupportedBoundsAndRechecksAuthorization() async throws {
        let script = visibleFixture + VisibleBrowserAutomation.operation + #"""
        function run() {
            const allow = function() { return true; }, bounds = [100, 20, 800, 600];
            const expected = visibleBrowserOperation(app, 'chrome', allow, bounds, null);
            windowList.push(window);
            const duplicate = visibleBrowserOperation(app, 'chrome', allow, bounds, expected);
            windowList.pop();
            frame.x += 10;
            const moved = visibleBrowserOperation(app, 'chrome', allow, bounds, expected);
            frame.x -= 10;
            const saved = frame;
            frame = [100, 20, 900, 620];
            const unsupported = visibleBrowserOperation(app, 'chrome', allow, bounds, expected);
            frame = saved;
            let checks = 0;
            const revoked = visibleBrowserOperation(app, 'chrome', function() { return ++checks < 3; }, bounds, expected);
            const closedTab = visibleBrowserOperation(app, 'chrome', allow, bounds, expected);
            return JSON.stringify({ expected: expected, duplicate: duplicate, moved: moved, unsupported: unsupported, revoked: revoked, closedTab: closedTab, closed: closed });
        }
        """#
        let result = try await execute(script)
        let expected = try XCTUnwrap(result["expected"] as? [String: Any])
        XCTAssertEqual(expected["tabID"] as? String, "20")
        for key in ["duplicate", "moved", "unsupported", "revoked"] { XCTAssertEqual(result[key] as? Bool, false, key) }
        XCTAssertEqual(result["closedTab"] as? Bool, true)
        XCTAssertEqual(result["closed"] as? [String], ["20"])
    }

    func testVisibleBrowserProductionScriptCompilesWithoutApplicationAccess() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-visible-script-\(UUID()).scpt")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await BoundedCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/osacompile"),
            arguments: ["-l", "JavaScript", "-o", url.path, "-e", VisibleBrowserAutomation.script])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testVisibleBrowserProductionScriptRejectsMultipleOrDifferentProcessInstances() async throws {
        let script = visibleFixture + #"""
        function scopedCommand(processIDs) {
            const ObjC = { import: function() {}, unwrap: function(value) { return value; } };
            function running(pid) { return { processIdentifier: pid, bundleIdentifier: 'com.google.Chrome', isTerminated: false }; }
            const $ = { NSRunningApplication: {
                runningApplicationWithProcessIdentifier: function(pid) { return processIDs.indexOf(pid) < 0 ? null : running(pid); },
                runningApplicationsWithBundleIdentifier: function() {
                    return { count: processIDs.length, objectAtIndex: function(index) { return running(processIDs[index]); } };
                }
            } };
            function Application() { return { running: function() { return true; }, windows: app.windows }; }
        """# + VisibleBrowserAutomation.script + #"""
            return JSON.parse(run(['chrome', 'com.google.Chrome', '123', String(Date.now() / 1000 + 60),
                '[100,20,800,600]', JSON.stringify({ windowID: '77', index: 1, tabID: '20', url: list[1].url() })]));
        }
        function run() {
            const multiple = scopedCommand([123, 456]);
            const different = scopedCommand([456]);
            const exact = scopedCommand([123]);
            return JSON.stringify({ multiple: multiple, different: different, exact: exact, closed: closed });
        }
        """#
        let result = try await execute(script)
        XCTAssertEqual(result["multiple"] as? Bool, false)
        XCTAssertEqual(result["different"] as? Bool, false)
        XCTAssertEqual(result["exact"] as? Bool, true)
        XCTAssertEqual(result["closed"] as? [String], ["20"])
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

    private let visibleFixture = #"""
    const closed = [];
    let selectedIndex = 1, frame = { x: 100, y: 20, width: 800, height: 600 };
    function makeTab(id, url) {
        return { id: function() { return id; }, currentURL: url,
            index: function() { return list.indexOf(this) + 1; },
            url: function() { return this.currentURL; }, close: function() { closed.push(String(id)); } };
    }
    const list = [makeTab(10, 'https://safe.example/'), makeTab(20, 'https://youtube.com/watch?v=example'), makeTab(30, 'https://other.example/')];
    const tabs = function() { return list; };
    tabs.byId = function(id) { return list.filter(function(t) { return t.id() === id; })[0]; };
    for (let i = 0; i < list.length; i++) Object.defineProperty(tabs, String(i), { get: function() { return list[i]; } });
    const window = { id: function() { return 77; }, tabs: tabs, bounds: function() { return frame; },
        currentTab: function() { return list[selectedIndex]; }, activeTab: function() { return list[selectedIndex]; },
        activeTabIndex: function() { return selectedIndex + 1; } };
    const windowList = [window];
    const app = { windows: function() { return windowList; } };

    """#
}
