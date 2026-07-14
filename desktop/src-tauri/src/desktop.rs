use crate::{
    ModelUsage, ProviderId, UsageSnapshot, UsageWindow,
    service::{AppPaths, UsageService},
};
use serde::{Deserialize, Serialize};
use std::{sync::Mutex, time::Instant};
use tauri::{
    AppHandle, Emitter, Manager, PhysicalPosition, Runtime, State, WindowEvent,
    image::Image,
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub primary_provider: ProviderId,
    pub language: String,
}

impl Default for AppSettings {
    fn default() -> Self {
        let language = std::env::var("LANG")
            .ok()
            .filter(|language| language.starts_with("zh"))
            .map(|_| "zh-Hans".to_string())
            .unwrap_or_else(|| "en".to_string());
        Self {
            primary_provider: ProviderId::Codex,
            language,
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsPatch {
    pub primary_provider: Option<ProviderId>,
    pub language: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderView {
    pub id: ProviderId,
    pub display_name: String,
    pub snapshot: Option<UsageSnapshot>,
    pub local_tokens: Option<u64>,
    pub failure: Option<String>,
    pub loading: bool,
    pub models: Vec<ModelUsage>,
    pub session: Option<UsageWindow>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppViewState {
    pub settings: AppSettings,
    pub providers: Vec<ProviderView>,
    pub refreshing: bool,
}

impl Default for AppViewState {
    fn default() -> Self {
        Self {
            settings: AppSettings::default(),
            providers: [ProviderId::Codex, ProviderId::Claude]
                .into_iter()
                .map(|id| ProviderView {
                    id,
                    display_name: id.display_name().to_string(),
                    snapshot: None,
                    local_tokens: None,
                    failure: None,
                    loading: true,
                    models: vec![],
                    session: None,
                })
                .collect(),
            refreshing: true,
        }
    }
}

#[derive(Default)]
struct PopupState {
    /// When the panel was last hidden. Used to suppress the reopen that would
    /// otherwise follow the focus-loss → tray-click event pair, which is how a
    /// second click on the tray icon closes the panel (contract rule I3).
    hidden_at: Option<Instant>,
}

pub struct DesktopState {
    view: Mutex<AppViewState>,
    popup: Mutex<PopupState>,
    service: UsageService,
}

impl DesktopState {
    fn new(service: UsageService) -> Self {
        let view = service.initial_view();
        Self {
            view: Mutex::new(view),
            popup: Mutex::new(PopupState::default()),
            service,
        }
    }
}

#[tauri::command]
fn get_app_state(state: State<'_, DesktopState>) -> AppViewState {
    state.view.lock().expect("view state").clone()
}

#[tauri::command]
fn save_settings<R: Runtime>(
    app: AppHandle<R>,
    state: State<'_, DesktopState>,
    patch: SettingsPatch,
) -> AppViewState {
    let view = {
        let mut view = state.view.lock().expect("view state");
        if let Some(provider) = patch.primary_provider {
            view.settings.primary_provider = provider;
        }
        if let Some(language) = patch
            .language
            .filter(|value| value == "en" || value == "zh-Hans")
        {
            view.settings.language = language;
        }
        view.clone()
    };
    state.service.save_settings(&view.settings);
    update_tray(&app, &view);
    view
}

#[tauri::command]
async fn refresh_usage<R: Runtime>(app: AppHandle<R>, manual: bool) -> AppViewState {
    perform_refresh(app, manual).await
}

#[tauri::command]
fn quit_app<R: Runtime>(app: AppHandle<R>) {
    app.exit(0);
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let app_data = app.path().app_data_dir()?;
            app.manage(DesktopState::new(UsageService::new(AppPaths::discover(
                app_data,
            ))));
            build_tray(app.handle())?;
            let initial = app
                .state::<DesktopState>()
                .view
                .lock()
                .expect("view state")
                .clone();
            update_tray(app.handle(), &initial);
            if let Some(window) = app.get_webview_window("main") {
                let app_handle = app.handle().clone();
                window.on_window_event(move |event| {
                    if matches!(event, WindowEvent::Focused(false)) {
                        hide_popup(&app_handle);
                    }
                });
                if std::env::var_os("AIUSAGEBAR_SHOW_ON_LAUNCH").is_some() {
                    window.show()?;
                    window.set_focus()?;
                }
            }
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                perform_refresh(app_handle.clone(), false).await;
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
                interval.tick().await;
                loop {
                    interval.tick().await;
                    perform_refresh(app_handle.clone(), false).await;
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_app_state,
            save_settings,
            refresh_usage,
            quit_app,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run AIUsageBar");
}

fn build_tray<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    TrayIconBuilder::with_id("main-tray")
        .icon(tray_image(None, ProviderId::Codex))
        .icon_as_template(cfg!(target_os = "macos"))
        .title("C —%")
        .tooltip("TokenTracker")
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                position,
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                toggle_popup(tray.app_handle(), position.x, position.y);
            }
        })
        .build(app)?;
    Ok(())
}

fn toggle_popup<R: Runtime>(app: &AppHandle<R>, x: f64, y: f64) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    if window.is_visible().unwrap_or(false) {
        hide_popup(app);
        return;
    }
    // If the panel was hidden micro-seconds ago, this click is the same gesture
    // that dismissed it (focus loss fired first) — not a request to reopen.
    let just_hidden = app
        .try_state::<DesktopState>()
        .and_then(|state| state.popup.lock().expect("popup state").hidden_at)
        .is_some_and(|at| at.elapsed() < std::time::Duration::from_millis(250));
    if just_hidden {
        return;
    }
    show_popup(app, x, y);
}

fn show_popup<R: Runtime>(app: &AppHandle<R>, x: f64, y: f64) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    position_popup(&window, x, y);
    let _ = window.show();
    let _ = window.set_focus();
    if app
        .try_state::<DesktopState>()
        .is_some_and(|state| state.service.is_stale(chrono::Duration::seconds(30)))
    {
        let app_handle = app.clone();
        tauri::async_runtime::spawn(async move {
            perform_refresh(app_handle, false).await;
        });
    }
}

