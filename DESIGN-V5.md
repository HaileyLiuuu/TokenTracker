# TokenTracker v5 — Claude Card Reorder

**Status: EXECUTABLE SPEC. Read CONTEXT.md first. Single-file change.**

## 0. What changes

The Claude Code card display order changes:

| Before | After |
|---|---|
| **Hero**: Current week (all models) | **Hero**: Current session |
| Tier: Current session | Tier: Current week (all models) |
| Tier: Fable | Tier: Fable |

The user wants the hierarchy to match Claude Code's own `/usage` output —
Current session first and largest, then weekly, then per-model.

**Codex card is unchanged** — Codex has no session/per-model breakdown.

## 1. Root cause

`providerCard()` in `desktop/ui/app.js` (line 62) hardcodes the hero to
`provider.snapshot?.weekly?.remainingPercent` (seven_day, all models).

`provider.session` (five_hour) already exists on the view model, populated by
the Rust backend. It's currently rendered as a tier section. It needs to
BECOME the hero.

## 2. What to change

Only one file: `desktop/ui/app.js`. The `providerCard()` function.

### 2.1 Claude hero: source from `provider.session`

For Claude cards only, the hero percentage, progress bar, and meta data
(reset time, local tokens) must come from `provider.session` (five_hour).

When `provider.session` is null (first launch before fetch, or old cached
data), fall back to `provider.snapshot.weekly`. This is the same graceful
degradation pattern already used elsewhere in the app.

For Codex cards: unchanged. Codex has no session data, so hero stays on
`provider.snapshot?.weekly`.

### 2.2 Tier sections: swap session and all-models

Current tier order (lines 73-79):
```
renderTier(t("currentSession"), provider.session, ...)
// then per-model tiers from provider.models
```

New tier order:
```
renderTier(t("allModels"), provider.snapshot.weekly, ...)
// then per-model tiers from provider.models (unchanged)
```

`t("allModels")` = "All models" / "所有模型" — existing i18n key.
`t("currentSession")` stays in the copy object but is no longer used in
`providerCard()` (the hero IS the session now).

### 2.3 Pseudocode for the Claude branch

```js
function providerCard(provider, index) {
  const isCodex = provider.id === "codex";
  // ... badge, name, note unchanged ...

  // Claude: hero = session. Codex: hero = weekly (unchanged).
  const heroWindow = (!isCodex && provider.session) || provider.snapshot?.weekly;
  const heroRemaining = heroWindow?.remainingPercent;
  const heroPct = heroRemaining != null ? Math.round(heroRemaining) + "%" : "—";

  // Tier sections (Claude only): allModels first, then per-model
  let tierHtml = "";
  if (!isCodex && provider.snapshot) {
    tierHtml += renderTier(t("allModels"), provider.snapshot.weekly, provider.localTokens);
    if (provider.models) {
      provider.models.filter(m => m.modelKey !== "").forEach(m => {
        tierHtml += renderTier(m.displayName, m.weekly, provider.localTokens);
      });
    }
  }

  // HTML: hero grid uses heroWindow.remainingPercent and heroWindow.resetAt
  // Progress bar uses heroRemaining
}
```

## 3. Rust backend — ZERO changes

`parse_claude_usage` already populates `snapshot.session` (five_hour).
`load_claude` already wires it into `ProviderView.session`.
`initial_view` already copies it from cache.
The data path is complete and correct.

## 4. Verification

After building:

1. Click tray icon → Claude card shows.
2. **Hero number** = session remaining % (from five_hour, e.g. 93%).
   Progress bar and meta (reset time, local tokens) match the session window.
3. **First tier row** = "All models" (weekly total, e.g. 86%).
4. **Subsequent tier rows** = per-model (Fable, etc.).
5. Codex card is completely unchanged.
6. If `provider.session` is null, card falls back to weekly data — never blanks.

## 5. Standing constraints

- Single file change (`app.js`). No Rust, no CSS, no HTML.
- Commit only `app.js`.
- Never `git reset`, `git clean`, `git checkout --`.
- Never make model API calls to test quota display.
- Do not push without explicit direction.
