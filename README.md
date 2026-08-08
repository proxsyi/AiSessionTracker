# GPT Usage Tracker

A native macOS menu-bar app that shows the live Codex and ChatGPT limits reported by your account.

## Features

- Keeps Codex and ChatGPT in separate, matching tabs.
- Tracks rolling windows, weekly usage, code review, workspace limits, and purchased credits when ChatGPT reports them.
- Shows ChatGPT message, model, and feature allowances only when the account reports real values.
- Displays reset countdowns and locally sampled Codex trends without inventing limits.
- Lets every dashboard counter, menu-bar percentage source, chart, and notification be enabled independently.
- Offers per-counter usage alerts plus OpenAI service-health alerts.
- Command-I toggles the popover; clicking elsewhere closes it like a normal menu-bar item.

There is no session pinging, schedule, activity log, wake permission, or privileged helper in this app.

## Install

Download `GPTSessionPinger.app.zip` from the latest `gpt-v*` release, unzip it, move **GPT Usage Tracker.app** to `/Applications`, and open it.

Open **Settings > General**, then sign in through the private in-app browser. The app captures the ChatGPT web session without reading Safari or Chrome cookies.

## Data and permissions

- One `webSession` record is stored in Keychain service `com.proxsyi.gptsessionpinger` and shared by the Codex and ChatGPT tabs.
- Settings and sampled trend history stay local to the Mac.
- Notifications and Launch at Login are optional.
- Logging out clears this app's Keychain login and embedded-browser data without affecting browser sessions or Claude apps.
- Credentials are never written to logs or plain-text files.

ChatGPT's consumer-web endpoints are undocumented, so provider changes can require an app update.

## Build

Requires macOS 13 or newer and Xcode command-line tools.

```bash
git clone --branch gpt-session-pinger https://github.com/proxsyi/AiSessionTracker.git
cd AiSessionTracker
swift test
./Scripts/build_app.sh
```

The signed local build is written to `dist/GPT Usage Tracker.app`.

## Uninstall

Use **Log out** first to remove the OpenAI web session, quit the app, and move it from `/Applications` to the Trash. No wake helper or administrator-installed component needs removal.
