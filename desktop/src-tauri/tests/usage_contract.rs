use aiusagebar_core::{ProviderId, parse_claude_usage, parse_codex_usage};
use chrono::{TimeZone, Utc};

#[test]
fn provider_payloads_normalize_to_weekly_remaining_usage() {
    let fetched_at = Utc.with_ymd_and_hms(2026, 7, 13, 8, 0, 0).unwrap();
    let codex = parse_codex_usage(
        br#"{"rate_limit":{"primary_window":{"used_percent":21,"limit_window_seconds":604800,"reset_at":1784512550},"secondary_window":null}}"#,
        fetched_at,
    )
    .unwrap();
    let claude = parse_claude_usage(
        br#"{"seven_day":{"utilization":42,"resets_at":"2026-07-20T08:00:00Z"}}"#,
        fetched_at,
    )
    .unwrap();

    assert_eq!(codex.provider, ProviderId::Codex);
    assert_eq!(codex.weekly.remaining_percent, 79.0);
    assert_eq!(codex.weekly.duration_minutes, Some(10_080));
    assert_eq!(claude.provider, ProviderId::Claude);
    assert_eq!(claude.weekly.remaining_percent, 58.0);
    assert_eq!(
        claude.weekly.reset_at,
        Some(Utc.with_ymd_and_hms(2026, 7, 20, 8, 0, 0).unwrap())
    );
}
