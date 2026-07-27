# Session Pinger

A personal macOS menu bar app that sends a short message to claude.ai so Claude usage sessions begin at intentional times instead of drifting with the first manual message of the day.

## What it does

- Starts sessions on a configurable schedule. The defaults are 5:00 AM, 10:00 AM, 3:00 PM, and 8:00 PM.
- Enforces at least five hours between every scheduled start, including the overnight boundary.
- Reuses one dedicated Claude conversation for scheduled, manual, and connection-test pings.
- Treats any non-empty Claude reply as success.
- Shows session, weekly, and optional Fable 5 usage with reset times and Claude service status.
- Supports dynamic Fable-scoped payloads and labels Fable as shared weekly when Claude reports no separate allowance.
- Offers independent next-possible and scheduled countdowns.
- Can optionally start an available session immediately, except within five hours of the next scheduled start or another successful ping.
- Can wake a plugged-in, closed-lid MacBook for scheduled pings and return it to sleep when no physical input occurs.
- Provides configurable notifications and GitHub Release update checks.
- Lives only in the menu bar. There is no Dock icon.

## Get it running

1. Download `Session.Pinger.zip` from [GitHub Releases](https://github.com/proxsyi/ClaudeSessionPinger/releases) and unzip it.
2. Move `Session Pinger.app` to **Applications**.
3. Open it. If macOS says Apple could not verify the app, click **Done**, then use **System Settings > Privacy & Security > Open Anyway**.

   Terminal alternative:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Session Pinger.app"
   ```

4. Open **Settings > General > Log in with Claude**. The app captures the session, cookie header, and organization automatically.
5. Optional: in **Settings > App**, install scheduled wake support. This is a one-time administrator-authorized installation.
6. If using closed-lid wake, keep the MacBook plugged in and run the two-minute closed-lid test from Settings.

## Scheduled wake

- Scheduled wake is on by default, but requires the one-time helper installation.
- The helper is installed at `/Library/PrivilegedHelperTools/com.proxsyi.claudesessionpinger.wake-helper`.
- It is root-owned, restricted to the installing user, and accepts only fixed `version`, `schedule`, `cancel`, `hold`, and `sleep` commands.
- Wake events are registered five seconds before each scheduled ping.
- The helper holds a `PreventSystemSleep` assertion for up to 120 seconds while the app pings.
- After an automatic ping, the app waits 30 seconds and checks `IOHIDSystem` physical-input idle time. If no physical activity occurred, it requests sleep.
- A closed-lid wake, ping, and return-to-sleep test passed on a plugged-in MacBook on July 18, 2026.

## Shortcuts

- **Command-U:** toggle the menu bar popover globally when enabled.
- **Command-,**: save and close Settings, then restore the popover.

## Security and storage

- Keychain service: `com.proxsyi.claudesessionpinger`.
- Keychain accounts: `sessionKey` and `cookieHeader`.
- Credentials are never written to plain-text files or logs.
- Settings use `UserDefaults`.
- Activity history: `~/Library/Application Support/ClaudeSessionPinger/history.json`.
- Wake diagnostics: `~/Library/Application Support/ClaudeSessionPinger/wake-events.log`.

## Important limitation

Claude.ai does not provide a supported consumer-chat API for this workflow. Session Pinger uses undocumented consumer-web endpoints with your own browser session. Endpoint, authentication, model, or usage-payload changes can require an app update.

## Building from source

Requires macOS 13 or newer and Xcode command-line tools.

```bash
git clone https://github.com/proxsyi/ClaudeSessionPinger.git
cd ClaudeSessionPinger
./Scripts/build_app.sh
```

The signed and strictly verified app is written to `dist/Session Pinger.app`. Run the assembled app bundle rather than the raw Swift package executable.

## Uninstall

Quit the app and delete it from `/Applications`. To remove current local data and Keychain records:

```bash
rm -rf "$HOME/Library/Application Support/ClaudeSessionPinger"
security delete-generic-password -s com.proxsyi.claudesessionpinger -a sessionKey
security delete-generic-password -s com.proxsyi.claudesessionpinger -a cookieHeader
```

If scheduled wake support was installed, remove the privileged files with administrator authorization:

```bash
sudo rm -f /Library/PrivilegedHelperTools/com.proxsyi.claudesessionpinger.wake-helper
sudo rm -f "/Library/Application Support/SessionPinger/allowed_uid"
sudo rmdir "/Library/Application Support/SessionPinger" 2>/dev/null || true
```

Legacy installations may also have Keychain records under `com.cash.claudesessionpinger`. Remove those only after confirming the current credentials work.
