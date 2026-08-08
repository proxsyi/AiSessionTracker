# Session Tracker

Three independent macOS menu-bar apps live in this repository:

- **Claude Session Pinger** tracks Claude session and weekly limits, and can ping on a schedule.
- **GPT Usage Tracker** shows the ChatGPT and Codex limits your account reports.
- **Session Tracker** combines Claude, Codex, and ChatGPT into three switchable dashboards.

The combined app keeps credentials, settings, and alerts separated by service. Its menu-bar star and ring can follow the Claude and GPT counters you choose. The two optional percentages use Claude orange and GPT green, separated by `/` without letter labels. You can independently hide the icon, either percentage, any dashboard, counter, chart, or notification from Settings.

Command-U opens the Claude dashboard. Command-I opens the GPT side (Codex or ChatGPT). One press toggles the popover, and clicking elsewhere closes it like a normal menu-bar item.

All usage values and reset times come from the signed-in service. If ChatGPT does not report a message or feature limit for the account, the app labels it unavailable instead of estimating it.

## Local build

Requires macOS 13+ and Xcode command-line tools.

```bash
swift test
./Scripts/build_app.sh
```

The local development build is written to `dist/Session Tracker.app`.

## Public release

Public builds require a **Developer ID Application** certificate and a stored
`notarytool` keychain profile. Apple Development certificates are for local
testing and do not provide a notarized public download. Each app has its own
stable bundle ID, release tag prefix, and update zip; release all three
together as described in [AGENTS.md](AGENTS.md).
