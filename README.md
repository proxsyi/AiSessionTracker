# GPT Session Pinger

A personal macOS menu bar app that sends short messages to ChatGPT on an intentional schedule, so your ChatGPT usage sessions start when you choose.

## What it does

- Starts ChatGPT sessions on a configurable daily schedule. Defaults: 5:00 AM, 10:00 AM, 3:00 PM, and 8:00 PM.
- Enforces five-hour spacing between every scheduled start, including overnight.
- Uses one dedicated ChatGPT conversation for scheduled, manual, and connection-test pings.
- Captures your ChatGPT web-session cookies through a built-in browser login and keeps them only in the macOS Keychain.
- Shows session and weekly limits when ChatGPT reports equivalent account data, plus OpenAI service health.
- Provides persistent activity history, notifications, global Command-U, and automatic update checks.
- Can wake a plugged-in, closed-lid MacBook for a scheduled ping and return it to sleep when there was no physical input.
- Runs only in the menu bar; there is no Dock icon.

## Get it running

1. Build `GPT Session Pinger.app` from this branch.
2. Move it to **Applications** and open it.
3. Open **Settings > General > Log in with ChatGPT**. Complete the login in the built-in browser; the app captures the authenticated cookie header automatically.
4. Optionally install scheduled wake support under **Settings > App**. This is a one-time administrator-authorized installation.

## Security and limitations

- Keychain service: `com.proxsyi.gptsessionpinger`.
- The app never writes credentials to logs or plain-text files.
- This is a personal consumer-web integration, not the OpenAI API. ChatGPT’s web endpoints and account fields are undocumented and can change without notice.
- ChatGPT does not consistently expose a universal usage meter. The app only displays session/weekly values when the signed-in account returns explicit limit data; it does not infer usage from messages.
- Closed-lid wake requires a plugged-in MacBook.

## Build

Requires macOS 13+ and Xcode command-line tools.

```bash
swift build -c release
./Scripts/build_app.sh
```

The assembled, strictly verified app is written to `dist/GPT Session Pinger.app`.
