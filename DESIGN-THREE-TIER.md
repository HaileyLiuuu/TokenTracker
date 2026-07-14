# Claude Code panel: three-tier display (DESIGN ONLY)

User request: the Claude Code card should show three rows, each with
remaining %, reset time, and local 7-day tokens:

| Row | Data source (API key) | Status |
|---|---|---|
| Current session | `five_hour` — utilization, resets_at | **API returns this; not parsed** |
| Current week (all models) | `seven_day` — utilization, resets_at | Already parsed (primary weekly) |
| Current week (Fable) | `limits[]` → `weekly_scoped` with `scope.model.display_name` | Parsed in commit `125389b` |

Each API window carries `utilization` (used %) and `resets_at` (RFC 3339).
Remaining % = 100 - utilization, clamped 0..100. Duration is not always
explicit — the session window is ~5 hours, the weekly windows are ~168 hours
(7 days).

Local 7-day tokens are the existing `scan_claude_tokens()` total. It's a
single number today. Showing the same token count on all three rows is
acceptable for now; per-tier token attribution is a separate future feature.

## Current state after commit `125389b`

```
parse_claude_usage(data, fetched_at) → UsageSnapshot {
    weekly: UsageWindow,        // from seven_day (all models total)
    models: Vec<ModelUsage>,    // [0] = All models (from seven_day),
                                // [1..] = per-tier from limits weekly_scoped
    // five_hour is NOT captured anywhere
}
```

The `five_hour` key in the API response is **not read** by the parser.
Adding it requires:

## What the next agent needs to do

### Data layer (lib.rs)

1. `UsageSnapshot` gains an `Option<UsageWindow>` for the session window:
   ```rust
   pub session: Option<UsageWindow>,
   ```
   Populate it from the `five_hour` key in `parse_claude_usage`.

2. `UsageWindow` needs a `duration_minutes` set for session windows.
   The `five_hour` key has `resets_at` but no explicit duration field —
   infer 300 minutes (5 hours) when parsing a session window, or store
   `None` and compute `starts_at()` from a hardcoded fallback.

3. `ModelUsage` entries already work for per-tier weekly rows. Add a
   `session` counterpart to `ProviderView` so the JS can access it.

### View model (desktop.rs)

4. `ProviderView` gains `session: Option<UsageWindow>` — a single session-level
   window, distinct from the per-model `models` vec.

### Service (service.rs)

5. Wire `session` from the snapshot into `ProviderView` in `load_claude`
   and `initial_view`.

### UI (app.js + styles.css)

6. The Claude card renders three sections:
   - **Current session**: session.remainingPercent, session.resetAt, localTokens
   - **Current week (all models)**: snapshot.weekly (existing headline)
   - **Per-model rows**: existing `models` filtered to modelKey != ""

   Each row shows remaining %, reset time, and the local token count.
   The existing `.metric` row pattern can be reused.

### Contract tests (tests/usage_contract.rs)

7. Extend tests for `five_hour` parsing: a payload with `five_hour`
   plus `seven_day` plus `limits` must produce `session` populated.

### What does NOT change

- Codex card is unchanged (no session/per-model split in Codex API).
- Tray title still shows primary provider's total remaining.
- `PRIVACY.md` boundaries unchanged — `five_hour` is already in the
  API response we fetch; no new endpoint or credential access.
