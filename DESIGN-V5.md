# TokenTracker v5 — Claude Card Hero Label Fix

**Status: EXECUTABLE SPEC. Read CONTEXT.md first. One-line change.**

## 0. What changes

The Claude card hero label currently says "CURRENT SESSION". Change it to
"CURRENT WEEK".

| Before | After |
|---|---|
| CURRENT SESSION / 当前会话 | CURRENT WEEK / 本周用量 |

That's it. Data sources, tier rows, Codex card — all unchanged.

## 1. What to change

One file: `desktop/ui/app.js`.

In the `copy` object (line 12), change the `currentSession` value:

```js
// Before:
currentSession: "Current session",

// After:
currentSession: "Current week",
```

In `copy["zh-Hans"]` (line 21):

```js
// Before:
currentSession: "当前会话",

// After:
currentSession: "本周用量",
```

The key name `currentSession` stays the same — only the display value changes.

The `currentSession` key is referenced in two places:
- `providerCard()` hero label (line ~100): `t(heroLabelKey)` where `heroLabelKey` resolves to `"currentSession"` for Claude
- (formerly in tier rendering — no longer used there after v4)

**No other code changes.** No new i18n keys. No data source changes. No CSS.

## 2. Verification

1. Build the app.
2. Claude card hero label reads "CURRENT WEEK" (English) / "本周用量" (Chinese).
3. Data, tier rows, progress bar, Codex card — all unchanged.

## 3. Standing constraints

- Single file change (`app.js`), two lines changed.
- No Rust, no CSS, no HTML.
- Commit only `app.js`.
- Never `git reset`, `git clean`, `git checkout --`.
