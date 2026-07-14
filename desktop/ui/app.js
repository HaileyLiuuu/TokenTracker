const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const { openUrl } = window.__TAURI__.opener;

const copy = {
  en: {
    usage: "Usage", weeklyUsage: "Weekly usage", primary: "Primary", language: "Language",
    remaining: "Remaining", resets: "Resets", localTokens: "Local 7-day tokens",
    refresh: "Refresh now", quit: "Quit TokenTracker", providerData: "Provider data",
    updated: "Updated", loading: "Loading…", unavailable: "Unavailable",
    signInCodex: "Sign in to Codex", signInClaude: "Sign in to Claude Code",
    currentSession: "Current session", currentWeekLabel: "CURRENT WEEK", allModels: "All models",
    refreshLabel: "REFRESH NOW", quitLabel: "QUIT APP"
  },
  "zh-Hans": {
    usage: "用量", weeklyUsage: "每周用量", primary: "主显示", language: "界面语言",
    remaining: "剩余", resets: "下次重置", localTokens: "本机 7 天 Token",
    refresh: "立即刷新", quit: "退出 TokenTracker", providerData: "服务官方数据",
    updated: "最后更新", loading: "正在读取…", unavailable: "暂不可用",
    signInCodex: "登录 Codex", signInClaude: "登录 Claude Code",
    currentSession: "当前会话", currentWeekLabel: "本周用量", allModels: "所有模型",
    refreshLabel: "立即刷新", quitLabel: "退出程序"
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

function renderTier(label, w, localTokens) {
  if (!w) return "";
  const r = w.remainingPercent;
  const pct = r != null ? Math.round(r) + "%" : "—";
  return `<div class="tier-section">
    <div class="tier-heading">${label}</div>
    <div class="tier-row"><span class="tier-label">${t("remaining")}</span><span class="tier-value">${pct}</span></div>
    <div class="tier-row"><span class="tier-label">${t("resets")}</span><span class="tier-value tier-value-sm">${formatDate(w.resetAt)}</span></div>
    <div class="tier-row"><span class="tier-label">${t("localTokens")}</span><span class="tier-value tier-value-sm">${formatNumber(localTokens)}</span></div>
    <div class="tier-progress"><div class="tier-progress-fill" style="width:${r ?? 0}%;opacity:${r != null ? 1 : 0}"></div></div>
  </div>`;
}

function providerCard(provider, index) {
  const isCodex = provider.id === "codex";
  const cls = provider.id;
  const name = provider.displayName || (isCodex ? "Codex" : "Claude Code");
  const initial = isCodex ? "C" : "CC";
  const remaining = provider.snapshot?.weekly?.remainingPercent;
  const pct = remaining != null ? Math.round(remaining) : null;
  const heroPct = pct != null ? pct + "%" : "—";

  const note = provider.failure === "loginExpired"
    ? `<button class="setup-link" data-setup="${cls}">${isCodex ? t("signInCodex") : t("signInClaude")}</button>`
    : provider.snapshot
      ? `<span>◈ ${t("providerData")}</span><span>${t("updated")} ${new Intl.DateTimeFormat([], { timeStyle: "short" }).format(new Date(provider.snapshot.fetchedAt))}</span>`
      : `<span>${provider.loading ? t("loading") : t("unavailable")}</span>`;

  let tierHtml = "";
  if (!isCodex && provider.snapshot) {
    tierHtml += renderTier(t("currentSession"), provider.session, provider.localTokens);
    if (provider.models) {
      provider.models.filter(m => m.modelKey !== "").forEach(m => {
        tierHtml += renderTier(m.displayName, m.weekly, provider.localTokens);
      });
    }
  }

  return `<section class="provider-panel ${cls}">
    <div class="provider-identity">
      <div class="provider-badge">${initial}</div>
      <span class="provider-name">${name}</span>
      <span class="provider-index">${String(index + 1).padStart(2, "0")} ↗</span>
    </div>
    <div class="provider-hero">
      <div class="hero-pct">${heroPct}</div>
      <div class="meta-stack">
        <span class="meta-label">${t("resets")}</span>
        <span class="meta-value">${formatDate(provider.snapshot?.weekly?.resetAt)}</span>
      </div>
      <div class="hero-label">${isCodex ? t("remaining") : t("currentWeekLabel")}</div>
      <div class="meta-stack">
        <span class="meta-label">${t("localTokens")}</span>
        <span class="meta-value">${formatNumber(provider.localTokens)}</span>
      </div>
    </div>
    <div class="progress-bar"><div class="progress-fill" style="width:${remaining ?? 0}%;opacity:${remaining != null ? 1 : 0}"></div></div>
    <div class="progress-labels"><span>0%</span><span>50%</span><span>100%</span></div>
    ${tierHtml}
    <div class="provider-note">${note}</div>
  </section>`;
}

function render() {
  document.documentElement.lang = state.settings.language;
  document.querySelectorAll("[data-i18n]").forEach(el => { el.textContent = t(el.dataset.i18n); });
  document.querySelectorAll("[data-provider]").forEach(button => button.classList.toggle("active", button.dataset.provider === state.settings.primaryProvider));
  document.querySelectorAll("[data-language]").forEach(button => button.classList.toggle("active", button.dataset.language === state.settings.language));
  document.getElementById("provider-cards").innerHTML = state.providers.map(providerCard).join("");
  const primaryIdx = state.providers.findIndex(p => p.id === state.settings.primaryProvider);
  document.getElementById("header-index").textContent =
    (primaryIdx >= 0 ? String(primaryIdx + 1).padStart(2, "0") : "01") + " / 02";
  document.querySelectorAll("[data-setup]").forEach(button => button.addEventListener("click", () => {
    openUrl(button.dataset.setup === "codex" ? "https://developers.openai.com/codex/cli" : "https://docs.anthropic.com/en/docs/claude-code/getting-started");
  }));
  const icon = document.getElementById("refresh-icon");
  icon.classList.toggle("spinning", state.refreshing);
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

await listen("usage-updated", event => { state = event.payload; render(); });
await load();
