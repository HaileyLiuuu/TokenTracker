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

Only one file: `desktop/ui/app.js`. The `providerCard()` function and the
`copy` i18n objects.

### 2.1 Claude hero: source from `provider.session` + label change

For Claude cards only, the hero percentage, progress bar, and meta data
(reset time, local tokens) must come from `provider.session` (five_hour).

When `provider.session` is null (first launch before fetch, or old cached
data), fall back to `provider.snapshot.weekly`. This is the same graceful
degradation pattern already used elsewhere in the app.

For Codex cards: unchanged. Codex has no session data, so hero stays on
`provider.snapshot?.weekly`.

**Hero label change:** The hero grid currently shows `t("remaining")` ("REMAINING")
as the hero label below the percentage. For Claude cards, change this to
`t("currentSession")` ("CURRENT SESSION"). For Codex, keep `t("remaining")`.

### 2.2 Tier sections: use new label `weeklyAllLabel`

Current tier order (lines 73-79):
```
renderTier(t("currentSession"), provider.session, ...)
// then per-model tiers
```

New tier order:
```
renderTier(t("weeklyAllLabel"), provider.snapshot.weekly, ...)
// then per-model tiers (unchanged)
```

The first tier row shows "Current week (all models)" — matching Claude Code's
own `/usage` output which labels this tier as "Current week (all models)".

**New i18n keys required:**

```js
// copy.en — add:
weeklyAllLabel: "Current week (all models)",

// copy["zh-Hans"] — add:
weeklyAllLabel: "本周用量（所有模型）",
```

The existing `allModels` key stays (keeps code tidy) but is no longer used by
`providerCard()`.

### 2.3 Full label mapping for Claude card

| Visual element | Data source | i18n key | English | 中文 |
|---|---|---|---|---|
| Hero % label | `provider.session` | `currentSession` | CURRENT SESSION | 当前会话 |
| Tier 1 heading | `provider.snapshot.weekly` | `weeklyAllLabel` | Current week (all models) | 本周用量（所有模型） |
| Tier 2+ heading | `provider.models[i]` | `m.displayName` | Fable etc. | Fable etc. |

### 2.4 Pseudocode for the Claude branch

```js
function providerCard(provider, index) {
  const isCodex = provider.id === "codex";
  // ... badge, name, note unchanged ...

  // Claude: hero = session. Codex: hero = weekly (unchanged).
  const heroWindow = (!isCodex && provider.session) || provider.snapshot?.weekly;
  const heroRemaining = heroWindow?.remainingPercent;
  const heroPct = heroRemaining != null ? Math.round(heroRemaining) + "%" : "—";
  // Claude hero label = "CURRENT SESSION", Codex = "REMAINING"
  const heroLabelKey = !isCodex ? "currentSession" : "remaining";

  // Tier sections (Claude only)
  let tierHtml = "";
  if (!isCodex && provider.snapshot) {
    tierHtml += renderTier(t("weeklyAllLabel"), provider.snapshot.weekly, provider.localTokens);
    if (provider.models) {
      provider.models.filter(m => m.modelKey !== "").forEach(m => {
        tierHtml += renderTier(m.displayName, m.weekly, provider.localTokens);
      });
    }
  }

  // HTML: hero grid uses heroWindow.remainingPercent and heroWindow.resetAt
  // hero-label div uses t(heroLabelKey) instead of hardcoded t("remaining")
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
2. **Hero label** = "CURRENT SESSION" / "当前会话" (not "REMAINING").
3. **Hero number** = session remaining % (from five_hour, e.g. 93%).
4. **First tier row** = "Current week (all models)" / "本周用量（所有模型）" (weekly total, e.g. 86%).
5. **Subsequent tier rows** = per-model (Fable, etc.).
6. Codex card is completely unchanged (hero label still "REMAINING").
7. If `provider.session` is null, card falls back to weekly data — never blanks.

## 5. Standing constraints

- Single file change (`app.js`). No Rust, no CSS, no HTML.
- New i18n keys `weeklyAllLabel` added to both `en` and `zh-Hans` copy objects.
- Commit only `app.js`.
- Never `git reset`, `git clean`, `git checkout --`.
- Never make model API calls to test quota display.
- Do not push without explicit direction.