async fn perform_refresh<R: Runtime>(app: AppHandle<R>, manual: bool) -> AppViewState {
    let existing = {
        let state = app.state::<DesktopState>();
        let mut view = state.view.lock().expect("view state");
        view.refreshing = true;
        for provider in &mut view.providers {
            provider.loading = provider.snapshot.is_none();
        }
        view.clone()
    };
    let _ = app.emit("usage-updated", existing.clone());
    let refreshed = app
        .state::<DesktopState>()
        .service
        .refresh(existing, manual)
        .await;
    {
        let state = app.state::<DesktopState>();
        *state.view.lock().expect("view state") = refreshed.clone();
    }
    update_tray(&app, &refreshed);
    let _ = app.emit("usage-updated", refreshed.clone());
    refreshed
}

fn hide_popup<R: Runtime>(app: &AppHandle<R>) {
    if let Some(state) = app.try_state::<DesktopState>() {
        state.popup.lock().expect("popup state").hidden_at = Some(Instant::now());
    }
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.hide();
    }
}

fn position_popup<R: Runtime>(window: &tauri::WebviewWindow<R>, x: f64, y: f64) {
    let Ok(Some(monitor)) = window.monitor_from_point(x, y) else {
        return;
    };
    let Ok(size) = window.outer_size() else {
        return;
    };
    let area = monitor.work_area();
    let left = area.position.x as f64;
    let top = area.position.y as f64;
    let right = left + area.size.width as f64;
    let bottom = top + area.size.height as f64;
    let distances = [
        ("left", x - left),
        ("right", right - x),
        ("top", y - top),
        ("bottom", bottom - y),
    ];
    let edge = distances
        .into_iter()
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .map(|item| item.0)
        .unwrap_or("top");
    let gap = 8.0;
    let (mut popup_x, mut popup_y) = match edge {
        "bottom" => (x - size.width as f64 / 2.0, y - size.height as f64 - gap),
        "left" => (x + gap, y - size.height as f64 / 2.0),
        "right" => (x - size.width as f64 - gap, y - size.height as f64 / 2.0),
        _ => (x - size.width as f64 / 2.0, y + gap),
    };
    popup_x = popup_x.clamp(
        left + gap,
        (right - size.width as f64 - gap).max(left + gap),
    );
    popup_y = popup_y.clamp(
        top + gap,
        (bottom - size.height as f64 - gap).max(top + gap),
    );
    let _ = window.set_position(PhysicalPosition::new(
        popup_x.round() as i32,
        popup_y.round() as i32,
    ));
}

