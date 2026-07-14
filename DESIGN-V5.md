# TokenTracker v5 — Claude Card Display Order + Tray Data Source

**Status: IMPLEMENTED. This doc records the final design for future agents.**

## 0. What changed

| Area | Before | After |
|---|---|---|
| Claude hero data | `snapshot.weekly` (seven_day, all models) | `provider.session` (five_hour, current session) |
| Claude hero label | "REMAINING" / "剩余" | "CURRENT SESSION" / "当前会话" |
| Claude tier 1 | `provider.session` with "Current session" | `provider.snapshot.weekly` with "Current week" |
| Tray percentage | `snapshot.weekly.remaining_percent` | `snapshot.session` first, fallback to `snapshot.weekly` |

## 1. Claude card layout (final state)

```
┌─ Claude panel ─────────────────────────┐
│ [CC] CLAUDE CODE                   02 ↗ │
│                                         │
│ 93%              RESETS 2:19 PM        │  ← HERO (session data)
│ CURRENT SESSION  LOCAL TOKENS 12,450   │     label: "CURRENT SESSION"
│ [████████████████████████]             │
│                                         │
│ Current week                 86%        │  ← TIER 1 (weekly all models)
│ Resets  Jul 17      12,450             │     label: "Current week"
│ ───                                     │
│ Fable                         76%        │  ← TIER 2+ (per-model)
│ Resets  Jul 17      12,450             │
└─────────────────────────────────────────┘
```

## 2. Changed files

### `desktop/ui/app.js`
- `providerCard()`: `heroWindow` = session for Claude, weekly for Codex (line 63)
- `providerCard()`: hero label key = `"currentSession"` for Claude (line 96)
- `providerCard()`: tier 1 = `provider.snapshot.weekly` with `t("currentWeekLabel")` (line 76)
- i18n keys: `currentSession: "CURRENT SESSION"`, `currentWeekLabel: "Current week"`

### `desktop/src-tauri/src/desktop.rs`
- `update_tray()`: tray percentage = `snapshot.session` first, fallback to `snapshot.weekly` (line 343)

## 3. Not changed
- Codex card (hero = weekly, label = "REMAINING", no tiers)
- Per-model tiers (Fable etc.) rendered from `provider.models`
- Rust parsing (`parse_claude_usage` already populates `session` from five_hour)
