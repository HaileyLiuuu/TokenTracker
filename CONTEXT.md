# AIUsageBar context

## Goal

A cross-platform macOS menu-bar and Windows system-tray app that keeps Codex and Claude Code plan usage visible without opening their deeper usage screens.

## Domain vocabulary

- **Primary provider**: Codex or Claude Code, chosen by the user, whose remaining percentage appears in the menu bar.
- **Usage window**: a provider-reported quota window with a used percentage and reset time.
- **Remaining percentage**: `100 - used percentage`, clamped to 0...100.
- **Local tokens**: tokens found in local JSONL logs during the provider's current weekly window. This is not presented as an account-wide provider total.
- **Usage snapshot**: normalized provider data consumed by the UI.

## Confirmed test seams

1. The Codex Usage-screen payload and Claude payload normalize into the same `UsageSnapshot` public type.
2. Primary-provider and language settings persist and drive user-visible labels.
3. Local Codex and Claude logs produce a bounded local-token total without decoding, retaining, or transmitting prompt fields.
4. A Claude usage client reads Keychain credentials at most once per app session unless the user explicitly retries after an authentication failure.
5. Claude usage requests are coalesced and throttled to at most once every five minutes. Rate-limit backoff and the last successful snapshot are persisted without credentials so an app restart does not blank the UI or retry early. Snapshots expire at the provider reset time, or after 24 hours when no reset time is available.
6. macOS and Windows reuse the user's existing provider sign-in state without requiring credentials to be entered into AIUsageBar.
7. GitHub Releases produce a Universal macOS installer and a Windows x64 installer from the same Tauri/Rust core.

The tray hover/click interaction, outside-click dismissal, and rendered layout are verified in packaged apps because they cross native window-system boundaries.
