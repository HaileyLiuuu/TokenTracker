use aiusagebar_core::{ClaudeCredential, read_claude_file_credential, read_codex_file_credential};
use chrono::{TimeZone, Utc};
use std::fs;

#[test]
fn existing_cli_credentials_are_reused_without_reconfiguration() {
    let temp = tempfile::tempdir().unwrap();
    let codex_home = temp.path().join(".codex");
    let claude_home = temp.path().join(".claude");
    fs::create_dir_all(&codex_home).unwrap();
    fs::create_dir_all(&claude_home).unwrap();
    fs::write(
        codex_home.join("auth.json"),
        r#"{"tokens":{"access_token":"codex-token","account_id":"account-1"}}"#,
    )
    .unwrap();
    fs::write(
        claude_home.join(".credentials.json"),
        r#"{"claudeAiOauth":{"accessToken":"claude-token","expiresAt":1784000000000}}"#,
    )
    .unwrap();

    let codex = read_codex_file_credential(&codex_home).unwrap();
    let claude = read_claude_file_credential(&claude_home).unwrap();

    assert_eq!(codex.access_token, "codex-token");
    assert_eq!(codex.account_id, "account-1");
    assert_eq!(claude.access_token, "claude-token");
    assert_eq!(
        claude.expires_at.unwrap().timestamp_millis(),
        1_784_000_000_000
    );
}

#[test]
fn an_expired_cached_claude_credential_is_not_reused() {
    let now = Utc.with_ymd_and_hms(2026, 7, 17, 1, 40, 0).unwrap();

    // Claude Code rotates the keychain token on expiry. A cached copy that has
    // already expired must not be reused, or every refresh fails until the user
    // manually retries and the panel silently shows stale data.
    let expired = ClaudeCredential {
        access_token: "old-token".into(),
        expires_at: Some(now - chrono::Duration::hours(1)),
    };
    assert!(!expired.is_usable_at(now));

    let live = ClaudeCredential {
        access_token: "fresh-token".into(),
        expires_at: Some(now + chrono::Duration::hours(8)),
    };
    assert!(live.is_usable_at(now));

    // A credential without an expiry is reusable — nothing says otherwise.
    let no_expiry = ClaudeCredential {
        access_token: "no-expiry-token".into(),
        expires_at: None,
    };
    assert!(no_expiry.is_usable_at(now));
}
