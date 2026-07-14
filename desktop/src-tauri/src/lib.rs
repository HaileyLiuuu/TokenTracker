use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::File,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
};

mod desktop;
pub use desktop::run;
mod service;

/// Maximum accepted JSONL line length; longer lines are skipped unbuffered.
pub const MAX_JSONL_LINE_LEN: usize = 512 * 1024;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderId {
    Codex,
    Claude,
}

impl ProviderId {
    /// Short label shown in the tray. "CC" is Claude Code — never "A".
    pub fn initial(self) -> &'static str {
        match self {
            ProviderId::Codex => "C",
            ProviderId::Claude => "CC",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            ProviderId::Codex => "Codex",
            ProviderId::Claude => "Claude Code",
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    pub used_percent: f64,
    pub remaining_percent: f64,
    pub reset_at: Option<DateTime<Utc>>,
    pub duration_minutes: Option<i64>,
}

impl UsageWindow {
    fn new(
        used_percent: f64,
        reset_at: Option<DateTime<Utc>>,
        duration_minutes: Option<i64>,
    ) -> Self {
        let used_percent = used_percent.clamp(0.0, 100.0);
        Self {
            used_percent,
            remaining_percent: 100.0 - used_percent,
            reset_at,
            duration_minutes,
        }
    }

    pub fn starts_at(&self) -> Option<DateTime<Utc>> {
        Some(self.reset_at? - chrono::Duration::minutes(self.duration_minutes?))
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelUsage {
    /// Key suffix from the API: "" for the all-models total, else "fable",
    /// "opus", "sonnet", "haiku", or a tier not yet known at build time.
    pub model_key: String,
    pub display_name: String,
    pub weekly: UsageWindow,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSnapshot {
    pub provider: ProviderId,
    pub weekly: UsageWindow,
    pub fetched_at: DateTime<Utc>,
    /// Per-model breakdown. Empty for Codex. For Claude, entry 0 is the
    /// all-models total and `weekly` above is a copy of it.
    #[serde(default)]
    pub models: Vec<ModelUsage>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCache {
    pub snapshot: Option<UsageSnapshot>,
    pub next_allowed_request_at: Option<DateTime<Utc>>,
}

impl ProviderCache {
    pub fn record_success(&mut self, snapshot: UsageSnapshot) {
        self.snapshot = Some(snapshot);
        self.next_allowed_request_at = None;
    }

    pub fn record_rate_limit(&mut self, received_at: DateTime<Utc>, retry_after: chrono::Duration) {
        self.next_allowed_request_at =
            Some(received_at + retry_after.max(chrono::Duration::zero()));
    }

    pub fn usable_snapshot(&self, now: DateTime<Utc>) -> Option<UsageSnapshot> {
        self.snapshot
            .as_ref()
            .filter(|snapshot| {
                snapshot
                    .weekly
                    .reset_at
                    .map(|reset| reset > now)
                    .unwrap_or_else(|| {
                        now.signed_duration_since(snapshot.fetched_at) < chrono::Duration::hours(24)
                    })
            })
            .cloned()
    }

    pub fn may_request(&self, now: DateTime<Utc>, minimum_interval: chrono::Duration) -> bool {
        if self
            .next_allowed_request_at
            .is_some_and(|allowed| now < allowed)
        {
            return false;
        }
        self.snapshot.as_ref().is_none_or(|snapshot| {
            now.signed_duration_since(snapshot.fetched_at) >= minimum_interval
                || self.usable_snapshot(now).is_none()
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum UsageError {
    #[error("the provider response is not valid JSON: {0}")]
    InvalidJson(#[from] serde_json::Error),
    #[error("the provider response did not include a weekly usage window")]
    MissingWeeklyWindow,
    #[error("the provider returned an invalid reset timestamp")]
    InvalidResetTimestamp,
    #[error("the provider is not signed in")]
    CredentialMissing,
    #[error("the provider credential is invalid: {0}")]
    InvalidCredential(String),
    #[error("the provider sign-in has expired")]
    LoginExpired,
    #[error("the provider temporarily rate limited usage requests")]
    RateLimited,
    #[error("the provider usage service is unavailable: {0}")]
    Unavailable(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct CodexCredential {
    pub access_token: String,
    pub account_id: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ClaudeCredential {
    pub access_token: String,
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Deserialize)]
struct CodexCredentialEnvelope {
    tokens: CodexCredentialTokens,
}

#[derive(Deserialize)]
struct CodexCredentialTokens {
    access_token: String,
    account_id: String,
}

pub fn read_codex_file_credential(codex_home: &Path) -> Result<CodexCredential, UsageError> {
    let data =
        std::fs::read(codex_home.join("auth.json")).map_err(|_| UsageError::CredentialMissing)?;
    let envelope: CodexCredentialEnvelope = serde_json::from_slice(&data)
        .map_err(|error| UsageError::InvalidCredential(error.to_string()))?;
    Ok(CodexCredential {
        access_token: envelope.tokens.access_token,
        account_id: envelope.tokens.account_id,
    })
}

#[derive(Deserialize)]
struct ClaudeCredentialEnvelope {
    #[serde(rename = "claudeAiOauth")]
    claude_ai_oauth: ClaudeOauthCredential,
}

#[derive(Deserialize)]
struct ClaudeOauthCredential {
    #[serde(rename = "accessToken")]
    access_token: String,
    #[serde(rename = "expiresAt")]
    expires_at: Option<i64>,
}

pub fn read_claude_file_credential(claude_home: &Path) -> Result<ClaudeCredential, UsageError> {
    let data = std::fs::read(claude_home.join(".credentials.json"))
        .map_err(|_| UsageError::CredentialMissing)?;
    parse_claude_credential(&data)
}

pub fn parse_claude_credential(data: &[u8]) -> Result<ClaudeCredential, UsageError> {
    let envelope: ClaudeCredentialEnvelope = serde_json::from_slice(data)
        .map_err(|error| UsageError::InvalidCredential(error.to_string()))?;
    let expires_at = envelope
        .claude_ai_oauth
        .expires_at
        .map(|milliseconds| {
            Utc.timestamp_millis_opt(milliseconds)
                .single()
                .ok_or_else(|| UsageError::InvalidCredential("invalid expiry".into()))
        })
        .transpose()?;
    Ok(ClaudeCredential {
        access_token: envelope.claude_ai_oauth.access_token,
        expires_at,
    })
}

#[derive(Deserialize)]
struct CodexPayload {
    rate_limit: CodexRateLimit,
}

#[derive(Deserialize)]
struct CodexRateLimit {
    primary_window: Option<CodexWindow>,
    secondary_window: Option<CodexWindow>,
}

#[derive(Deserialize)]
struct CodexWindow {
    used_percent: f64,
    limit_window_seconds: Option<i64>,
    reset_at: Option<i64>,
}

pub fn parse_codex_usage(
    data: &[u8],
    fetched_at: DateTime<Utc>,
) -> Result<UsageSnapshot, UsageError> {
    let payload: CodexPayload = serde_json::from_slice(data)?;
    let weekly = [
        payload.rate_limit.primary_window,
        payload.rate_limit.secondary_window,
    ]
    .into_iter()
    .flatten()
    .max_by_key(|window| window.limit_window_seconds.unwrap_or_default())
    .ok_or(UsageError::MissingWeeklyWindow)?;
    let reset_at = weekly
        .reset_at
        .map(|timestamp| {
            Utc.timestamp_opt(timestamp, 0)
                .single()
                .ok_or(UsageError::InvalidResetTimestamp)
        })
        .transpose()?;

    Ok(UsageSnapshot {
        provider: ProviderId::Codex,
        weekly: UsageWindow::new(
            weekly.used_percent,
            reset_at,
            weekly.limit_window_seconds.map(|seconds| seconds / 60),
        ),
        fetched_at,
        models: vec![],
    })
}

#[derive(Deserialize)]
struct ClaudeWindow {
    utilization: f64,
    resets_at: Option<String>,
}

pub fn parse_claude_usage(
    data: &[u8],
    fetched_at: DateTime<Utc>,
) -> Result<UsageSnapshot, UsageError> {
    let raw: serde_json::Map<String, serde_json::Value> = serde_json::from_slice(data)?;
    let mut models: Vec<ModelUsage> = Vec::new();

    for (key, value) in &raw {
        if !key.starts_with("seven_day") {
            continue;
        }
        let Ok(window) = serde_json::from_value::<ClaudeWindow>(value.clone()) else {
            continue;
        };
        let model_key = key.strip_prefix("seven_day").unwrap_or(key);
        let model_key = model_key.strip_prefix('_').unwrap_or(model_key);
        let display_name = model_display_name(model_key);
        let reset_at = window
            .resets_at
            .as_deref()
            .map(|value| {
                DateTime::parse_from_rfc3339(value)
                    .map(|date| date.with_timezone(&Utc))
                    .map_err(|_| UsageError::InvalidResetTimestamp)
            })
            .transpose()?;
        models.push(ModelUsage {
            model_key: model_key.to_string(),
            display_name,
            weekly: UsageWindow::new(window.utilization, reset_at, Some(10_080)),
        });
    }

    // Sort: all-models total first, then alphabetical by display name
    models.sort_by(|a, b| {
        a.model_key
            .is_empty()
            .cmp(&b.model_key.is_empty())
            .reverse()
            .then_with(|| a.display_name.cmp(&b.display_name))
    });

    let primary = models.first().ok_or(UsageError::MissingWeeklyWindow)?;

    Ok(UsageSnapshot {
        provider: ProviderId::Claude,
        weekly: primary.weekly.clone(),
        fetched_at,
        models,
    })
}

fn model_display_name(key: &str) -> String {
    match key {
        "" => "All models".into(),
        "fable" => "Fable".into(),
        "sonnet" => "Sonnet".into(),
        "opus" => "Opus".into(),
        "haiku" => "Haiku".into(),
        other => {
            let mut chars = other.chars();
            match chars.next() {
                None => String::new(),
                Some(first) => {
                    let mut name = first.to_uppercase().collect::<String>();
                    name.push_str(&chars.collect::<String>());
                    name
                }
            }
        }
    }
}

pub fn scan_codex_tokens(roots: &[PathBuf], cutoff: DateTime<Utc>) -> u64 {
    let mut total = 0_u64;
    for_each_jsonl_line(roots, |line| {
        let Ok(event) = serde_json::from_slice::<CodexTokenEvent>(line) else {
            return;
        };
        if event.kind != "event_msg" || event.payload.kind != "token_count" {
            return;
        }
        let Ok(timestamp) = DateTime::parse_from_rfc3339(&event.timestamp) else {
            return;
        };
        if timestamp.with_timezone(&Utc) < cutoff {
            return;
        }
        total = total.saturating_add(
            event
                .payload
                .info
                .and_then(|info| info.last_token_usage)
                .map(|usage| usage.total_tokens)
                .unwrap_or_default(),
        );
    });
    total
}

pub fn scan_claude_tokens(roots: &[PathBuf], cutoff: DateTime<Utc>) -> u64 {
    let mut total = 0_u64;
    let mut seen = HashSet::new();
    for_each_jsonl_line(roots, |line| {
        let Ok(event) = serde_json::from_slice::<ClaudeTokenEvent>(line) else {
            return;
        };
        if event.kind != "assistant" {
            return;
        }
        let Ok(timestamp) = DateTime::parse_from_rfc3339(&event.timestamp) else {
            return;
        };
        if timestamp.with_timezone(&Utc) < cutoff {
            return;
        }
        let Some(usage) = event.message.usage else {
            return;
        };
        let identity = event
            .message
            .id
            .unwrap_or_else(|| format!("{}-{}", event.timestamp, usage.total()));
        if seen.insert(identity) {
            total = total.saturating_add(usage.total());
        }
    });
    total
}

fn for_each_jsonl_line(roots: &[PathBuf], mut handle: impl FnMut(&[u8])) {
    for root in roots {
        let files: Vec<PathBuf> = if root.is_file() {
            vec![root.clone()]
        } else if root.is_dir() {
            walkdir::WalkDir::new(root)
                .into_iter()
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().is_file())
                .map(|entry| entry.into_path())
                .filter(|path| {
                    path.extension()
                        .is_some_and(|extension| extension == "jsonl")
                })
                .collect()
        } else {
            Vec::new()
        };
        for path in files {
            let Ok(file) = File::open(path) else { continue };
            let mut reader = BufReader::new(file);
            let mut line = Vec::new();
            while let Some(within_bound) = read_bounded_line(&mut reader, &mut line) {
                if within_bound {
                    handle(&line);
                }
            }
        }
    }
}

/// Reads the next newline-delimited line into `line`, holding at most
/// `MAX_JSONL_LINE_LEN` bytes. Returns `None` at end of file or on a read
/// error, `Some(true)` for a line within the bound, and `Some(false)` for an
/// oversized line, whose bytes are discarded rather than buffered.
fn read_bounded_line(reader: &mut impl BufRead, line: &mut Vec<u8>) -> Option<bool> {
    line.clear();
    let mut seen_any = false;
    let mut oversized = false;
    loop {
        let buffer = match reader.fill_buf() {
            Ok(buf) => buf,
            Err(error) => {
                eprintln!("AIUsageBar: I/O error reading JSONL file, scan incomplete: {error}");
                return None;
            }
        };
        if buffer.is_empty() {
            return seen_any.then_some(!oversized);
        }
        seen_any = true;
        if let Some(newline) = buffer.iter().position(|&byte| byte == b'\n') {
            if !oversized && line.len() + newline <= MAX_JSONL_LINE_LEN {
                line.extend_from_slice(&buffer[..newline]);
            } else {
                oversized = true;
            }
            reader.consume(newline + 1);
            return Some(!oversized);
        }
        let chunk_len = buffer.len();
        if !oversized && line.len() + chunk_len <= MAX_JSONL_LINE_LEN {
            line.extend_from_slice(buffer);
        } else {
            oversized = true;
            line.clear();
        }
        reader.consume(chunk_len);
    }
}

#[derive(Deserialize)]
struct CodexTokenEvent {
    timestamp: String,
    #[serde(rename = "type")]
    kind: String,
    payload: CodexTokenPayload,
}

#[derive(Deserialize)]
struct CodexTokenPayload {
    #[serde(rename = "type")]
    kind: String,
    info: Option<CodexTokenInfo>,
}

#[derive(Deserialize)]
struct CodexTokenInfo {
    last_token_usage: Option<CodexTokenUsage>,
}

#[derive(Deserialize)]
struct CodexTokenUsage {
    total_tokens: u64,
}

#[derive(Deserialize)]
struct ClaudeTokenEvent {
    timestamp: String,
    #[serde(rename = "type")]
    kind: String,
    message: ClaudeMessage,
}

#[derive(Deserialize)]
struct ClaudeMessage {
    id: Option<String>,
    usage: Option<ClaudeTokenUsage>,
}

#[derive(Deserialize)]
struct ClaudeTokenUsage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
}

impl ClaudeTokenUsage {
    fn total(&self) -> u64 {
        self.input_tokens
            .unwrap_or_default()
            .saturating_add(self.output_tokens.unwrap_or_default())
            .saturating_add(self.cache_read_input_tokens.unwrap_or_default())
            .saturating_add(self.cache_creation_input_tokens.unwrap_or_default())
    }
}
