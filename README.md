# Hawkeye 2

A small native macOS task app with TickTick, Todoist, or Notion sync. Requires macOS 14 or later and Swift 6. The interface follows Hawkeye's forest palette, serif headings, and 2:4:1 layout.

The Windows port is in `Desktop`. Copy `dist/Hawkeye-Windows-x64.exe` to a Windows 10 or Windows 11 laptop and run it. The executable includes the .NET runtime and browser setup files. Chrome and Edge have native Windows browser access without an extension. See [Windows setup](docs/WINDOWS.md), [portable architecture](docs/PORT_DESIGN.md), and [verification results](docs/PORT_VERIFICATION.md). Screenshots and macOS data import are excluded. The same portable projects include Linux adapters.

## Run the app

Run `swift run Hawkeye2` from this directory for the developer version. Debug builds save the PAT in a local text file and use separate development task data.

To build a standalone app, run `zsh scripts/build-app.sh`. Open `dist/Hawkeye 2.app`. The script signs the app with a certificate-backed code-signing identity and verifies its signature.

On the first build, the script selects your signing identity automatically when exactly one valid identity is available. It saves that certificate's public fingerprint in the ignored `.signing-identity` file and reuses it on future builds. The certificate and private key remain in your Keychain. If several identities are available, set `HAWKEYE_SIGNING_IDENTITY` to the desired SHA-1 fingerprint. List available identities with `security find-identity -v -p codesigning`.

Builds stop if the pinned identity is unavailable. They never fall back to ad-hoc signing. Release builds use Keychain. Older entries can retain access rules from previous builds and continue to prompt. Developer builds use a text file and never fall back to Keychain when that file is missing or unreadable.

Run `zsh scripts/verify-signing.sh` to check that different executable builds satisfy the same signing requirement, an ad-hoc replacement is rejected, and missing identities stop the build. This check signs temporary fixtures and never reads the TickTick token.

## Iterate on the developer app

Run `zsh scripts/build-app.sh --development`, then open `dist/Hawkeye 2 Dev.app`. To run from source, use `swift run Hawkeye2` or the VS Code **Debug Hawkeye2 (file PAT)** configuration. All debug launches use the same development credential file and preferences.

Connect through third-party app settings once. Developer builds save the selected app's PAT as plain text in `~/Library/Application Support/Hawkeye2/Development`, with file permissions `0600`. Each provider has its own token file. The existing TickTick path remains `ticktick-pat.txt`. These files live outside the repository and are not included in the app bundle. Release builds use provider-specific Keychain entries.

Development tasks live at `~/Library/Application Support/Hawkeye2/Development/tasks.json`. Production tasks remain at `~/Library/Application Support/Hawkeye2/tasks.json`. Both builds can sync to the same TickTick account, but have separate local stores and destination preferences. `--data-directory` verification sessions still skip all credentials and cannot save a connection.

Run `zsh scripts/build-app.sh` for the release app. The VS Code **Release Hawkeye2 (Keychain)** configuration also uses Keychain. To remove the old Hawkeye PAT entry, quit the release app and run `security delete-generic-password -s com.hawkeye2.mac.ticktick -a personal-access-token`. This removes that credential without deleting any other Keychain items or task data.

## Connect a task app

