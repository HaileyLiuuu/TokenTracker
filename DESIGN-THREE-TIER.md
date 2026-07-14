# Claude Code card: three-tier usage display

**Status: DESIGN ONLY. Execute from this document. Read `CONTEXT.md` first.**

## 0. What the user wants

The Claude Code panel card shows three sections, each with **remaining %**,
**reset time**, and **local 7-day tokens**:

```
┌─────────────────────────────────────────┐
│ CC  Claude Code                      86% │  ← header (total remaining)
│ ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░    │  ← total progress bar
│                                         │
│ Current session              93%        │  ← from five_hour
│ Resets  2:19 PM                        │
│ Local 7-day tokens  12,450             │
│ ████░░░░░░░░░░░░░░░░░░░░░░░░           │
│                                         │
│ Current week (all models)    86%        │  ← from seven_day (existing)
│ Resets  Jul 17, 2026                   │
│ Local 7-day tokens  12,450             │
│ ████████░░░░░░░░░░░░░░░░░░░░░░         │
│                                         │
│ Current week (Fable)         76%        │  ← from limits[weekly_scoped]
│ Resets  Jul 17, 2026                   │
│ Local 7-day tokens  12,450             │
│ ██████████░░░░░░░░░░░░░░░░░░           │
│                                         │
│ ◈ Provider data  Updated 10:15 AM      │  ← unchanged footer
└─────────────────────────────────────────┘
```

## 1. Data sources (all in the response we already fetch)

The Claude OAuth usage endpoint `api.anthropic.com/api/oauth/usage` returns:

```json
{
  "five_hour": {
    "utilization": 7.0,
    "resets_at": "2026-07-14T05:20:00+00:00"
  },
  "seven_day": {
    "utilization": 14.0,
    "resets_at": "2026-07-17T12:00:00+00:00"
  },
  "limits": [
    { "kind": "session",       "percent": 7,  "resets_at": "...", "scope": null, "is_active": false },
    { "kind": "weekly_all",    "percent": 14, "resets_at": "...", "scope": null, "is_active": false },
    { "kind": "weekly_scoped", "percent": 24, "resets_at": "...", "scope": { "model": { "display_name": "Fable" } }, "is_active": true }
  ]
}
```

| Tier | Data source | Already parsed? | Duration |
|---|---|---|---|
| Current session | `five_hour` key | **No** — not read | 300 minutes (5 hours, inferred) |
| Current week (all models) | `seven_day` key | Yes — `snapshot.weekly` | 10,080 minutes (7 days) |
| Per-model tiers | `limits[]` → `weekly_scoped` | Yes — `snapshot.models[1..]` | 10,080 minutes |

All three carry `utilization` (used percent, 0..100), `resets_at` (RFC 3339).
Remaining = 100 - utilization, clamped.

Local 7-day tokens: the single `scan_claude_tokens()` total. Showing the same
number in all three sections is acceptable for now.

## 2. Structural change, layer by layer

### 2.1 Core type (lib.rs — `UsageSnapshot`)

Add one field. **Do not repurpose `models` for session data** — a session window
is not a model tier. session data will be stored as an optional `UsageWindow` on the snapshot.

```rust
pub struct UsageSnapshot {
    pub provider: ProviderId,
    pub weekly: UsageWindow,           // unchanged — seven_day all-models
    pub fetched_at: DateTime<Utc>,
    #[serde(default)]
    pub models: Vec<ModelUsage>,       // unchanged — all-models total + per-tier
    #[serde(default)]
    pub session: Option<UsageWindow>,  // NEW — from five_hour, None for Codex
}
```

`UsageWindow::new()` takes `(used_percent, reset_at, duration_minutes)`.
When constructing from `five_hour`, pass `Some(300)` as `duration_minutes`.

### 2.2 Parser (lib.rs — `parse_claude_usage`)

After the existing `seven_day*` loop and the `limits[]` loop, add a
`five_hour` extraction:

