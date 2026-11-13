# Hawkeye

Distraction-free work. Clear boundaries between work and leisure.

Hawkeye helps you protect the time you set aside for work. Choose the applications and websites that distract you, then start or schedule a task. While that task is active, Hawkeye automatically closes blocked applications and matching browser tabs so you can focus on what you planned to do.

You decide when to work and what to block. Hawkeye connects those choices to your tasks, helping you keep focused work and leisure separate.

![Hawkeye's main window with completed tasks on the left, task planning in the middle, and the focus timer on the right](application%20images/Starting%20App.png)

## Blocking that follows your work

Distraction blocking starts automatically when a task becomes active. When no task or Pomodoro timer is active, blocking stops and you can use those apps and websites again. Keeping Hawkeye open does not mean keeping distractions blocked all day.

For example, set aside 30 minutes to write a project update and block the social apps and websites that interrupt you. During the active task, Hawkeye closes them if you open them. Once that work period ends, you can return to them for leisure, provided no other task or Pomodoro is running.

You can also start a Pomodoro session without a task. Blocking stays active throughout that session, including its breaks, until you stop the timer.

## Tools to support distraction-free work

- Automatically close distracting applications and matching browser tabs during active work sessions.
- Choose which apps and websites to block, with website blocking in Safari and Google Chrome.
- Plan tasks with a start time, duration, and optional description.
- See your unfinished work and completed tasks side by side.
- Focus on one active task at a time, with a reminder when it is time to start.
- Start a task now, take a short pause, or move it to a later time.
- Use a Pomodoro timer for timed work sessions and breaks, even without a task.
- Keep tasks on your Mac, or sync them with TickTick, Todoist, or Notion.

## From a plan to an active task

1. Type a task in the middle of the window.
2. Choose its start time and how long you want to spend on it.
3. Press Return or click the arrow to save it.
4. When its start time arrives, the task becomes active and distraction blocking begins. A green dot marks the task, and the eye on the right opens.
5. Click the circle beside the task when you finish. It moves to **Completed tasks** on the left.

![An active task marked with a green dot, with the open eye and task title in the focus pane](application%20images/Active%20Task.png)

Double-click an unfinished task to edit it. Use its menu to start it now, pause an active task, or defer it until later. You can also reopen a completed task by clicking its checkmark.

## Choose your distractions and focus time

Use the gear in the bottom-right corner to choose your blocked apps and websites. During an active task or a running Pomodoro, Hawkeye quits blocked apps and closes matching website tabs in Safari or Google Chrome. You can also enable YouTube category filtering to allow videos in categories you choose, such as Education.

A blocked app can close entirely, including its other windows and tabs. Review the block list before starting.

The Pomodoro timer starts with 25 minutes of focus followed by a 5-minute break. Click **Start focus** beneath the timer to begin. You can change both durations using the sliders beside **Pomodoro**. Stop the timer when you finish your work session. If no task is active, blocking stops too.

Closing the main window keeps Hawkeye running in the menu bar. Use the eye icon to reopen it, change launch-at-login settings, or quit the app.

## Connect the task app you already use

Hawkeye works without a connected account. If you already use TickTick, Todoist, or Notion, you can connect one of them to sync your tasks.

Open the sliders at the bottom of the task list, choose your app, and follow the connection instructions. You will need a personal access token, a private key that lets Hawkeye access that account. Check the token, choose a destination list, project, or Notion database, then click **Connect and sync**.

![Connection settings with TickTick, Todoist, and Notion options, a hidden token, and a destination list](application%20images/Connect%20to%20third%20party%20apps.png)

Only one task app can be connected at a time. Hawkeye syncs every minute while it is running and after local task changes. Disconnecting keeps your saved tasks in Hawkeye.

## Permissions and local data

Your tasks are saved on your Mac. Connecting a task app also sends task changes to that service.

On macOS, Hawkeye requests permissions for reminders and focus monitoring. Browser tab blocking needs Automation access. With Screen Recording access, monitoring captures your displays about once a minute and saves small image previews locally. With Accessibility access, it can also save text from the foreground Safari or Chrome page locally. These records can contain sensitive content. Hawkeye does not use AI to judge what is on your screen.

You can review access through **Focus permissions** in the app. The [technical guide](docs/README.md) explains data storage, permissions, and cleanup in detail.

## Get started

The Mac app shown here requires **macOS 14 or later**. To build it from this repository, you need Swift 6 and a code-signing certificate. See [Mac build and setup instructions](docs/README.md#run-the-app).

For the separate Windows version and its platform differences, see the [Windows guide](docs/WINDOWS.md).

Developers can find build commands, troubleshooting, and test instructions in the [technical README](docs/README.md), and implementation details in the [design document](DESIGN.md).
