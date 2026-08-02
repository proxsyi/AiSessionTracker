# Session Tracker

A combined macOS menu bar app with three dashboards: Claude, Codex, and ChatGPT.

## What it combines

- **Claude** keeps the complete Session Pinger experience: browser login, live session and weekly usage, scheduled pings, alerts, activity, wake support, and model selection.
- **Codex** shows its rolling and weekly usage windows, credits, code-review limits, reset times, history, and optional alerts.
- **ChatGPT** shows every account-reported model and feature allowance, including rolling windows, deep research, uploads, image generation, voice, and other limits when available.
- Settings open for the currently selected service. A Claude/GPT selector sits to the left of the existing General, Usage, Alerts, and App sections.

The menu bar symbol is one combined meter: its inner star follows Claude session usage, while its outer ring follows Codex weekly usage. Each part changes color independently.

## Isolation

Session Tracker uses its own bundle identifier (`com.proxsyi.sessiontracker`) and app bundle. Claude and GPT retain separate preferences and Keychain services, so their credentials and settings cannot overwrite one another. Building this branch does not remove either standalone app.

## Build

Requires macOS 13+ and Xcode command-line tools.

```bash
swift test
./Scripts/build_app.sh
```

The signed app is written to `dist/Session Tracker.app`.