```rust
// Parse the session-level window
if let Some(session) = raw.get("five_hour").and_then(|v| v.as_object()) {
    if let (Some(&util), Some(&resets)) = (
        session.get("utilization").and_then(|v| v.as_f64()),
        session.get("resets_at").and_then(|v| v.as_str()),
    ) {
        let session_reset = Some(
            DateTime::parse_from_rfc3339(resets)
                .map(|d| d.with_timezone(&Utc))
                .map_err(|_| UsageError::InvalidResetTimestamp)?
        );
        session_used_percent = Some(util);
        session_reset_time = session_reset;
    }
}
```

The rest of the function is: `Ok(UsageSnapshot { ..., session: ... })`.
If the `five_hour` key is absent or malformed, `session` is `None` — the card
survives with the other two sections intact.

### 2.3 Construction sites (lib.rs + cache_contract.rs)

Every place that constructs `UsageSnapshot` needs `session: None` added
(Codex parser line ~271, cache_contract test line ~7). The Claude parser
populates it from `five_hour`.

### 2.4 View model (desktop.rs — `ProviderView`)

Add one field:

```rust
pub struct ProviderView {
    pub id: ProviderId,
    pub display_name: String,
    pub snapshot: Option<UsageSnapshot>,
    pub local_tokens: Option<u64>,
    pub failure: Option<String>,
    pub loading: bool,
    pub models: Vec<ModelUsage>,           // unchanged
    pub session: Option<UsageWindow>,      // NEW — from snapshot.session
}
```

This serializes to JS as `provider.session?.remainingPercent`,
`provider.session?.resetAt`.

### 2.5 Construction sites (desktop.rs + service.rs)

Every `ProviderView { ... }` needs `session: None` (AppViewState::default,
initial_view, load_codex). For `load_claude` specifically, read it from the
snapshot:

```rust
let session = snapshot
    .as_ref()
    .and_then(|s| s.session.clone());
// then in the struct literal:
ProviderView {
    // ... existing fields ...
    session,
    // ...
}
```

### 2.6 UI (app.js — `providerCard`)

Replace the current ad-hoc model rows with a structured three-section layout.
The function receives `provider` which now has:
- `provider.session` — `{ remainingPercent, usedPercent, resetAt, durationMinutes }` or undefined
- `provider.snapshot.weekly` — the all-models weekly window (unchanged)
- `provider.models` — `[{ displayName, modelKey, weekly: {...} }]` (unchanged)
- `provider.localTokens` — the single token number (unchanged)

**For Codex cards**, render exactly as today — the `session` field is null,
`models` is empty, no three-tier layout.

**For Claude cards only**, build three sections. Each section follows the same
compact metric-row pattern:

```
Section header (bold label)
├── Remaining  X%
├── Resets  <date>
├── Local 7-day tokens  <number>
└── progress bar
```

The JS pseudocode:

```js
function threeTierSection(label, window, localTokens) {
  if (!window) return "";
  const r = window.remainingPercent;
  const pct = r != null ? Math.round(r) + "%" : "—";
  return `<div class="tier-section">
    <div class="tier-heading">${label}</div>
    <div class="metric"><span>${t("remaining")}</span><span>${pct}</span></div>
    <div class="metric"><span>${t("resets")}</span><span>${formatDate(window.resetAt)}</span></div>
    <div class="metric"><span>${t("localTokens")}</span><span>${formatNumber(localTokens)}</span></div>
    <div class="progress tier-progress"><div style="width:${r ?? 0}%;opacity:${r != null ? 1 : 0}"></div></div>
  </div>`;
}
```

In `providerCard`, for a Claude card:
```js
let tierHtml = "";
if (!isCodex && provider.snapshot) {
  tierHtml =
    threeTierSection("Current session", provider.session, provider.localTokens) +
    threeTierSection("Current week (all models)", provider.snapshot.weekly, provider.localTokens);
  // Per-model rows from models (skip modelKey === "" — it's the all-models duplicate)
  if (provider.models) {
    provider.models.filter(m => m.modelKey !== "").forEach(m => {
      tierHtml += threeTierSection(m.displayName, m.weekly, provider.localTokens);
    });
  }
}
```

The **i18n labels**: add `"currentSession": "Current session"` / `"当前会话"`,
`"allModels": "Current week (all models)"` / `"所有模型"` to the `copy` objects.
The per-model headers use `m.displayName` directly (already localised by the API).

### 2.7 CSS (styles.css)

The existing `.metric` and `.progress` rules are reused. Add:

