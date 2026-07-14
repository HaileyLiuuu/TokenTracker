use aiusagebar_core::{read_claude_file_credential, read_codex_file_credential};
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