pub fn update_tray<R: Runtime>(app: &AppHandle<R>, view: &AppViewState) {
    let provider = view.settings.primary_provider;
    let remaining = view
        .providers
        .iter()
        .find(|item| item.id == provider)
        .and_then(|item| item.snapshot.as_ref())
        .map(|snapshot| {
            snapshot
                .session
                .as_ref()
                .unwrap_or(&snapshot.weekly)
                .remaining_percent
                .round()
                .clamp(0.0, 100.0) as u8
        });
    if let Some(tray) = app.tray_by_id("main-tray") {
        let value = remaining
            .map(|value| value.to_string())
            .unwrap_or_else(|| "—".into());
        let initial = provider.initial();
        let _ = tray.set_title(Some(format!("{initial} {value}%")));
        let _ = tray.set_tooltip(Some(format!(
            "{}: {value}% remaining",
            provider.display_name()
        )));
        if cfg!(target_os = "macos") {
            let _ = tray.set_icon(None);
        } else {
            let _ = tray.set_icon(Some(tray_image(remaining, provider)));
        }
    }
}

fn tray_image(percentage: Option<u8>, provider: ProviderId) -> Image<'static> {
    const WIDTH: usize = 32;
    const HEIGHT: usize = 32;
    let mut rgba = vec![0_u8; WIDTH * HEIGHT * 4];
    let accent = if cfg!(target_os = "macos") {
        [0, 0, 0, 255]
    } else if provider == ProviderId::Codex {
        [33, 173, 85, 255]
    } else {
        [229, 138, 58, 255]
    };
    let text = percentage
        .map(|value| value.to_string())
        .unwrap_or_else(|| "--".into());
    let scale = if text.len() >= 3 { 2 } else { 3 };
    let glyph_width = 3 * scale;
    let spacing = scale;
    let total_width = text.len() * glyph_width + text.len().saturating_sub(1) * spacing;
    let start_x = (WIDTH.saturating_sub(total_width)) / 2;
    for (index, character) in text.chars().enumerate() {
        draw_glyph(
            &mut rgba,
            character,
            start_x + index * (glyph_width + spacing),
            6,
            scale,
            accent,
        );
    }
    for x in 2..30 {
        put_pixel(&mut rgba, x, 26, [95, 95, 100, 170]);
        put_pixel(&mut rgba, x, 27, [95, 95, 100, 170]);
    }
    let filled = percentage
        .map(|value| 28 * value as usize / 100)
        .unwrap_or_default();
    for x in 2..(2 + filled) {
        put_pixel(&mut rgba, x, 26, accent);
        put_pixel(&mut rgba, x, 27, accent);
    }
    Image::new_owned(rgba, WIDTH as u32, HEIGHT as u32)
}

fn draw_glyph(
    buffer: &mut [u8],
    character: char,
    x: usize,
    y: usize,
    scale: usize,
    color: [u8; 4],
) {
    let rows: [u8; 5] = match character {
        '0' => [0b111, 0b101, 0b101, 0b101, 0b111],
        '1' => [0b010, 0b110, 0b010, 0b010, 0b111],
        '2' => [0b111, 0b001, 0b111, 0b100, 0b111],
        '3' => [0b111, 0b001, 0b111, 0b001, 0b111],
        '4' => [0b101, 0b101, 0b111, 0b001, 0b001],
        '5' => [0b111, 0b100, 0b111, 0b001, 0b111],
        '6' => [0b111, 0b100, 0b111, 0b101, 0b111],
        '7' => [0b111, 0b001, 0b010, 0b010, 0b010],
        '8' => [0b111, 0b101, 0b111, 0b101, 0b111],
        '9' => [0b111, 0b101, 0b111, 0b001, 0b111],
        _ => [0, 0, 0b111, 0, 0],
    };
    for (row, bits) in rows.into_iter().enumerate() {
        for column in 0..3 {
            if bits & (1 << (2 - column)) == 0 {
                continue;
            }
            for dy in 0..scale {
                for dx in 0..scale {
                    put_pixel(buffer, x + column * scale + dx, y + row * scale + dy, color);
                }
            }
        }
    }
}

fn put_pixel(buffer: &mut [u8], x: usize, y: usize, color: [u8; 4]) {
    let index = (y * 32 + x) * 4;
    if let Some(pixel) = buffer.get_mut(index..index + 4) {
        pixel.copy_from_slice(&color);
    }
}
