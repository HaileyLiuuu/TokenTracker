# AIUsageBar context

## Goal

A native macOS menu-bar app that keeps Codex and Claude Code plan usage visible without opening their deeper usage screens.

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

The menu-bar hover/click interaction, outside-click dismissal, and rendered layout are verified in the packaged app because they cross AppKit window-system boundaries.
