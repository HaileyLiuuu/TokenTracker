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
    // Single-tier payload still produces a models entry
    assert_eq!(claude.models.len(), 1);
    assert_eq!(claude.models[0].model_key, "");
    assert_eq!(claude.models[0].display_name, "All models");
}

#[test]
fn claude_per_model_windows_are_extracted_as_model_usage_entries() {
    let fetched_at = Utc.with_ymd_and_hms(2026, 7, 13, 8, 0, 0).unwrap();
    let snapshot = parse_claude_usage(
        br#"{"seven_day":{"utilization":42,"resets_at":"2026-07-20T08:00:00Z"},"seven_day_sonnet":{"utilization":65,"resets_at":"2026-07-20T08:00:00Z"},"seven_day_opus":{"utilization":10,"resets_at":"2026-07-20T08:00:00Z"}}"#,
        fetched_at,
    )
    .unwrap();

    assert_eq!(snapshot.provider, ProviderId::Claude);
    assert_eq!(snapshot.weekly.remaining_percent, 58.0); // primary = all-models total
    assert_eq!(snapshot.models.len(), 3);

    assert_eq!(snapshot.models[0].model_key, "");
    assert_eq!(snapshot.models[0].display_name, "All models");
    assert_eq!(snapshot.models[0].weekly.remaining_percent, 58.0);

    assert_eq!(snapshot.models[1].model_key, "opus");
    assert_eq!(snapshot.models[1].display_name, "Opus");
    assert_eq!(snapshot.models[1].weekly.remaining_percent, 90.0);

    assert_eq!(snapshot.models[2].model_key, "sonnet");
    assert_eq!(snapshot.models[2].display_name, "Sonnet");
    assert_eq!(snapshot.models[2].weekly.remaining_percent, 35.0);
}

#[test]
fn limits_array_with_weekly_scoped_entries_adds_model_rows() {
    let fetched_at = Utc.with_ymd_and_hms(2026, 7, 13, 8, 0, 0).unwrap();
    let snapshot = parse_claude_usage(
        br#"{"seven_day":{"utilization":14,"resets_at":"2026-07-17T12:00:00Z"},"limits":[{"kind":"session","group":"session","percent":7,"resets_at":"2026-07-14T05:20:00Z","scope":null,"is_active":false},{"kind":"weekly_all","group":"weekly","percent":14,"resets_at":"2026-07-17T12:00:00Z","scope":null,"is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":24,"resets_at":"2026-07-17T12:00:00Z","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}]}"#,
        fetched_at,
    )
    .unwrap();

    assert_eq!(snapshot.weekly.remaining_percent, 86.0); // 100-14
    assert_eq!(snapshot.models.len(), 2);

    assert_eq!(snapshot.models[0].model_key, "");
    assert_eq!(snapshot.models[0].display_name, "All models");

    assert_eq!(snapshot.models[1].model_key, "fable");
    assert_eq!(snapshot.models[1].display_name, "Fable");
    assert_eq!(snapshot.models[1].weekly.remaining_percent, 76.0); // 100-24
}

#[test]
fn limits_weekly_scoped_does_not_duplicate_existing_seven_day_entry() {
    let fetched_at = Utc.with_ymd_and_hms(2026, 7, 13, 8, 0, 0).unwrap();
    // seven_day_sonnet already provides Sonnet; a limits weekly_scoped for Sonnet
    // must not create a duplicate entry.
    let snapshot = parse_claude_usage(
        br#"{"seven_day":{"utilization":14,"resets_at":"2026-07-17T12:00:00Z"},"seven_day_sonnet":{"utilization":15,"resets_at":"2026-07-17T12:00:00Z"},"limits":[{"kind":"weekly_scoped","percent":15,"resets_at":"2026-07-17T12:00:00Z","scope":{"model":{"display_name":"Sonnet"}},"is_active":true}]}"#,
        fetched_at,
    )
    .unwrap();

    assert_eq!(snapshot.models.len(), 2);
    // Sonnet is the seven_day_sonnet entry, not duplicated from limits
    let sonnet_entries: Vec<_> = snapshot
        .models
        .iter()
        .filter(|m| m.display_name == "Sonnet")
        .collect();
    assert_eq!(sonnet_entries.len(), 1);
}

#[test]
fn unknown_model_tier_gets_title_case_fallback_name() {
    let fetched_at = Utc.with_ymd_and_hms(2026, 7, 13, 8, 0, 0).unwrap();
    let snapshot = parse_claude_usage(
        br#"{"seven_day":{"utilization":42,"resets_at":"2026-07-20T08:00:00Z"},"seven_day_futuremodel":{"utilization":20,"resets_at":"2026-07-20T08:00:00Z"}}"#,
        fetched_at,
    )
    .unwrap();

    assert_eq!(snapshot.models.len(), 2);
    assert_eq!(snapshot.models[1].model_key, "futuremodel");
    assert_eq!(snapshot.models[1].display_name, "Futuremodel");
    assert_eq!(snapshot.models[1].weekly.remaining_percent, 80.0);
}

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

#[test]
fn missing_five_hour_produces_session_none() {
    let fetched_at = Utc.with_ymd_and_hms(2026, 7, 13, 8, 0, 0).unwrap();
    let snapshot = parse_claude_usage(
        br#"{"seven_day":{"utilization":42,"resets_at":"2026-07-20T08:00:00Z"}}"#,
        fetched_at,
    )
    .unwrap();

    assert_eq!(snapshot.weekly.remaining_percent, 58.0);
    assert!(snapshot.session.is_none());
}
