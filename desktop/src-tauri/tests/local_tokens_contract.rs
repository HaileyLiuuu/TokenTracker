use aiusagebar_core::{MAX_JSONL_LINE_LEN, scan_claude_tokens, scan_codex_tokens};
use chrono::{TimeZone, Utc};
use std::fs;

#[test]
fn local_logs_are_bounded_by_the_weekly_window_and_claude_messages_are_deduplicated() {
    let temp = tempfile::tempdir().unwrap();
    let codex = temp.path().join("codex");
    let claude = temp.path().join("claude");
    fs::create_dir_all(&codex).unwrap();
    fs::create_dir_all(&claude).unwrap();
    fs::write(
        codex.join("session.jsonl"),
        concat!(
            "{\"timestamp\":\"2026-07-05T12:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":1000}}}}\n",
            "{\"timestamp\":\"2026-07-10T12:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":2500}}}}\n"
        ),
    )
    .unwrap();
    let message = "{\"timestamp\":\"2026-07-10T12:00:00Z\",\"type\":\"assistant\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"cache_read_input_tokens\":30,\"cache_creation_input_tokens\":40}}}";
    fs::write(
        claude.join("session.jsonl"),
        format!("{message}\n{message}\n"),
    )
    .unwrap();
    let cutoff = Utc.with_ymd_and_hms(2026, 7, 9, 0, 0, 0).unwrap();

    assert_eq!(scan_codex_tokens(&[codex], cutoff), 2_500);
    assert_eq!(scan_claude_tokens(&[claude], cutoff), 100);
}

#[test]
fn oversized_jsonl_lines_are_skipped_without_buffering_and_surrounding_lines_still_count() {
    let temp = tempfile::tempdir().unwrap();
    let codex = temp.path().join("codex");
    fs::create_dir_all(&codex).unwrap();

    let valid_before = "{\"timestamp\":\"2026-07-10T12:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":1000}}}}";
    let valid_after = "{\"timestamp\":\"2026-07-10T13:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":2500}}}}";
    // A syntactically valid event padded past the line bound must be skipped,
    // and the reader must resynchronize on the next newline.
    let oversized = format!(
        "{{\"timestamp\":\"2026-07-10T12:30:00Z\",\"type\":\"event_msg\",\"pad\":\"{}\",\"payload\":{{\"type\":\"token_count\",\"info\":{{\"last_token_usage\":{{\"total_tokens\":50000}}}}}}}}",
        "a".repeat(MAX_JSONL_LINE_LEN)
    );
    fs::write(
        codex.join("session.jsonl"),
        format!("{valid_before}\n{oversized}\n{valid_after}\n"),
    )
    .unwrap();
    let cutoff = Utc.with_ymd_and_hms(2026, 7, 9, 0, 0, 0).unwrap();

    assert_eq!(scan_codex_tokens(&[codex], cutoff), 3_500);
}
