import AppKit
import Foundation
import ScreenCaptureKit

@MainActor
final class MacScreenshotActions: ScreenshotActions, ScreenshotObservationProviding {
    private let permissions: FocusPermissions
    private let runner = BoundedCommandRunner()

    init(permissions: FocusPermissions) { self.permissions = permissions }

    func revalidate(_ window: ScreenshotWindow, before deadline: Date) async throws -> Bool {
        guard permitted(window, before: deadline) else { return false }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard permitted(window, before: deadline),
              let display = content.displays.first(where: { $0.displayID == window.displayID }) else { return false }
        return ScreenshotWindowAssociation.windows(on: display.displayID, frame: display.frame,
            from: ScreenshotWindowAssociation.descriptors(content)).contains(window)
    }

    func terminate(_ window: ScreenshotWindow) -> Bool {
        guard permissions.effectsEnabled, !Task.isCancelled,
              let running = NSRunningApplication(processIdentifier: window.application.processID),
              running.bundleIdentifier == window.application.bundleID else { return false }
        return running.forceTerminate()
    }

    func visibleTab(in window: ScreenshotWindow, browser: ScriptableBrowser, before deadline: Date) async throws -> VisibleBrowserTab? {
        guard browser.bundleID == window.application.bundleID, permissions.automation[browser] == .granted,
              try await revalidate(window, before: deadline) else { return nil }
        let output = try await command(window, browser: browser, before: deadline, expected: nil)
        try Task.checkCancellation()
        guard permitted(window, before: deadline), permissions.automation[browser] == .granted,
              let tab = try JSONDecoder().decode(BrowserTab?.self, from: output) else { return nil }
        return VisibleBrowserTab(window: window, browser: browser, tab: tab)
    }

    func close(_ target: VisibleBrowserTab, before deadline: Date,
               authorizing: @MainActor () -> Bool) async throws -> Bool {
        guard target.browser.bundleID == target.window.application.bundleID,
              permissions.automation[target.browser] == .granted,
              try await revalidate(target.window, before: deadline),
              authorizing() else { return false }
        let output = try await command(target.window, browser: target.browser, before: deadline, expected: target.tab)
        try Task.checkCancellation()
        return try JSONDecoder().decode(Bool.self, from: output)
    }

    private func permitted(_ window: ScreenshotWindow, before deadline: Date) -> Bool {
        guard permissions.effectsEnabled, !Task.isCancelled, Date() < deadline,
              let running = NSRunningApplication(processIdentifier: window.application.processID) else { return false }
        return !running.isTerminated && running.bundleIdentifier == window.application.bundleID
    }

    private func command(_ window: ScreenshotWindow, browser: ScriptableBrowser, before deadline: Date,
                         expected: BrowserTab?) async throws -> Data {
        guard permitted(window, before: deadline), permissions.automation[browser] == .granted else { throw DetectionFailure.unavailable }
        let frame = window.frame
        let bounds = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        let boundsJSON = String(decoding: try JSONEncoder().encode(bounds), as: UTF8.self)
        let tabJSON = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        return try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: [
            "-l", "JavaScript", "-e", VisibleBrowserAutomation.script, browser.rawValue, browser.bundleID,
            String(window.application.processID), String(deadline.timeIntervalSince1970), boundsJSON, tabJSON
        ])
    }
}

enum VisibleBrowserAutomation {
    static let operation = #"""
    function visibleBrowserOperation(app, kind, allowed, bounds, expected) {
        const empty = expected === null ? null : false;
        function rectangle(value) {
            if (!value || Array.isArray(value)) return null;
            const result = [value.x, value.y, value.width, value.height];
            return result.every(function(v) { return typeof v === 'number' && isFinite(v); }) &&
                   result[2] > 0 && result[3] > 0 ? result : null;
        }
        function matchingWindow() {
            if (!allowed()) return null;
            const windows = app.windows(), matches = [];
            for (let i = 0; i < windows.length; i++) {
                const actual = rectangle(windows[i].bounds());
                if (actual && actual.every(function(v, index) { return Math.abs(v - bounds[index]) <= 1; })) matches.push(windows[i]);
            }
            return matches.length === 1 ? matches[0] : null;
        }
        function selected(window) {
            const tabs = window.tabs();
            const index = Number(kind === 'chrome' ? window.activeTabIndex() : window.currentTab().index()) - 1;
            if (!Number.isInteger(index) || index < 0 || index >= tabs.length) return null;
            const tab = tabs[index], url = tab.url();
            const active = kind === 'chrome' ? window.activeTab() : window.currentTab();
            if (typeof url !== 'string' || !url || active.url() !== url) return null;
            if (kind === 'chrome' && String(active.id()) !== String(tab.id())) return null;
            return { windowID: String(window.id()), index: index, tabID: kind === 'chrome' ? String(tab.id()) : null, url: url };
        }
        function same(actual, target) {
            return actual && actual.windowID === target.windowID && actual.url === target.url &&
                (kind === 'chrome' ? actual.tabID === target.tabID && !!target.tabID : actual.index === target.index);
        }
        const window = matchingWindow();
        if (!window) return empty;
        const actual = selected(window);
        if (expected === null) return allowed() ? actual : null;
        if (!same(actual, expected)) return false;
        const target = kind === 'chrome' ? window.tabs.byId(Number(expected.tabID)) : window.tabs[expected.index];
        const current = matchingWindow();
        if (!current || !same(selected(current), expected) || target.url() !== expected.url || !allowed()) return false;
        target.close();
        return true;
    }
    """#

    static let script = operation + #"""

    ObjC.import('AppKit');
    function run(args) {
        const kind = args[0], bundleID = args[1], pid = Number(args[2]), deadline = Number(args[3]) * 1000;
        const bounds = JSON.parse(args[4]), expected = JSON.parse(args[5]);
        function allowed() {
            const instances = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(bundleID);
            if (Number(instances.count) !== 1 || Number(instances.objectAtIndex(0).processIdentifier) !== pid) return false;
            const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
            return Date.now() < deadline && app && !app.isTerminated && ObjC.unwrap(app.bundleIdentifier) === bundleID;
        }
        if (!allowed()) return expected === null ? 'null' : 'false';
        const app = Application(bundleID);
        if (!app.running()) return expected === null ? 'null' : 'false';
        return JSON.stringify(visibleBrowserOperation(app, kind, allowed, bounds, expected));
    }
    """#
}
