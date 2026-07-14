use crate::desktop::{AppSettings, AppViewState, ProviderView};
use crate::{
    ClaudeCredential, ProviderCache, ProviderId, UsageError, UsageSnapshot,
    parse_claude_credential, parse_claude_usage, parse_codex_usage, read_claude_file_credential,
    read_codex_file_credential, scan_claude_tokens, scan_codex_tokens,
};
use chrono::{DateTime, Duration, Utc};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::Mutex,
};

const CLAUDE_MINIMUM_FETCH_INTERVAL: Duration = Duration::minutes(5);

#[derive(Clone, Debug)]
pub struct AppPaths {
    pub codex_home: PathBuf,
    pub claude_home: PathBuf,
    pub app_data: PathBuf,
}

impl AppPaths {
    pub fn discover(app_data: PathBuf) -> Self {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        let codex_home = std::env::var_os("CODEX_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"));
        Self {
            codex_home,
            claude_home: home.join(".claude"),
            app_data,
        }
    }

    fn settings_file(&self) -> PathBuf {
        self.app_data.join("settings.json")
    }

    fn cache_file(&self) -> PathBuf {
        self.app_data.join("usage-cache.json")
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistentCache {
    codex: ProviderCache,
    claude: ProviderCache,
}

enum ClaudeCredentialState {
    Unread,
    Loaded(ClaudeCredential),
    Failed,
}

pub struct UsageService {
    client: Client,
    paths: AppPaths,
    cache: Mutex<PersistentCache>,
    claude_credential: Mutex<ClaudeCredentialState>,
    refresh_lock: tokio::sync::Mutex<()>,
    last_completed_at: Mutex<Option<DateTime<Utc>>>,
}

impl UsageService {
    pub fn new(paths: AppPaths) -> Self {
        let cache = read_json(&paths.cache_file()).unwrap_or_default();
        Self {
            client: Client::builder()
                .timeout(std::time::Duration::from_secs(15))
                .user_agent(concat!("aiusagebar/", env!("CARGO_PKG_VERSION")))
                .build()
                .expect("HTTP client"),
            paths,
            cache: Mutex::new(cache),
            claude_credential: Mutex::new(ClaudeCredentialState::Unread),
            refresh_lock: tokio::sync::Mutex::new(()),
            last_completed_at: Mutex::new(None),
        }
    }

    pub fn initial_view(&self) -> AppViewState {
        let now = Utc::now();
        let cache = self.cache.lock().expect("usage cache");
        let settings = self.load_settings();
        AppViewState {
            settings,
            providers: [
                (ProviderId::Codex, cache.codex.usable_snapshot(now)),
                (ProviderId::Claude, cache.claude.usable_snapshot(now)),
            ]
            .into_iter()
            .map(|(id, snapshot)| ProviderView {
                id,
                display_name: id.display_name().to_string(),
                snapshot: snapshot.clone(),
                models: snapshot
                    .as_ref()
                    .map(|s| s.models.clone())
                    .unwrap_or_default(),
                local_tokens: None,
                failure: None,
                loading: true,
            })
            .collect(),
            refreshing: true,
        }
    }

    pub fn load_settings(&self) -> AppSettings {
        read_json(&self.paths.settings_file()).unwrap_or_default()
    }

    pub fn save_settings(&self, settings: &AppSettings) {
        write_json(&self.paths.settings_file(), settings);
    }

    pub fn is_stale(&self, max_age: Duration) -> bool {
        self.last_completed_at
            .lock()
            .expect("last refresh")
            .is_none_or(|date| Utc::now().signed_duration_since(date) >= max_age)
    }

    pub async fn refresh(&self, existing: AppViewState, manual: bool) -> AppViewState {
        let Ok(_guard) = self.refresh_lock.try_lock() else {
            return existing;
        };
        if manual
            && existing.providers.iter().any(|provider| {
                provider.id == ProviderId::Claude
                    && provider.failure.as_deref() == Some("loginExpired")
            })
        {
            *self.claude_credential.lock().expect("Claude credential") =
                ClaudeCredentialState::Unread;
        }

        let now = Utc::now();
        let (codex_result, claude_result) =
            tokio::join!(self.load_codex(now), self.load_claude(now));
        *self.last_completed_at.lock().expect("last refresh") = Some(Utc::now());
        AppViewState {
            settings: existing.settings,
            providers: vec![codex_result, claude_result],
            refreshing: false,
        }
    }

    async fn load_codex(&self, now: DateTime<Utc>) -> ProviderView {
        let result = self.fetch_codex(now).await;
        let snapshot = result.as_ref().ok().cloned().or_else(|| {
            self.cache
                .lock()
                .expect("usage cache")
                .codex
                .usable_snapshot(now)
        });
        let cutoff = snapshot
            .as_ref()
            .and_then(|value| value.weekly.starts_at())
            .unwrap_or(now - Duration::days(7));
        let roots = vec![
            self.paths.codex_home.join("sessions"),
            self.paths.codex_home.join("archived_sessions"),
        ];
        let local_tokens = tokio::task::spawn_blocking(move || scan_codex_tokens(&roots, cutoff))
            .await
            .ok();
        let models = snapshot
            .as_ref()
            .map(|s| s.models.clone())
            .unwrap_or_default();
        ProviderView {
            id: ProviderId::Codex,
            display_name: ProviderId::Codex.display_name().to_string(),
            snapshot: snapshot.clone(),
            models,
            local_tokens,
            failure: result.err().map(|error| failure_code(&error)),
            loading: false,
        }
    }

    async fn load_claude(&self, now: DateTime<Utc>) -> ProviderView {
        let result = self.fetch_claude(now).await;
        let snapshot = result.as_ref().ok().cloned().or_else(|| {
            self.cache
                .lock()
                .expect("usage cache")
                .claude
                .usable_snapshot(now)
        });
        let cutoff = snapshot
            .as_ref()
            .and_then(|value| value.weekly.starts_at())
            .unwrap_or(now - Duration::days(7));
        let roots = vec![self.paths.claude_home.join("projects")];
        let local_tokens = tokio::task::spawn_blocking(move || scan_claude_tokens(&roots, cutoff))
            .await
            .ok();
        let models = snapshot
            .as_ref()
            .map(|s| s.models.clone())
            .unwrap_or_default();
        ProviderView {
            id: ProviderId::Claude,
            display_name: ProviderId::Claude.display_name().to_string(),
            snapshot: snapshot.clone(),
            models,
            local_tokens,
            failure: result.err().map(|error| failure_code(&error)),
            loading: false,
        }
    }

    async fn fetch_codex(&self, now: DateTime<Utc>) -> Result<UsageSnapshot, UsageError> {
        let credential = read_codex_file_credential(&self.paths.codex_home)?;
        let response = self
            .client
            .get("https://chatgpt.com/backend-api/wham/usage?supports_rewardless_invites=true")
            .bearer_auth(credential.access_token)
            .header("ChatGPT-Account-ID", credential.account_id)
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|error| UsageError::Unavailable(error.to_string()))?;
        match response.status() {
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
                return Err(UsageError::LoginExpired);
            }
            StatusCode::TOO_MANY_REQUESTS => {
                let retry_after = parse_retry_after(
                    response
                        .headers()
                        .get("retry-after")
                        .and_then(|value| value.to_str().ok()),
                    now,
                );
                let mut cache = self.cache.lock().expect("usage cache");
                cache.codex.record_rate_limit(now, retry_after);
                let fallback = cache.codex.usable_snapshot(now);
                self.persist_cache(&cache);
                return fallback.ok_or(UsageError::RateLimited);
            }
            status if !status.is_success() => {
                return Err(UsageError::Unavailable(format!("HTTP {status}")));
            }
            _ => {}
        }
        let data = response
            .bytes()
            .await
            .map_err(|error| UsageError::Unavailable(error.to_string()))?;
        let snapshot = parse_codex_usage(&data, now)?;
        {
            let mut cache = self.cache.lock().expect("usage cache");
            cache.codex.record_success(snapshot.clone());
            self.persist_cache(&cache);
        }
        Ok(snapshot)
    }

    async fn fetch_claude(&self, now: DateTime<Utc>) -> Result<UsageSnapshot, UsageError> {
        {
            let cache = self.cache.lock().expect("usage cache");
            if !cache.claude.may_request(now, CLAUDE_MINIMUM_FETCH_INTERVAL) {
                return cache
                    .claude
                    .usable_snapshot(now)
                    .ok_or(UsageError::RateLimited);
            }
        }
        let credential = self.claude_credential()?;
        if credential.expires_at.is_some_and(|date| date <= now) {
            return Err(UsageError::LoginExpired);
        }
        let response = self
            .client
            .get("https://api.anthropic.com/api/oauth/usage")
            .bearer_auth(credential.access_token)
            .header("anthropic-beta", "oauth-2025-04-20")
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|error| UsageError::Unavailable(error.to_string()))?;
        let received_at = Utc::now();
        match response.status() {
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
                return Err(UsageError::LoginExpired);
            }
            StatusCode::TOO_MANY_REQUESTS => {
                let retry_after = parse_retry_after(
                    response
                        .headers()
                        .get("retry-after")
                        .and_then(|value| value.to_str().ok()),
                    received_at,
                )
                .max(CLAUDE_MINIMUM_FETCH_INTERVAL);
                let mut cache = self.cache.lock().expect("usage cache");
                cache.claude.record_rate_limit(received_at, retry_after);
                let fallback = cache.claude.usable_snapshot(received_at);
                self.persist_cache(&cache);
                return fallback.ok_or(UsageError::RateLimited);
            }
            status if !status.is_success() => {
                return Err(UsageError::Unavailable(format!("HTTP {status}")));
            }
            _ => {}
        }
        let data = response
            .bytes()
            .await
            .map_err(|error| UsageError::Unavailable(error.to_string()))?;
        let snapshot = parse_claude_usage(&data, now)?;
        {
            let mut cache = self.cache.lock().expect("usage cache");
            cache.claude.record_success(snapshot.clone());
            self.persist_cache(&cache);
        }
        Ok(snapshot)
    }

    fn claude_credential(&self) -> Result<ClaudeCredential, UsageError> {
        let mut state = self.claude_credential.lock().expect("Claude credential");
        match &*state {
            ClaudeCredentialState::Loaded(credential) => return Ok(credential.clone()),
            ClaudeCredentialState::Failed => return Err(UsageError::CredentialMissing),
            ClaudeCredentialState::Unread => {}
        }
        let credential = read_claude_system_credential()
            .or_else(|_| read_claude_file_credential(&self.paths.claude_home));
        match credential {
            Ok(credential) => {
                *state = ClaudeCredentialState::Loaded(credential.clone());
                Ok(credential)
            }
            Err(error) => {
                *state = ClaudeCredentialState::Failed;
                Err(error)
            }
        }
    }

    fn persist_cache(&self, cache: &PersistentCache) {
        write_json(&self.paths.cache_file(), cache);
    }
}

