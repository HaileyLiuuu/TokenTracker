# TokenTracker context

## Goal

A cross-platform macOS menu-bar and Windows system-tray app that keeps Codex
and Claude Code plan usage visible without opening their deeper usage screens.

## Domain vocabulary

- **Primary provider**: Codex or Claude Code, chosen by the user, whose
  remaining percentage appears in the menu bar.
- **Usage window**: a provider-reported quota window with a used percentage
  and reset time. A snapshot can contain multiple windows:
  - **session** (`five_hour`): 5-hour rolling window. Used for the tray
    percentage and Claude card hero.
  - **weekly** (`seven_day`): 7-day all-models total. Used for the Claude
    card tier "Current week" and Codex card.
- **Remaining percentage**: `100 - used percentage`, clamped to 0…100.
- **Local tokens**: tokens found in local JSONL logs during the provider's
  current weekly window. Not presented as an account-wide provider total.
- **Usage snapshot**: normalized provider data consumed by the UI.

## Confirmed test seams

1. The Codex Usage-screen payload and Claude payload normalize into the same
   `UsageSnapshot` public type.
2. Primary-provider and language settings persist and drive user-visible labels.
3. Local Codex and Claude logs produce a bounded local-token total without
   decoding, retaining, or transmitting prompt fields.
4. A Claude usage client reads Keychain credentials at most once per app
   session unless the user explicitly retries after an authentication failure.
5. Claude usage requests are coalesced and throttled to at most once every
   five minutes. Rate-limit backoff and the last successful snapshot are
   persisted without credentials so an app restart does not blank the UI or
   retry early. Snapshots expire at the provider reset time, or after 24 hours
   when no reset time is available.
6. macOS and Windows reuse the user's existing provider sign-in state without
   requiring credentials to be entered into TokenTracker.
7. GitHub Releases produce a Universal macOS installer and a Windows x64
   installer from the same Tauri/Rust core.
8. The tray panel opens only on a tray-icon click. Pointer hover over the
   tray icon never opens, closes, or schedules the closing of the panel; no
   hover handling exists in the tray, the window, or the web UI.
9. Clicking the tray icon while the panel is open closes it, and a click
   anywhere outside the panel closes it. The panel is always focused when
   shown, because outside-click dismissal is implemented as focus loss; a
   panel that is shown without focus cannot be dismissed. (Regressed once
   during the Swift→Tauri port — see commit 334da4e, which added global
   mouse-down monitoring after NSPopover.transient proved unreliable.)
10. The macOS tray shows a text title only ("C 12%" / "CC 87%"); Claude Code's
    label is "CC". Windows renders the drawn tray bitmap because a Windows
    tray has no text title.
11. Claude's usage payload is parsed into every `seven_day*` model window it
    contains, including tiers unknown at build time, without collapsing them
    into a single window. Per-model breakdown also sourced from the `limits`
    array (`weekly_scoped` entries with `scope.model.display_name`).
12. The **menu bar tray percentage** comes from `snapshot.session` (five_hour)
    first, falling back to `snapshot.weekly` (seven_day) when session is null
    (e.g. for Codex, which has no session data).
13. The **Claude card display order** (top to bottom):
    - **Hero** (largest number + progress bar): session data from five_hour.
      Label = "CURRENT SESSION" / "当前会话".
    - **Tier 1**: weekly all-models data from seven_day.
      Label = "Current week" / "本周用量".
    - **Tier 2+**: per-model tiers from `limits[]` (Fable, Opus, etc.).
    - Each tier shows remaining %, reset time, local 7-day tokens, and
      a thin progress bar.
14. **Footer buttons** (REFRESH NOW / QUIT APP) are localized via `data-i18n`
    attributes on their `<span>` elements — not hardcoded text. The i18n keys
    are `refreshLabel` and `quitLabel`. (Regressed once during the V3
    editorial redesign — the new HTML dropped `data-i18n` from the footer.)

The tray click interaction, outside-click dismissal, and rendered layout are
verified in packaged apps because they cross native window-system boundaries.
