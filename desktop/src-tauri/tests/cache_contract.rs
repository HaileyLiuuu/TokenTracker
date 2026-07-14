use aiusagebar_core::{ProviderCache, ProviderId, UsageSnapshot, UsageWindow};
use chrono::{Duration, TimeZone, Utc};

#[test]
fn claude_rate_limit_keeps_the_last_real_snapshot_until_its_reset() {
    let now = Utc.with_ymd_and_hms(2026, 7, 13, 8, 0, 0).unwrap();
    let snapshot = UsageSnapshot {
        provider: ProviderId::Claude,
        weekly: UsageWindow {
            used_percent: 42.0,
            remaining_percent: 58.0,
            reset_at: Some(now + Duration::days(7)),
            duration_minutes: Some(10_080),
        },
        fetched_at: now,
    };
    let mut cache = ProviderCache::default();
    cache.record_success(snapshot.clone());
    cache.record_rate_limit(now + Duration::minutes(6), Duration::minutes(20));

    assert_eq!(
        cache.usable_snapshot(now + Duration::minutes(7)),
        Some(snapshot.clone())
    );
    assert!(!cache.may_request(now + Duration::minutes(7), Duration::minutes(5)));
    assert_eq!(cache.usable_snapshot(now + Duration::days(8)), None);
}
