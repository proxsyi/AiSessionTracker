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

The provider settings use `TrackerSettingsWindow`, `TrackerSettingsSection`, and the same account, ping, activity, usage-alert, service-alert, and wake controls from `TrackerDesignSystem`. Provider views supply bindings and callbacks; they do not duplicate those layouts. The shared schedule editor and session-display controls also remain the only implementations for both providers.

Wake scheduling uses one `TrackerWakeSchedule` transaction with distinct Claude and Codex owners. Refreshing schedules preserves pending test wakes. Codex claims a scheduled wake even when its timer fires before the wake notification, and the app waits for every active provider ping before returning to sleep. Explicit wake tests bypass the ordinary five-hour automatic-ping cooldown.

## Intentional provider differences

- Claude and Codex retain their own reported usage windows and allowances. Codex-only credit, workspace, and code-review counters are not fabricated for Claude.
- Codex sends to **Work**; ChatGPT sends to a separate regular chat. Their model catalogs are filtered accordingly.
- Effort controls use the provider's own options. Claude's current lightweight ping transport does not expose the same effort selector as Work; it must not show a nonfunctional duplicate.
- Work's existing Light compatibility option is retained and checked against response metadata during live verification. Other effort labels come from the account catalog, not API terminology.
- Regular ChatGPT currently supports manual pings, not Claude/Codex-style automatic session scheduling or a fabricated five-hour countdown.

## Regression checks

`ProviderFeatureParityTests`, `ModelPresentationTests`, `SessionTimingTests`, and `SharedDesignContractTests` cover common controls, labels, schedule independence, and provider distinctions. Signed-app diagnostics verify the live catalog, chosen model/effort, and saved-chat reuse without logging credentials. Visual inspection and physical sleep/wake testing remain separate checks.

`SettingsPersistenceTests` round-trip provider preferences in isolated defaults domains without reading or changing Keychain credentials. `WakePolicyTests` compare identical provider wake times, isolated commands, preservation of pending tests, partial-failure cleanup, and protection against sleeping during another ping. Saving Codex's counter preferences changes only Codex's counters, not ChatGPT's.

### Feature-branch verification — August 30, 2026

- 120 automated tests passed with Thread Sanitizer; the release build passed with warnings treated as errors.
- Two live pings per OpenAI mode reused the previously saved chats. Codex confirmed **5.6 Luna · Light**; regular ChatGPT confirmed **5.3 Mini**. The latter is non-reasoning in this account's catalog and omits effort metadata.
- The signed local update retains bundle ID `com.proxsyi.sessiontracker` and Developer ID team `7JX38C53N8`. This is not a public, notarized release train.
- Computer Use was unavailable for this verification. No new claim of visual, click-by-click, or physical closed-lid wake verification is made.

### Feature-branch verification — August 31, 2026

- 130 automated tests passed with Thread Sanitizer; the release build passed with warnings treated as errors. Settings persistence is tested without real credentials or real schedule changes.
- Claude's live ping succeeded in its existing chat. Both providers' wake events are registered under their separate helper owners. Wake scheduling, pending tests, and cross-provider sleep protection were verified in code/tests; the Mac was not physically put to sleep.
- **Codex live verification remains blocked.** Both 5.6 Luna Light and 5.5 Light reached the saved Work chat but returned a browser network error or timed out without a fresh saved reply. Neither successful pinging nor full completion is claimed. The saved default and both active chat IDs were preserved.
- Fixed a false-success bug: a browser error card can no longer count as a completed ping. Confirmation now requires a fresh, finished cloud reply and supports the current flat-message response as well as the legacy mapping format. Three unconfirmed diagnostic successes were corrected in local history, including their false last-success timestamp.
- All eight previously identified development chats returned HTTP 404 in fresh checks. The active Codex Work chat and separate ChatGPT chat returned HTTP 200. No additional chats were deleted in this pass.
- The shared controls are verified by source-contract and state tests, not manual pixel comparison. Computer Use remains unavailable. This local signed feature build is not a public notarized release.

### Feature-branch verification — September 1, 2026

- Claude and Codex General, Usage, Alerts, and App pages were opened from the installed signed app and visually compared. They use the same rails, cards, rows, spacing, footer, and provider-specific accent treatment; only real provider data and controls differ.
- The selected settings page is now shared across Claude, Codex, and ChatGPT. Switching providers retains General, Usage, Alerts, or App instead of resetting to General; each mounted provider view continues to retain its own scroll position.
- Both provider App pages show the same wake controls and local weekly-history action. The installed helper remains root-owned/setuid, and matching Claude/Codex wake events are registered under separate owners.
- The installed app completed two fresh Codex pings in the same existing Work chat with **5.6 Luna · Light**. Both replies were confirmed from finished cloud records, the Work conversation ID stayed unchanged, and the separate ChatGPT conversation ID also stayed unchanged.
- Computer Use was not exposed in this run, so the visual check used the installed app's accessibility-visible Settings window and screenshots. Physical closed-lid wake remains unclaimed.
