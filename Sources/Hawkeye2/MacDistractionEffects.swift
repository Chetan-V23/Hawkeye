import AppKit
import Foundation

@MainActor
final class MacDistractionEffects: DistractionActions, DeterministicObservation, YouTubePageSourceReading {
    private let permissions: FocusPermissions
    private let runner = BoundedCommandRunner()

    init(permissions: FocusPermissions) { self.permissions = permissions }

    func frontmostApplication() -> ForegroundApplication? {
        guard permissions.effectsEnabled, let application = NSWorkspace.shared.frontmostApplication,
              let bundleID = application.bundleIdentifier else { return nil }
        return ForegroundApplication(bundleID: bundleID, processID: application.processIdentifier)
    }

    func canAutomate(_ browser: ScriptableBrowser) -> Bool { permissions.automation[browser] == .granted }

    func terminate(_ application: ForegroundApplication) -> Bool {
        guard permissions.effectsEnabled, frontmostApplication() == application,
              let running = NSRunningApplication(processIdentifier: application.processID),
              running.bundleIdentifier == application.bundleID else { return false }
        return running.forceTerminate()
    }

    func tabs(in browser: ScriptableBrowser, application: ForegroundApplication, before deadline: Date) async throws -> [BrowserTab] {
        guard permissions.effectsEnabled, canAutomate(browser) else { return [] }
        let output = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: [
            "-l", "JavaScript", "-e", BrowserAutomation.script, browser.rawValue, browser.bundleID,
            String(application.processID), String(deadline.timeIntervalSince1970), "read"
        ])
        return try JSONDecoder().decode([BrowserTab].self, from: output)
    }

    func close(_ tab: BrowserTab, in browser: ScriptableBrowser, application: ForegroundApplication, before deadline: Date) async throws -> Bool {
        guard permissions.effectsEnabled, canAutomate(browser), frontmostApplication() == application,
              Date() < deadline else { return false }
        let tabJSON = String(decoding: try JSONEncoder().encode(tab), as: UTF8.self)
        let output = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: [
            "-l", "JavaScript", "-e", BrowserAutomation.script, browser.rawValue, browser.bundleID,
            String(application.processID), String(deadline.timeIntervalSince1970), "close", tabJSON
        ])
        return try JSONDecoder().decode(Bool.self, from: output)
    }

    func youtubePageSource(for tab: BrowserTab, in browser: ScriptableBrowser,
                           application: ForegroundApplication, before deadline: Date) async throws -> String {
        guard permissions.effectsEnabled, canAutomate(browser), frontmostApplication() == application,
              Date() < deadline else { throw YouTubeCategoryLookupError.staleTab }
        let tabJSON = String(decoding: try JSONEncoder().encode(tab), as: UTF8.self)
        let output = try await BoundedCommandRunner(timeout: min(1.5, deadline.timeIntervalSinceNow),
            maximumOutputBytes: 12 * 1024 * 1024).run(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: [
                "-l", "JavaScript", "-e", YouTubePageSourceAutomation.script, browser.rawValue, browser.bundleID,
                String(application.processID), String(deadline.timeIntervalSince1970), tabJSON
            ])
        struct Snapshot: Decodable { let stale: Bool; let html: String? }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: output)
        guard !snapshot.stale, frontmostApplication() == application else { throw YouTubeCategoryLookupError.staleTab }
        guard let html = snapshot.html, !html.isEmpty else { throw YouTubeCategoryLookupError.unavailable }
        return html
    }
}

enum YouTubePageSourceAutomation {
    static let operation = #"""
    function youtubePageSource(app, kind, allowed, expected) {
        const stale = { stale: true, html: null }, unavailable = { stale: false, html: null };
        if (!allowed()) return stale;
        const windows = app.windows();
        for (let w = 0; w < windows.length; w++) {
            if (String(windows[w].id()) !== expected.windowID) continue;
            const tabs = windows[w].tabs();
            for (let t = 0; t < tabs.length; t++) {
                const matches = kind === 'chrome' ? String(tabs[t].id()) === expected.tabID : t === expected.index;
                if (!matches) continue;
                const window = app.windows.byId(windows[w].id());
                const target = kind === 'chrome' ? window.tabs.byId(tabs[t].id()) : window.tabs[expected.index];
                if (target.url() !== expected.url || !allowed()) return stale;
                let html;
                try {
                    html = kind === 'safari' ? target.source()
                        : target.execute({ javascript: 'document.documentElement.outerHTML' });
                } catch (_) { return unavailable; }
                if (target.url() !== expected.url || !allowed()) return stale;
                if (typeof html !== 'string' || html.length > 4 * 1024 * 1024) return unavailable;
                return { stale: false, html: html };
            }
        }
        return stale;
    }
    """#

    static let script = operation + #"""

    ObjC.import('AppKit');
    function run(args) {
        const kind = args[0], bundleID = args[1], pid = Number(args[2]), deadline = Number(args[3]) * 1000;
        function allowed() {
            const app = $.NSWorkspace.sharedWorkspace.frontmostApplication;
            return Date.now() < deadline && app && Number(app.processIdentifier) === pid && ObjC.unwrap(app.bundleIdentifier) === bundleID;
        }
        if (!allowed()) return JSON.stringify({ stale: true, html: null });
        const app = Application(bundleID);
        if (!app.running()) return JSON.stringify({ stale: true, html: null });
        return JSON.stringify(youtubePageSource(app, kind, allowed, JSON.parse(args[4])));
    }
    """#
}

enum BrowserAutomation {
    static let operation = #"""
    function browserOperation(app, kind, allowed, expected) {
        if (!allowed()) return expected === null ? [] : false;
        const windows = app.windows();
        if (expected === null) {
            const result = [];
            for (let w = 0; w < windows.length; w++) {
                const windowID = String(windows[w].id()), tabs = windows[w].tabs();
                for (let t = 0; t < tabs.length; t++) {
                    result.push({ windowID: windowID, index: t, tabID: kind === 'chrome' ? String(tabs[t].id()) : null, url: tabs[t].url() || '' });
                }
            }
            return result;
        }
        for (let w = 0; w < windows.length; w++) {
            if (String(windows[w].id()) !== expected.windowID) continue;
            const tabs = windows[w].tabs();
            for (let t = 0; t < tabs.length; t++) {
                const matches = kind === 'chrome' ? String(tabs[t].id()) === expected.tabID : t === expected.index;
                if (matches) {
                    const window = app.windows.byId(windows[w].id());
                    const target = kind === 'chrome' ? window.tabs.byId(tabs[t].id()) : window.tabs[expected.index];
                    if (target.url() === expected.url && allowed()) {
                        target.close();
                        return true;
                    }
                }
            }
        }
        return false;
    }
    """#

    static let script = operation + #"""

    ObjC.import('AppKit');
    function run(args) {
        const kind = args[0], bundleID = args[1], pid = Number(args[2]), deadline = Number(args[3]) * 1000;
        function allowed() {
            const app = $.NSWorkspace.sharedWorkspace.frontmostApplication;
            return Date.now() < deadline && app && Number(app.processIdentifier) === pid && ObjC.unwrap(app.bundleIdentifier) === bundleID;
        }
        if (!allowed()) return args[4] === 'read' ? '[]' : 'false';
        const app = Application(bundleID);
        if (!app.running()) return args[4] === 'read' ? '[]' : 'false';
        return JSON.stringify(browserOperation(app, kind, allowed, args[4] === 'read' ? null : JSON.parse(args[5])));
    }
    """#
}