fn read_claude_system_credential() -> Result<ClaudeCredential, UsageError> {
    if std::env::var_os("AIUSAGEBAR_DISABLE_KEYCHAIN").is_some() {
        return Err(UsageError::CredentialMissing);
    }
    let username = whoami::username().map_err(|_| UsageError::CredentialMissing)?;
    let entry = keyring::Entry::new("Claude Code-credentials", &username)
        .map_err(|_| UsageError::CredentialMissing)?;
    let secret = entry
        .get_secret()
        .map_err(|_| UsageError::CredentialMissing)?;
    parse_claude_credential(&secret)
}

fn parse_retry_after(value: Option<&str>, now: DateTime<Utc>) -> Duration {
    let Some(value) = value else {
        return Duration::zero();
    };
    if let Ok(seconds) = value.parse::<i64>() {
        return Duration::seconds(seconds.max(0));
    }
    httpdate::parse_http_date(value)
        .ok()
        .map(DateTime::<Utc>::from)
        .map(|date| (date - now).max(Duration::zero()))
        .unwrap_or_default()
}

fn failure_code(error: &UsageError) -> String {
    match error {
        UsageError::CredentialMissing
        | UsageError::InvalidCredential(_)
        | UsageError::LoginExpired => "loginExpired",
        _ => "unavailable",
    }
    .into()
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Option<T> {
    std::fs::read(path)
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
}

fn write_json<T: Serialize>(path: &Path, value: &T) {
    let Some(parent) = path.parent() else { return };
    if std::fs::create_dir_all(parent).is_err() {
        return;
    }
    let Ok(data) = serde_json::to_vec_pretty(value) else {
        return;
    };
    let _ = std::fs::write(path, data);
}
