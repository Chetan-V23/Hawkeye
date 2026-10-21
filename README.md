# Hawkeye 2

A small native macOS task app with TickTick sync. Requires macOS 14 or later and Swift 6. The interface follows Hawkeye's forest palette, serif headings, and 2:4:1 layout.

## Run the app

Run `swift run Hawkeye2` from this directory for the developer version. Debug builds save the PAT in a local text file and use separate development task data.

To build a standalone app, run `zsh scripts/build-app.sh`. Open `dist/Hawkeye 2.app`. The script signs the app with a certificate-backed code-signing identity and verifies its signature.

On the first build, the script selects your signing identity automatically when exactly one valid identity is available. It saves that certificate's public fingerprint in the ignored `.signing-identity` file and reuses it on future builds. The certificate and private key remain in your Keychain. If several identities are available, set `HAWKEYE_SIGNING_IDENTITY` to the desired SHA-1 fingerprint. List available identities with `security find-identity -v -p codesigning`.

Builds stop if the pinned identity is unavailable. They never fall back to ad-hoc signing. Release builds use Keychain. Older entries can retain access rules from previous builds and continue to prompt. Developer builds use a text file and never fall back to Keychain when that file is missing or unreadable.

Run `zsh scripts/verify-signing.sh` to check that different executable builds satisfy the same signing requirement, an ad-hoc replacement is rejected, and missing identities stop the build. This check signs temporary fixtures and never reads the TickTick token.

## Iterate on the developer app

Run `zsh scripts/build-app.sh --development`, then open `dist/Hawkeye 2 Dev.app`. To run from source, use `swift run Hawkeye2` or the VS Code **Debug Hawkeye2 (file PAT)** configuration. All debug launches use the same development credential file and preferences.

Connect through TickTick settings once. The developer app saves the PAT as plain text at `~/Library/Application Support/Hawkeye2/Development/ticktick-pat.txt`, with file permissions `0600`. You can also paste the PAT directly into that file and relaunch. Leave out quotes or variable assignments. The file lives outside the repository and is not included in the app bundle. Disconnect deletes this file.

Development tasks live at `~/Library/Application Support/Hawkeye2/Development/tasks.json`. Production tasks remain at `~/Library/Application Support/Hawkeye2/tasks.json`. Both builds can sync to the same TickTick account, but have separate local stores and destination preferences. `--data-directory` verification sessions still skip all credentials and cannot save a connection.

Run `zsh scripts/build-app.sh` for the release app. The VS Code **Release Hawkeye2 (Keychain)** configuration also uses Keychain. To remove the old Hawkeye PAT entry, quit the release app and run `security delete-generic-password -s com.hawkeye2.mac.ticktick -a personal-access-token`. This removes that credential without deleting any other Keychain items or task data.

## Connect TickTick

1. Create a personal token in TickTick's web app under **Settings → Account → API Token**.
2. Open Hawkeye's TickTick settings using the sliders button at the bottom of the middle pane, or press Command-comma.
3. Paste the token and click **Check token**.
4. Choose the TickTick list that receives new tasks.
5. Click **Connect & sync**. Existing local tasks also upload to that list.

Once connected, settings fetches your lists again each time it opens, using the saved token and bypassing the local HTTP cache. The refresh button also fetches the lists while settings stays open. Choose another list and click **Save destination** to change where new tasks go. Tasks already synced stay in their existing lists. The token field stays hidden until you click **Change token**. Canceling token replacement keeps the saved connection.

The release app stores the token in macOS Keychain. Developer builds use the development token file described above. Hawkeye polls TickTick every 60 seconds while running and syncs after local changes. Manual sync is available through the footer button or Command-Shift-R. Closing the final window quits the app and stops polling.

Use one TickTick account with this task store. Disconnect keeps your local tasks and pending changes. Reconnect to the same account to resume sync. To use another account, keep a separate data directory.

## Use tasks

Enter a title, choose a start date and time, then press Return or click the arrow. The suggested start is the next half-hour boundary, such as 10:30 when the time is 10:15. Click the schedule button to open the clock and calendar picker. Changes apply when you click **Set start time**. Choose a duration beside the schedule button from 20 minutes, 30 minutes, 1 hour, 1 hour 30 minutes, or 2 hours. Choose **Custom…** to enter 1 to 1,440 minutes. Tasks without a duration use 30 minutes. Open task details beside the arrow to add a description or turn off the start time.

The middle pane sorts unfinished tasks by their start time. Use **Due now** to view tasks whose start time has arrived or **Today** to include tasks scheduled before tomorrow. Tasks without a start time appear under **All tasks** and never activate automatically.

