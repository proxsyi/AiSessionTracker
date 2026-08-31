# Claude and Codex feature parity

This describes the mixed app's implemented controls, not a claim that every operating-system interaction has been manually tested.

| Feature | Claude | Codex |
| --- | --- | --- |
| Browser login, re-login, logout | Yes | Yes |
| Provider model picker, refresh, low-usage choice | Yes | Yes |
| Custom ping message and test connection | Yes | Yes |
| Dedicated saved chat, open chat, start fresh | Yes | Yes |
| Schedule enabled independently of usage tracking | Yes | Yes |
| Hour/minute editor, add/remove time, spacing validation | Shared editor | Shared editor |
| Scheduled and next-possible countdowns, main focus | Shared controls | Shared controls |
| Start when available | Yes | Yes |
| Success rate, last result, last successful model | Yes | Yes |
| Individual usage-bar visibility | Yes | Yes |
| Usage thresholds: 25, 50, 75, 90, 95, 100 percent | Yes | Yes |
| Failure, available-session, sent, scheduled-sent alerts | Shared controls | Shared controls |
| Outage/degraded alerts and test notification | Yes | Yes |
| Weekly trend toggle and clear local history | Shared chart | Shared chart |
| Per-provider wake opt-in and closed-lid test | Yes | Yes |
| Shortcut and glass preference | Yes | Yes |
| Save/Cancel and retained settings navigation | Yes | Yes |

Wake-helper installation, launch at login, and combined-app updates belong to **System**. Provider schedules, histories, and chat identifiers stay separate.

## Intentional provider differences

- Claude and Codex retain their own reported usage windows and allowances. Codex-only credit, workspace, and code-review counters are not fabricated for Claude.
- Codex sends to **Work**; ChatGPT sends to a separate regular chat. Their model catalogs are filtered accordingly.
- Effort controls use the provider's own options. Claude's current lightweight ping transport does not expose the same effort selector as Work; it must not show a nonfunctional duplicate.
- Work's existing Light compatibility option is retained and checked against response metadata during live verification. Other effort labels come from the account catalog, not API terminology.
- Regular ChatGPT currently supports manual pings, not Claude/Codex-style automatic session scheduling or a fabricated five-hour countdown.

## Regression checks

`ProviderFeatureParityTests`, `ModelPresentationTests`, `SessionTimingTests`, and `SharedDesignContractTests` cover common controls, labels, schedule independence, and provider distinctions. Signed-app diagnostics verify the live catalog, chosen model/effort, and saved-chat reuse without logging credentials. Visual inspection and physical sleep/wake testing remain separate checks.

### Feature-branch verification — August 30, 2026

- 120 automated tests passed with Thread Sanitizer; the release build passed with warnings treated as errors.
- Two live pings per OpenAI mode reused the previously saved chats. Codex confirmed **5.6 Luna · Light**; regular ChatGPT confirmed **5.3 Mini**. The latter is non-reasoning in this account's catalog and omits effort metadata.
- The signed local update retains bundle ID `com.proxsyi.sessiontracker` and Developer ID team `7JX38C53N8`. This is not a public, notarized release train.
- Computer Use was unavailable for this verification. No new claim of visual, click-by-click, or physical closed-lid wake verification is made.
