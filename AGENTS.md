# AI Session Tracker contributor rules

Follow the project Coding Rules in Notion before editing or releasing. Keep
`main` deployable, work on a focused `feat/` or `fix/` branch, inspect the
working tree and file history before changes, and make atomic conventional
commits. Stage explicit paths only. Do not push unless the owner explicitly
asks for a push.

The GitHub repository is `proxsyi/AiSessionTracker`. Its deployable branches are:

- `main` — mixed AI Session Tracker
- `claude-session-pinger` — standalone Claude Session Pinger
- `gpt-session-pinger` — standalone GPT Usage Tracker

This repository ships three independent macOS apps:

- Claude Session Pinger — `com.proxsyi.claudesessionpinger`, `v*`, `ClaudeSessionPinger.app.zip`
- GPT Usage Tracker — `com.proxsyi.gptsessionpinger`, `gpt-v*`, `GPTSessionPinger.app.zip`
- Session Tracker — `com.proxsyi.sessiontracker`, `tracker-v*`, `SessionTracker.app.zip`

Every release train must build, test, sign, notarize, and publish all three
artifacts together. Never substitute one app's zip or update feed for another.
Use Developer ID Application signing with hardened runtime and a notarization
profile for public releases; Apple Development signing is local testing only.
Before shipping, verify each updater only accepts its own asset and bundle ID,
and verify the Claude wake helper is isolated from the combined app before
enabling wake support in both.

Branch READMEs describe only the app built from that branch. GPT Usage Tracker
must never include session-pinging, scheduling, wake support, a privileged
helper, or Claude credentials. The mixed and Claude branches may include their
own isolated Claude wake helpers.
