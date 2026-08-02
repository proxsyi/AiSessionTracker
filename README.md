# Session Tracker

Three independent macOS menu-bar apps live in this repository:

- **Claude Session Pinger** tracks Claude session and weekly limits, and can ping on a schedule.
- **GPT Usage Tracker** shows the ChatGPT and Codex limits your account reports.
- **Session Tracker** combines Claude, Codex, and ChatGPT into three switchable dashboards.

The combined app keeps credentials and settings separated by service. Its menu-bar star shows Claude session usage; its ring shows Codex weekly usage. You can hide any dashboard from Settings, which also hides its meter.

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