1. Create a personal token for your chosen app. TickTick exposes **Settings → Account → API Token**. Todoist exposes its API token in **Settings → Integrations → Developer**. For Notion, open [Personal access tokens](https://www.notion.so/developers/tokens) and enable the **Notion API** capability.
2. Open Hawkeye's third-party app settings using the sliders button at the bottom of the middle pane, or press Command-comma. Choose **TickTick**, **Todoist**, or **Notion**.
3. Paste the token and click **Check token**.
4. Choose the list, project, or Notion database that receives tasks. For Notion, map the title, completion, and date properties. If the completion field uses named statuses, choose the open and completed values.
5. Click **Connect and sync**. Only one app can be connected at a time.

Settings fetches destinations using the saved token each time it opens. The refresh button fetches them again. Changing the destination within the same app applies to new tasks. The token field stays hidden until you click **Change token**.

Changing the selected app is a draft until you save a validated connection. When you switch, Hawkeye retains every task saved in `tasks.json`, including imported tasks and completed tasks. It removes the previous connection's remote identities, pending bindings, and sync history. Retained tasks can sync to the new destination. No tasks are deleted from the previous app.

Hawkeye polls the selected app every 60 seconds while running and syncs after local changes. Manual sync is available through the footer button or Command-Shift-R. Closing the final window keeps Hawkeye running in the background.

## Start at login and run in the background

Open the signed release app once to enable launch at login. Keep the app in a permanent location. Hawkeye starts quietly in the menu bar after you log in to your Mac. Task scheduling, sync, and focus monitoring continue when the main window is closed. macOS permissions are requested when you open Hawkeye's window, rather than during background startup.

Click the eye in the menu bar and choose **Open Hawkeye** to reopen the window. **Settings…** opens settings. Change **Launch at login** in either the menu or settings. If macOS requires approval, use **Allow in Login Items…** to open System Settings. Later changes you make in System Settings are respected on subsequent app launches.

Choose **Quit Hawkeye** from the menu or press Command-Q to stop the app until you open it again or next log in. The developer app supports the same controls but requires you to enable launch at login explicitly. Bare `swift run` processes and isolated `--data-directory` sessions cannot register login items. Add `--background` when launching an isolated session to check startup without opening a window.

Disconnect keeps your saved tasks. Switching apps clears the previous connection data before connecting the new provider. Use a separate data directory for separate task collections.

## Use tasks

Enter a title, choose a start date and time, then press Return or click the arrow. The suggested start is the next half-hour boundary, such as 10:30 when the time is 10:15. Click the schedule button to open the clock and calendar picker. Changes apply when you click **Set start time**. Choose a duration beside the schedule button from 20 minutes, 30 minutes, 1 hour, 1 hour 30 minutes, or 2 hours. Choose **Custom…** to enter 1 to 1,440 minutes. Tasks without a duration use 30 minutes. Open task details beside the arrow to add a description or turn off the start time.

The middle pane sorts unfinished tasks by their start time. Use **Due now** to view tasks whose start time has arrived or **Today** to include tasks scheduled before tomorrow. Tasks without a start time appear under **All tasks** and never activate automatically.

At the start time, a task becomes active and gets a green dot. The right pane shows the focused eye in the original Hawkeye style. The packaged app asks for notification permission and sends the task title with "It's time to start." Foreground notifications are enabled too. Notifications require the packaged `.app`; a bare `swift run` process logs that notifications are unavailable.

Only one task is active. The earliest scheduled start wins, with creation time and task ID breaking ties. Tasks remain eligible until their original start plus duration, excluding the exact end instant. Completing or expiring the active task activates the next eligible task. Expired unfinished tasks show **Overdue**. Imported or reopened tasks activate only if their scheduled window is still open.

Right-click the active task for **Pause → 2, 3, or 5 minutes** and **Defer**. Pause pauses activation for every task. The eye relaxes unless a Pomodoro is running. Pause does not move any task's start or end time. Each task permits one pause. The user's snooze stores that task ID and survives restart; another task has its own pause allowance. After a task uses its pause, the **Pause** option disappears. Resuming a paused task does not repeat its start notification.

Right-click any inactive unfinished task, including an overdue or unscheduled task, for **Start Now**. It updates the start time to now, keeps the duration, syncs the schedule to TickTick, and activates that task. The option is absent on the active task. When another task is active, **Start Now** is disabled with an explanation. Starting during a user pause ends the pause and keeps the selected task active ahead of earlier overlapping tasks. Its used pause allowance remains unchanged.

**Defer** asks for a new future start time, keeps the duration, and queues the change for TickTick. Deferral does not reset the task's pause allowance. TickTick tasks with start and end dates retain that interval when moved. Offline changes sync when the connection returns. The current user pause continues until its chosen end even if its original task is completed or deferred.

Click a task's circle to complete it. Completed tasks move to the left pane. Uncheck a completed task to reopen it. Double-click any unfinished task to edit it. The relaxed eye appears when no task or Pomodoro is active. Activation runs independently of the visible pane while the app is running, checks again after wake or clock changes, and stops when the app quits.

## Use the Pomodoro timer

Click **Start focus** below the eye in the right pane. Pomodoro works with an empty task list and never changes task schedules or TickTick data. Focus defaults to 25 minutes, followed by a 5-minute break. Both phases repeat until you click **Stop timer**. Closing the window keeps the timer running. Quitting the app stops it.

Use the sliders button beside **POMODORO** to set whole minutes for focus and break, then click **Save**. Focus accepts 1 to 180 minutes, and break accepts 1 to 60 minutes. Durations persist between launches. Changes made during a run apply the next time you start the timer.

Each phase ending sends a macOS notification, even with no active task. The break notification and the timer pane prompt you to drink a glass of water. Notifications need permission in the packaged app. Starting Pomodoro marks monitoring active and enables blocking and screenshot sampling throughout focus and breaks. Pausing or completing a task does not stop a running Pomodoro. Stopping Pomodoro leaves monitoring active if a task is still active. Wake checks reconcile the current phase once instead of replaying missed alerts.

## Configure focus blocking

Open the gear button at the bottom-right to configure blocked apps and websites. The default blocks are Chess, Firefox, and `instagram.com`. **Add app…** selects a Mac application by its bundle identifier. Website entries accept a domain or an HTTP or HTTPS URL and save its hostname. Remove an entry with its minus button. Changes save locally and apply immediately, including during an active task. Development and release builds keep separate preferences. Isolated sessions save `focus-policy.json` inside their data directory.

While a task or Pomodoro is active, Hawkeye checks the foreground app about once per second. A blocked app closes completely when brought to the front. Firefox is a whole-app block by default, including all its other tabs, because it has no supported tab automation. You can remove Firefox or add other apps in the configuration panel. Hawkeye cannot add itself to the blocked list.

When Safari or Google Chrome is in front, Hawkeye inspects open tabs across its windows and closes only tabs whose actual HTTP or HTTPS hostname matches a blocked domain or its subdomains. `instagram.com.evil.example`, query strings, and URL usernames do not cause false matches. A browser added to the blocked apps list closes completely instead. Other browsers do not support website blocking in this version. No browser JavaScript-from-Apple-Events setting is needed.

In **Youtube Category**, click **Enable** to allow only YouTube videos in your category whitelist during monitoring. Filtering starts disabled, with **Education** whitelisted. Choose a category from **Add to whitelist** to add it. The menu and whitelist show category names in alphabetical order. Use a category's minus button to remove it. Changes save locally and apply immediately. App and website blocks take priority. Category filtering applies only to video URLs, such as `/watch?v=...`. The homepage, search results, and channel pages stay open. Videos with unavailable categories or categories outside the whitelist close.

Category lookup first reads the loaded tab's HTML, then falls back to a YouTube watch-page request if needed. Both methods require metadata for the URL's video ID. This follows the two lookup methods in `hawkeye_llm_eval/YTCategorychecker` and runs natively without Python or an API key. Safari exposes page source directly. Chrome uses its page JavaScript command when available and falls back to the request when that command is disabled. Successful lookups are cached for five minutes, and unavailable results for 15 seconds. The dropdown includes every category name, with **Comedy** shown once. Incorrect video categorization can cause unexpected blocking.

Blocking stops when neither a task nor Pomodoro is active. Task pauses, completion, and expiry leave a running Pomodoro's monitoring active. Restarting an active task occurrence resumes blocking even if its start notification was already delivered. Changing an active task's duration updates the monitoring deadline.

The first launch of the signed, packaged app opens **Focus permissions** and requests Notifications, Accessibility for computer control, and Screen Recording for monitoring screenshots. With Screen Recording access, Hawkeye captures each connected display every minute while a task or Pomodoro is active. It checks on-screen application windows on each display against your blocked apps and saves a small thumbnail for each display. A blocked app on another monitor can close even when an allowed app is in front. Foreground app detection and app blocking work without Accessibility or Screen Recording. Browser tab blocking requires separate **Automation** access for each supported browser. Hawkeye requests that access only while the browser is already running and never opens a browser for setup. An unanswered permission prompt does not pause task scheduling.

Reopen **Focus permissions…** from the app menu, TickTick settings, or the focus configuration panel. It shows current access and links to the relevant System Settings panes. If you deny access, enable Hawkeye in System Settings and refresh the status. Some macOS permission changes require reopening Hawkeye. Each browser's initial consent request runs once per Hawkeye preference profile. You can request it again manually. A bare `swift run` process shows the packaged-app requirement and disables system effects because macOS cannot reliably attribute its permissions.

The monitor checks the current task, deadline, foreground app identity, and policy again after asynchronous tab reads. It revalidates the exact URL before closing a tab. Chrome uses stable window and tab IDs. Safari has no stable tab ID, so it uses window ID and tab position, closes in reverse order, and skips a tab if its URL changed. Rapid browser edits can still race between the last URL read and the close event. Browser commands time out after four seconds and are cancelled when focus or policy changes. An AppleEvent already delivered to a browser cannot be withdrawn and may finish after a pause or policy edit.

To identify the foreground app from Terminal with the same native API, use this read-only command:

```sh
osascript -l JavaScript -e 'ObjC.import("AppKit"); ObjC.unwrap($.NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier)'
```

## Read activity logs

Developer builds write readable activity to `~/Library/Logs/Hawkeye2/Development/activity.log`. Release builds write to `~/Library/Logs/Hawkeye2/activity.log`. Files rotate at 5 MiB and retain one `.previous` file. Logs include task actions, activation and deactivation reasons, user pauses, notification results, and TickTick sync summaries and errors. Focus blocking records distraction detection, closing attempts, accepted close requests, failures, and skipped-tab outcomes using the configured app name or domain. Missing browser Automation access is also recorded. Repeated failures for the same target are suppressed while blocking continues retrying. Browsing URLs, tab titles, credentials, and HTTP payloads are not logged.

Click the small activity button at the bottom-right to open a separate live activity window. It shows the latest 500 events from this session and offers **Open log file** and **Show in Finder**. The window is available in development and release builds. Isolated `--data-directory` sessions write `activity.log` inside that directory.

While monitoring is active, Hawkeye also retrieves the foreground Safari or Google Chrome page's accessibility text, immediately and then once a minute after each attempt. This requires Accessibility access and works independently of Screen Recording and browser Automation. Expand **Browser text** in an activity entry to read the main content, and **All page text** for the complete captured text. Pages without an unambiguous main or article region show that main content was not identified. There are no site rules or filter settings. Text is limited to what the browser exposes and may include offscreen content. Up to 240 private local JSON attachments are retained in `activity.browser-content`. Captured text, page titles, and URLs do not enter the plain text log. See [macOS browser text](docs/MACOS_BROWSER_TEXT.md).

Screenshots first appear after one minute of active monitoring. The next capture starts a minute after the previous capture finishes. Without a running Pomodoro, task pause, completion, expiry, or replacement stops sampling and discards pending results. Pomodoro phase changes keep the capture cadence. Editing the same task's title or duration keeps its cadence and updates its capture deadline. Screenshot timing is independent of blacklist edits and the chosen distraction detector. Missing Screen Recording access produces a status entry and retries next minute without another consent prompt.

Screenshot entries identify the display and show a small preview in the activity window. Click a preview to open the local JPEG. Each display is captured without the cursor or audio. Processors receive the full image in memory, and only a thumbnail with a maximum 480-pixel edge is saved. Displays added or removed are picked up at the next sample. A capture or processing failure on one display does not discard successful captures from other displays. Thumbnails live beside `activity.log` in `activity.screenshots`, with folder permissions `0700` and JPEG permissions `0600`. The text log stores a relative thumbnail path. Hawkeye keeps at most 240 UUID-named JPEGs in total across displays and launches, then removes the oldest. Other files are preserved. Older text entries can outlive their thumbnails and show **Screenshot no longer retained**. Screenshot contents can include visible app text; Hawkeye does not run OCR or model inference on them.

## Verify changes

Run `swift test`. The tests use temporary stores and a mock HTTP transport without accessing your account. Monitoring tests inject fake foreground apps, browser observations, and screenshot sources. Screenshot persistence tests use generated images. JXA fixtures operate on in-memory mock tabs. No tests request macOS access, capture the desktop, inspect real browser tabs, or close real apps.

For an isolated manual UI check, run `swift run Hawkeye2 --data-directory /tmp/hawkeye2-check`. This session uses its own task and blacklist files, skips saved credentials, and blocks saving a connection. Permissions UI remains available with request actions disabled. It never requests system access, captures the desktop, inspects real apps, sends browser events, or terminates apps.

To check the packaged app, run `zsh scripts/prepare-ui-check.sh` after building. Open `.work/Hawkeye 2 Check.app`. It uses `.work/ui-data/tasks.json` and skips saved credentials.

## Extend the app

`Sources/HawkeyeCore` owns the task model, durable storage, and sync. `TaskService` is the single writer of task state. Add future AI tracking through that service rather than mutating view snapshots or writing the JSON file directly. The core has no SwiftUI dependency.

`Sources/Hawkeye2` contains the SwiftUI panes, task editor, settings, Keychain access, and the `AppModel` adapter. `DistractionSettings` owns local blacklist persistence.

`DistractionMonitor` owns foreground enforcement and logging. It accepts a Sendable async `DistractionDetecting` provider that receives task, policy, deadline, and foreground context and returns typed findings. `DeterministicDistractionDetector` is the only implementation. Other foreground detectors can supply their own dependencies and polling interval while sharing the coordinator's checks and native actions. Use `ScreenshotProcessing` for OCR or LLM evaluation across displays. Classification without an exact approved app or tab target is observation-only. See [the core design](DESIGN.md) for extension requirements.

`ScreenshotMonitor` schedules task screenshots through an injected `ScreenshotCapturing` source. Each display has an independent analysis and runs the same ordered processor list. Pass that list through `AppModel(screenshotProcessors:)` to compose future OCR and LLM steps; include `BlacklistedApplicationProcessor()` to retain the default screenshot blacklist checks. Steps can share typed results within one display's analysis without mixing results from other displays. An inferred browser distraction must identify one exact tab and its captured window before it can request a close. It must never become a request to quit the browser. Native actions revalidate the window, process, and tab before acting. `ActivityLog` owns thumbnail files and retention. Screenshot capture does not change the foreground detector contract. `ScriptableBrowser` owns the browser capability registry. Add a new browser only after checking its scripting dictionary and tab identity guarantees. `Theme.swift` defines the palette. No AI monitoring or inference runs in this version.

The adapters follow the [TickTick Open API reference](https://developer.ticktick.com/docs/index.html#/openapi), [Todoist API v1 reference](https://developer.todoist.com/api/v1/), and [Notion data-source API](https://developers.notion.com/reference/query-a-data-source). Notion requests pin API version `2026-03-11`. Live sync requires a token and a reachable provider.

TickTick imports your lists and Inbox. Initial sync requests the last 30 days of completed tasks, then subsequent syncs request newer completions. TickTick caps Inbox and completed queries at 200 results. Hawkeye displays a warning when it reaches a cap. It retains local completion history and checks known remote tasks individually for changes. Creation time falls back to the first import time when TickTick omits it. TickTick start and end dates supply an imported duration. A local duration overrides that duration. User snooze stays local.

Sync retries use the same remote task ID after a failed create. The mock server verifies recovery when the server accepts that ID. Real-account acceptance of client-supplied IDs still needs validation. See [the core design](DESIGN.md) for these API limits and conflict rules.

Pending local edits take precedence over remote changes to that task until uploaded. Hawkeye preserves TickTick's additional task metadata, such as checklist items and recurrence.

Todoist uses cursor pagination for projects and tasks. New tasks use the Sync API's documented command UUID to make retries safe. Notion reads tasks from the selected database's data source and updates only the mapped properties. Descriptions can use an optional rich-text property. Without that mapping, descriptions stay local and existing page content remains untouched.

Notion does not document an idempotency key for creating pages. If creation has an uncertain outcome, Hawkeye keeps the task and pauses its automatic creation. Check the database before using the recovery action to attach the existing page or retry. This prevents polling or restarting from repeatedly creating the same task.