At the start time, a task becomes active and gets a green dot. The right pane shows the focused eye in the original Hawkeye style. The packaged app asks for notification permission and sends the task title with "It's time to start." Foreground notifications are enabled too. Notifications require the packaged `.app`; a bare `swift run` process logs that notifications are unavailable.

Only one task is active. The earliest scheduled start wins, with creation time and task ID breaking ties. Tasks remain eligible until their original start plus duration, excluding the exact end instant. Completing or expiring the active task activates the next eligible task. Expired unfinished tasks show **Overdue**. Imported or reopened tasks activate only if their scheduled window is still open.

Right-click the active task for **Pause → 2, 3, or 5 minutes** and **Defer**. Pause relaxes the eye and pauses activation for every task. It does not move any task's start or end time. Each task permits one pause. The user's snooze stores that task ID and survives restart; another task has its own pause allowance. After a task uses its pause, the **Pause** option disappears. Resuming a paused task does not repeat its start notification.

Right-click any inactive unfinished task, including an overdue or unscheduled task, for **Start Now**. It updates the start time to now, keeps the duration, syncs the schedule to TickTick, and activates that task. The option is absent on the active task. When another task is active, **Start Now** is disabled with an explanation. Starting during a user pause ends the pause and keeps the selected task active ahead of earlier overlapping tasks. Its used pause allowance remains unchanged.

**Defer** asks for a new future start time, keeps the duration, and queues the change for TickTick. Deferral does not reset the task's pause allowance. TickTick tasks with start and end dates retain that interval when moved. Offline changes sync when the connection returns. The current user pause continues until its chosen end even if its original task is completed or deferred.

Click a task's circle to complete it. Completed tasks move to the left pane. Uncheck a completed task to reopen it. Double-click any unfinished task to edit it. The relaxed eye appears whenever no task is active. Activation runs independently of the visible pane while the app is running, checks again after wake or clock changes, and stops when the app quits.

## Read activity logs

Developer builds write readable activity to `~/Library/Logs/Hawkeye2/Development/activity.log`. Release builds write to `~/Library/Logs/Hawkeye2/activity.log`. Files rotate at 5 MiB and retain one `.previous` file. Logs include task actions, activation and deactivation reasons, user pauses, notification results, and TickTick sync summaries and errors. Credentials and HTTP payloads are not logged.

In the developer app, click the small activity button at the bottom-right to open a separate live activity window. It shows the latest 500 events from this session and offers **Open log file** and **Show in Finder**. Release builds omit that button and window. Isolated `--data-directory` sessions write `activity.log` inside that directory.

## Verify changes

Run `swift test`. The tests use temporary stores and a mock HTTP transport without accessing your account.

For an isolated manual UI check, run `swift run Hawkeye2 --data-directory /tmp/hawkeye2-check`. This session uses its own task file, skips saved credentials, and blocks saving a connection.

To check the packaged app, run `zsh scripts/prepare-ui-check.sh` after building. Open `.work/Hawkeye 2 Check.app`. It uses `.work/ui-data/tasks.json` and skips saved credentials.

## Extend the app

`Sources/HawkeyeCore` owns the task model, durable storage, and sync. `TaskService` is the single writer of task state. Add future AI tracking through that service rather than mutating view snapshots or writing the JSON file directly. The core has no SwiftUI dependency.

`Sources/Hawkeye2` contains the SwiftUI panes, task editor, settings, Keychain access, and the `AppModel` adapter. `Theme.swift` defines the palette. No AI monitoring, screen capture, or inference runs in this version.

The [TickTick Open API reference](https://developer.ticktick.com/docs/index.html#/openapi) describes the remote interface. Live sync requires a token and a reachable TickTick service.

The app imports your lists and Inbox. Initial sync requests the last 30 days of completed tasks, then subsequent syncs request newer completions. TickTick caps Inbox and completed queries at 200 results. Hawkeye displays a warning when it reaches a cap. It retains local completion history and checks known remote tasks individually for changes. Creation time falls back to the first import time when TickTick omits it. TickTick start and end dates supply an imported duration. A local duration overrides that duration. User snooze stays local.

Sync retries use the same remote task ID after a failed create. The mock server verifies recovery when the server accepts that ID. Real-account acceptance of client-supplied IDs still needs validation. See [the core design](DESIGN.md) for these API limits and conflict rules.

Pending local edits take precedence over remote changes to that task until uploaded. Hawkeye preserves TickTick's additional task metadata, such as checklist items and recurrence.
