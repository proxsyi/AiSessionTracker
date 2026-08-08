# AI Session Tracker

Three native macOS menu-bar apps for tracking Claude, Codex, and ChatGPT usage.

| App | Purpose | Branch |
| --- | --- | --- |
| **AI Session Tracker** | Claude, Codex, and ChatGPT in one three-tab app | `main` |
| **Claude Session Pinger** | Claude usage, scheduled session pings, and optional wake support | `claude-session-pinger` |
| **GPT Usage Tracker** | Codex and ChatGPT usage without session-pinging or wake features | `gpt-session-pinger` |

## AI Session Tracker

The mixed app keeps Claude and OpenAI logins, settings, alerts, and updater identities separate while presenting one consistent interface.

- Claude, Codex, and ChatGPT dashboards use matching tabs and cards.
- Usage counters appear only when the signed-in service reports them.
- Claude keeps its 5-hour scheduling and ping workflow.
- Codex tracks rolling windows, weekly usage, code review, workspace state, and credits when reported.
- ChatGPT tracks message, model, and feature allowances only when reported.
- Every visible counter and alert can be enabled independently.
- The menu-bar star and ring can use separate Claude and GPT percentage sources.
- Command-U opens Claude; Command-I opens the last selected Codex or ChatGPT tab.

## Install

Download `SessionTracker.app.zip` from the latest `tracker-v*` GitHub Release, unzip it, move **Session Tracker.app** to `/Applications`, and open it.

Public downloads must be signed with Developer ID Application and notarized by Apple. Local Apple Development builds are intended only for the developer’s Mac.

## Sign in

Open **Settings**, choose a service, and use its built-in private browser:

1. **Claude** captures the Claude session and organization.
2. **Codex** and **ChatGPT** share one ChatGPT login.
3. Logging out of one provider clears only that provider’s stored web session and embedded-browser data.

The app does not read Safari or Chrome cookies.

## Data and permissions

- Keychain service `com.proxsyi.claudesessionpinger`: one Claude `webSession` record.
- Keychain service `com.proxsyi.gptsessionpinger`: one ChatGPT `webSession` record shared by the Codex and ChatGPT tabs.
- Settings stay in the provider-specific `UserDefaults` domains so standalone and mixed apps remain compatible.
- Notifications are optional and controlled per usage counter and service state.
- Launch at Login is optional.
- Wake support exists only for Claude scheduling. The mixed app uses `com.proxsyi.sessiontracker.wake-helper`; the standalone Claude app uses its own isolated helper.
- GPT Usage Tracker has no wake helper or administrator installation.

Credentials are not written to logs or plain-text files. The apps use consumer-web sessions and undocumented service endpoints, so provider changes can require an update.

## Build

Requires macOS 13 or newer and Xcode command-line tools.

```bash
git clone https://github.com/proxsyi/AiSessionTracker.git
cd AiSessionTracker
swift test
./Scripts/build_app.sh
```

The signed local build is written to `dist/Session Tracker.app`.

## Branches and releases

- `main` is always the deployable mixed app.
- `claude-session-pinger` is always the deployable Claude-only app.
- `gpt-session-pinger` is always the deployable GPT-only app.

Each release train builds, tests, signs, notarizes, and publishes all three apps with separate bundle IDs, tags, assets, and update feeds. See [AGENTS.md](AGENTS.md) for the exact release contract.

## Uninstall

Quit the app and move it from `/Applications` to the Trash. The in-app **Log out** buttons remove stored web sessions without affecting browser logins.

Only remove a wake helper when the corresponding app will no longer be used:

```bash
sudo rm -f /Library/PrivilegedHelperTools/com.proxsyi.sessiontracker.wake-helper
sudo rm -f "/Library/Application Support/SessionTracker/allowed_uid"
sudo rmdir "/Library/Application Support/SessionTracker" 2>/dev/null || true
```

Do not remove the standalone Claude helper if Claude Session Pinger is still installed.