```css
.tier-section {
  padding-top: 10px;
  margin-top: 10px;
  border-top: 1px solid var(--border);
}
.tier-heading {
  font-weight: 600;
  font-size: 12px;
  margin-bottom: 6px;
}
.tier-progress {
  height: 5px;
  margin-top: 6px;
}
.tier-progress > div {
  height: 100%;
  border-radius: inherit;
  transition: width 180ms ease;
  background: var(--muted);
}
```

Remove the now-unused `.model-breakdown`, `.model-row`, `.model-name`,
`.model-pct`, `.model-progress` CSS classes (they are superseded by the
unified `.tier-section`).

### 2.8 i18n labels

In `app.js` `copy.en`: add `currentSession: "Current session"`, `allModels: "All models"`.
In `copy["zh-Hans"]`: add `currentSession: "当前会话"`, `allModels: "所有模型"`.

### 2.9 Contract test (tests/usage_contract.rs)

Add a test verifying `five_hour` parsing:

```rust
#[test]
fn five_hour_session_window_is_parsed_from_claude_payload() {
    let fetched_at = Utc.with_ymd_and_hms(2026, 7, 13, 8, 0, 0).unwrap();
    let snapshot = parse_claude_usage(
        br#"{"seven_day":{"utilization":14,"resets_at":"2026-07-17T12:00:00Z"},"five_hour":{"utilization":7,"resets_at":"2026-07-14T05:20:00Z"},"limits":[{"kind":"weekly_scoped","percent":24,"resets_at":"2026-07-17T12:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":true}]}"#,
        fetched_at,
    )
    .unwrap();

    assert_eq!(snapshot.weekly.remaining_percent, 86.0);
    assert_eq!(snapshot.models.len(), 2);

    let session = snapshot.session.expect("five_hour should populate session");
    assert_eq!(session.remaining_percent, 93.0); // 100-7
    assert_eq!(session.duration_minutes, Some(300));
    assert!(session.reset_at.is_some());
}
```

Also add a test that a payload without `five_hour` produces `session: None`.

## 3. What does NOT change

- Codex card rendering — the `isCodex` guard keeps it identical to today.
- Tray icon, tray title, tray tooltip.
- `PRIVACY.md` — `five_hour` is already in the response; no new endpoint.
- `ProviderCache` persistence — `UsageSnapshot` now has `session: Option<UsageWindow>`.
  `#[serde(default)]` ensures old cache files deserialize with `session: None`.
- `scan_claude_tokens()` stays a single `u64`. Per-tier local token attribution
  is a future feature.

## 4. Execution order

1. Read `CONTEXT.md` and this document. Read `lib.rs`, `desktop.rs`, `service.rs`,
   `app.js`, `styles.css` end to end.
2. Add `session` field to `UsageSnapshot` + `ProviderView`.
3. Fix all `UsageSnapshot { ... }` and `ProviderView { ... }` construction sites
   with `session: None`.
4. Add `five_hour` parsing to `parse_claude_usage`.
5. Wire `session` in `load_claude` and `initial_view`.
6. Write the contract test. Run `cargo test --test usage_contract` — all must pass.
7. Rewrite `providerCard` in `app.js` with the three-tier layout.
8. Add `.tier-section` / `.tier-heading` / `.tier-progress` CSS, remove unused
   model-specific classes.
9. Add i18n labels.
10. Full checks: `cargo test --tests`, `cargo clippy --all-targets -- -D warnings`,
    `cargo fmt --check`.
11. Build: `npm run tauri build -- --target universal-apple-darwin --bundles app`.
12. Manual verification in the packaged app (not `tauri dev`):
    - Claude card shows Current session, Current week (all models), and
      per-model rows.
    - Codex card is unchanged.
    - Remaining %, reset time, and local tokens are correct on all rows.
13. Commit. Do not push.

## 5. Standing constraints (same as always)

- Uncommitted changes are intentional user work: never `git reset`/`clean`/`checkout --`.
- Never log or print OAuth tokens, keychain contents, account identifiers, prompts,
  or responses.
- Never make model API calls to test the quota display.
- Do not delete the Swift implementation under `Sources/`.
- Do not push, create a remote, or publish without explicit user direction.
