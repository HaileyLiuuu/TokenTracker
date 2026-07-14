const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const { openUrl } = window.__TAURI__.opener;

const copy = {
  en: {
    usage: "Usage", weeklyUsage: "Weekly usage", primary: "Primary", language: "Language",
    remaining: "Remaining", resets: "Resets", localTokens: "Local 7-day tokens",
    refresh: "Refresh now", quit: "Quit AIUsageBar", providerData: "Provider data",
    updated: "Updated", loading: "Loading…", unavailable: "Unavailable",
    signInCodex: "Sign in to Codex", signInClaude: "Sign in to Claude Code"
  },
  "zh-Hans": {
    usage: "用量", weeklyUsage: "每周用量", primary: "主显示", language: "界面语言",
    remaining: "剩余", resets: "下次重置", localTokens: "本机 7 天 Token",
    refresh: "立即刷新", quit: "退出 AIUsageBar", providerData: "服务官方数据",
    updated: "最后更新", loading: "正在读取…", unavailable: "暂不可用",
    signInCodex: "登录 Codex", signInClaude: "登录 Claude Code"
  }
};

let state = {
  settings: { primaryProvider: "codex", language: navigator.language.startsWith("zh") ? "zh-Hans" : "en" },
  providers: [], refreshing: true
};

const t = key => copy[state.settings.language]?.[key] ?? copy.en[key] ?? key;

function formatDate(value) {
  if (!value) return "—";
  return new Intl.DateTimeFormat(state.settings.language === "zh-Hans" ? "zh-CN" : "en-US", {
    dateStyle: "medium", timeStyle: "short"
  }).format(new Date(value));
}

function formatNumber(value) {
  return value == null ? "—" : new Intl.NumberFormat(state.settings.language === "zh-Hans" ? "zh-CN" : "en-US").format(value);
}

function providerCard(provider) {
  const isCodex = provider.id === "codex";
  const name = isCodex ? "Codex" : "Claude Code";
  const initial = isCodex ? "C" : "A";
  const remaining = provider.snapshot?.weekly?.remainingPercent;
  const percentage = remaining == null ? "—" : `${Math.round(remaining)}%`;
  const note = provider.failure === "loginExpired"
    ? `<button class="setup-link" data-setup="${provider.id}">${isCodex ? t("signInCodex") : t("signInClaude")}</button>`
    : provider.snapshot
      ? `<span>◈ ${t("providerData")}</span><span>${t("updated")} ${new Intl.DateTimeFormat([], { timeStyle: "short" }).format(new Date(provider.snapshot.fetchedAt))}</span>`
      : `<span>${provider.loading ? t("loading") : t("unavailable")}</span>`;
  return `<article class="provider-card">
    <div class="card-heading"><span class="badge ${provider.id}">${initial}</span><span>${name}</span><span class="percentage">${percentage}</span></div>
    <div class="progress"><div class="${provider.id}" style="width:${remaining ?? 0}%;opacity:${remaining != null ? 1 : 0}"></div></div>
    <div class="metric"><span>${t("remaining")}</span><span>${percentage}</span></div>
    <div class="metric"><span>${t("resets")}</span><span>${formatDate(provider.snapshot?.weekly?.resetAt)}</span></div>
    <div class="metric"><span>${t("localTokens")}</span><span>${formatNumber(provider.localTokens)}</span></div>
    <div class="provider-note">${note}</div>
  </article>`;
}

function render() {
  document.documentElement.lang = state.settings.language;
  document.querySelectorAll("[data-i18n]").forEach(el => { el.textContent = t(el.dataset.i18n); });
  document.querySelectorAll("[data-provider]").forEach(button => button.classList.toggle("active", button.dataset.provider === state.settings.primaryProvider));
  document.querySelectorAll("[data-language]").forEach(button => button.classList.toggle("active", button.dataset.language === state.settings.language));
  document.getElementById("provider-cards").innerHTML = state.providers.map(providerCard).join("");
  document.querySelectorAll("[data-setup]").forEach(button => button.addEventListener("click", () => {
    openUrl(button.dataset.setup === "codex" ? "https://developers.openai.com/codex/cli" : "https://docs.anthropic.com/en/docs/claude-code/getting-started");
  }));
  const icon = document.getElementById("refresh-icon");
  icon.classList.toggle("spinning", state.refreshing);
  icon.disabled = state.refreshing;
  document.getElementById("refresh-button").disabled = state.refreshing;
}

async function load() {
  state = await invoke("get_app_state");
  render();
}

async function saveSettings(patch) {
  state = await invoke("save_settings", { patch });
  render();
}

document.getElementById("provider-picker").addEventListener("click", event => {
  const provider = event.target.dataset.provider;
  if (provider) saveSettings({ primaryProvider: provider });
});
document.getElementById("language-picker").addEventListener("click", event => {
  const language = event.target.dataset.language;
  if (language) saveSettings({ language });
});
document.getElementById("refresh-icon").addEventListener("click", () => invoke("refresh_usage", { manual: true }));
document.getElementById("refresh-button").addEventListener("click", () => invoke("refresh_usage", { manual: true }));
document.getElementById("quit-button").addEventListener("click", () => invoke("quit_app"));
document.body.addEventListener("mouseenter", () => invoke("set_window_hovered", { hovered: true }));
document.body.addEventListener("mouseleave", () => invoke("set_window_hovered", { hovered: false }));

await listen("usage-updated", event => { state = event.payload; render(); });
await load();
