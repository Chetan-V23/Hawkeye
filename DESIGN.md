# Hawkeye core

The domain is a `TodoTask`, a durable `TaskState`, and one pending write per task. Completion is derived from `completedAt`. `dueAt` stores the scheduled start in Hawkeye. A local duration override does not enqueue remote writes. Remote identity includes the project and a task ID allocated once before the first create request.

Two ownership options were considered.

1. The UI owns state and passes snapshots into a sync worker. This makes binding convenient, but every response needs a revision handshake with the UI and disk writer. A response can otherwise replace an edit made while networking awaited.
2. One `TaskService` actor owns state, disk writes, and sync. The UI requests mutations and reads snapshots. Networking suspends the actor, so user edits remain available. Response acknowledgements remove only the exact pending operation sent. This is the chosen design.

`TaskState` contains pure mutations and merge rules. `TaskService` persists a new state before adopting it. JSON writes are atomic and versioned. An unsupported schema or corrupt file fails visibly rather than resetting the task list. No authentication credential appears in task persistence.

All local tasks have a durable create intent. They upload automatically once a client and destination project are configured. A client without a destination downloads tasks but leaves local creates queued. Existing remote edits retain their original project.

Sync sends the queued writes first, then reads every task project. A second sync invocation returns a skipped report while the first is running. A create writes its stable remote ID to disk before contacting TickTick and checks that exact ID before retrying. Creation confirmation is saved before completion is requested. Edits arriving during any request retain their newer pending operation. Missing records are fetched individually for their actual status. A missing or inaccessible remote record is retained locally.

The explicit create ID is sent to TickTick's Open API. Its acceptance is covered by a deterministic server fixture, not a real account test. The documented API does not promise a general idempotency key. The application must surface a failed create instead of generating a new remote ID on retry.

The `TaskServicing` protocol is the application boundary for future automation or AI commands. The HTTP transport is injectable for deterministic tests. There is no network background loop in the core. The UI schedules `sync()` every 60 seconds.

The editor update command changes only title, description, scheduled start, and duration on the latest stored task. Completion and user pause have separate commands, so saving an older editor cannot undo either action.

The client paginates the official project endpoint and imports Inbox tasks through `POST /task/filter`. It requests the last 30 days of completed tasks on first sync through `POST /task/completed`. Subsequent history queries begin 60 seconds before the previous successful history cursor. Failed history requests keep the cursor for retry. Inbox and history endpoints cap results at 200; reaching a cap produces a visible warning. Known tasks missing from these results are still checked individually. A failed list produces a warning while other lists continue importing. A 401 aborts the sync. No private endpoints or guessed completion states are used.

`TaskFocusController` is a pure state machine owned by `TaskService`. `evaluateFocus(at:)` selects one unfinished task inside its half-open scheduled interval. Priority is start, creation time, then UUID. The controller emits typed activation and deactivation events only on transitions. Its staged state and `UserFocusState` are adopted only after any required disk write succeeds.

`TaskState.userFocus` holds the user-level snooze, the IDs that consumed their one pause, and the last announced start per task. Existing JSON without this field loads an empty user model. Old per-task snooze fields are ignored. Pause suppresses every candidate without moving task dates. A pause survives completion or deferral of its originating task until its own expiry. A resumed or restarted occurrence does not repeat its start alert. A deferred occurrence can send a new alert while keeping its used pause allowance.

`startNow(id:at:)` validates current activity and commits the new task start and user focus in one actor transaction. It rejects a task that is already active or conflicts with another active task. The command ends a global snooze and records a `ManualTaskStart` containing the task ID and exact scheduled start. This occurrence takes priority over earlier overlapping tasks until completion, expiry, or rescheduling. Pause preserves that selection and the used pause IDs. The returned transitions are published once by AppModel before its normal snapshot refresh. TickTick dates are written at whole-second precision, so a remote merge preserves the existing local start if both dates serialize to the same timestamp. This prevents a manual start from losing its selection or sending a duplicate alert on sync.

AppModel broadcasts `TaskFocusEvent` through `focusEvents`. One subscriber updates the eye's published active-task ID and logs transitions; another sends macOS notifications. New side effects can subscribe without adding policy to the views. A cancellable timer sleeps until the next start, end, or snooze boundary, with a 30-second clock reconciliation limit. Wake and clock changes also trigger evaluation. Remote sync remains on its independent 60-second loop.

For imported tasks, TickTick `startDate` takes precedence over `dueDate` as the scheduled start. A positive difference between those dates supplies `remoteDuration`; the local duration override takes precedence, followed by the 30-minute default. Updating a ranged task shifts both remote dates by the same amount. Tasks represented only by `dueDate` retain that representation. Start-time edits convert all-day tasks to timed tasks; unrelated edits preserve the all-day setting.

Completion uses the dedicated completion endpoint. A generic task update preserves an existing completed status while that endpoint runs. Reopening uses a status update because TickTick does not document a dedicated reopen endpoint.

Queued local task fields take precedence over downloaded task fields until the upload is acknowledged. This is a task-level conflict policy. The service preserves TickTick fields outside the local model, including checklist items, recurrence, tags, and sort order. User snooze and local duration overrides remain local.

The throughput checkpoint is a passing test suite for disk round trips, offline retries, ambiguous creates, edits during requests, overlapping polls, remote completion, and local-field preservation. UI work can proceed independently against the public actor API.

Endpoint definitions were checked against the [official TickTick API markdown](https://developer.ticktick.com/docs/openapi.md) on 21 October 2026. Live account sync is not part of the deterministic test suite.
