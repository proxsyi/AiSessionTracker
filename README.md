# Claude Session Pinger

A native macOS menu-bar app for tracking Claude usage and starting Claude sessions on an intentional schedule.

## Features

- Shows Claude's reported 5-hour, weekly, and optional Fable usage windows.
- Reuses one dedicated Claude conversation for scheduled, manual, and connection-test pings.
- Enforces five-hour spacing between scheduled starts, including overnight.
- Offers independent next-possible and scheduled-session countdowns.
- Supports optional notifications for usage, pings, and Claude service health.
- Supports optional closed-lid wake, ping, and return-to-sleep on a plugged-in MacBook.
- Command-U toggles the popover; clicking elsewhere closes it like a normal menu-bar item.

## Install

Download `ClaudeSessionPinger.app.zip` from the latest `v*` release, unzip it, move **Session Pinger.app** to `/Applications`, and open it.

Open **Settings > General**, then sign in through the private in-app browser. The app captures the Claude web session without reading Safari or Chrome cookies.

## Data and permissions

- One `webSession` record is stored in Keychain service `com.proxsyi.claudesessionpinger`.
- Settings and activity history remain local to the Mac.
- Notifications, Launch at Login, and wake support are optional.
- The isolated wake helper is `com.proxsyi.claudesessionpinger.wake-helper` and is installed only after administrator approval.
- Credentials are never written to logs or plain-text files.

Claude's consumer-web endpoints are undocumented, so provider changes can require an app update.

## Build

Requires macOS 13 or newer and Xcode command-line tools.

```bash
git clone --branch claude-session-pinger https://github.com/proxsyi/AiSessionTracker.git
cd AiSessionTracker
swift test
./Scripts/build_app.sh
```

The signed local build is written to `dist/Session Pinger.app`.

## Uninstall

Use **Log out** first to remove the Claude web session, quit the app, and move it from `/Applications` to the Trash. Remove the privileged wake helper only when this app and AI Session Tracker no longer need their respective Claude wake features.
