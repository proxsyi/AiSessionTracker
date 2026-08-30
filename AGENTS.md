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
Run `NOTARY_PROFILE="..." ./Scripts/release_train.sh` from clean `main`; the
script verifies every app before it publishes any tag or asset. The legacy
`Scripts/release.sh` delegates to this train. `ALLOW_SINGLE_APP_RELEASE=1` is
reserved for repairing an already-published release, not normal releases.
Before shipping, verify each updater only accepts its own asset, repository,
bundle ID, Team ID, signature, and notarization ticket. Extract every finished
ZIP and strictly verify the app inside it before publishing. Build release
artifacts outside file-provider folders so Finder metadata cannot invalidate a
signature after packaging.

The mixed app owns one shared wake helper. Claude and Codex scheduling must use
separate provider identifiers in that helper, and changing one provider's
schedule must never cancel the other's events. The standalone Claude helper is
separate from the mixed helper.

Branch READMEs describe only the app built from that branch. GPT Usage Tracker
must never include session-pinging, scheduling, wake support, a privileged
helper, or Claude credentials. The mixed app may ping Claude, Codex, and
ChatGPT; Codex must use its dedicated ChatGPT Work task, while ChatGPT must use
a different dedicated cloud chat. The mixed and Claude branches may include
their appropriate isolated wake helpers.
