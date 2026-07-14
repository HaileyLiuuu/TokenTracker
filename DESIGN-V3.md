# TokenTracker v3 — Swiss Editorial Redesign

**Status: EXECUTABLE SPEC. Read CONTEXT.md first. Every section is binding
unless marked "optional."**

## 0. What you are building

A complete visual redesign of the TokenTracker popover panel from a
rounded-card macOS-settings style into a **Swiss editorial / neo-brutalist
data dashboard**. The Rust backend, tray icon interaction, data fetching,
credential handling, and all Tauri IPC commands **do not change at all**.

This spec adapts ChatGPT's SwiftUI-oriented redesign brief
(`swiss-editorial-menu-bar-redesign-brief(1).md`) to our actual tech stack:
**Tauri 2 + static HTML/CSS/JS**. Where ChatGPT's brief contradicts our
reality (Xcode asset catalogs, SwiftUI views, `NSPopover`), this spec
overrides it.

---

## 1. Tech stack (what you touch and what you don't)

| Layer | Framework | Files you modify |
|---|---|---|
| UI | HTML + CSS + vanilla JS | `desktop/ui/index.html`, `desktop/ui/styles.css`, `desktop/ui/app.js` |
| Window config | JSON | `desktop/src-tauri/tauri.conf.json` |
| App icon assets | PNG files | `desktop/src-tauri/icons/` |
| Backend | Rust (Tauri 2) | **DO NOT TOUCH** — `lib.rs`, `service.rs`, `desktop.rs`, `main.rs`, any `.rs` test file |
| Build config | Cargo.toml, package.json | **DO NOT TOUCH** |

**Rule:** if a change requires modifying any `.rs` file, stop — you are doing
something wrong.

---

## 2. Design language (the visual contract)

```
Swiss editorial + neo-brutalist + data poster
```

Every visual element follows these rules:

1. **Flat color, no gradients, no glow, no blur.**
2. **1px near-black borders on structural containers.** No border-radius
   beyond 2px (functionally: square).
3. **Hard-edged rectangular modules.** No pill shapes, no rounded cards, no
   floating shadow cards.
4. **Large hero numbers** (80–110px percentages) as the focal point of each
   provider panel.
5. **Uppercase compact labels** (10–13px, +2–8% letter-spacing) for all
   metadata.
6. **Visible 20px grid** (5–10% opacity) on provider panel backgrounds.
7. **4px base spacing scale.**

---

## 3. Color system

### 3.1 Light mode (from ChatGPT brief, adopted as-is)

```css
:root {
  --bg:          #F3F1E9;
  --ink:         #181916;
  --blue:        #3047F5;
  --lime:        #D8FF3E;
  --lavender:    #CBCBFF;
  --coral:       #F4B09F;
  --orange:      #FF963D;
  --white:       #FAF9F4;
  --muted-ink:   rgba(24, 25, 22, 0.62);
  --grid-line:   rgba(24, 25, 22, 0.08);
  --border:      #181916;
}
```

### 3.2 Dark mode (our addition — ChatGPT's brief doesn't have this)

```css
@media (prefers-color-scheme: dark) {
  :root {
    --bg:          #1E1D1A;
    --ink:         #F3F1E9;
    --blue:        #5B6EFF;
    --lime:        #C8E63C;
    --lavender:    #3A3870;
    --coral:       #6B3A30;
    --orange:      #D97A35;
    --white:       #2A2925;
    --muted-ink:   rgba(243, 241, 233, 0.55);
    --grid-line:   rgba(243, 241, 233, 0.06);
    --border:      #F3F1E9;
  }
}
```

### 3.3 Color usage rules (binding)

- Provider panels each get ONE dominant surface color: Codex = lavender, Claude = coral.
- Active tab/button = electric blue (`--blue`).
- Codex accent = acid lime (`--lime`); Claude accent = orange (`--orange`).
- Borders, text = near-black (`--ink` in light, `--bg`-inverted in dark).
- Do not invent new colors. The 8 tokens above are the entire palette.

---

## 4. Typography

Font stack: system native (Tauri windows default to the OS font).
On macOS that's `-apple-system` (SF Pro). No webfonts, no Google Fonts.

Sizes (binding):

| Role | Size | Weight | Style |
|---|---|---|---|
| Panel headline `USAGE` | 64px | 800 | `letter-spacing: -0.03em` |
| Panel subtitle `· WEEKLY USAGE` | 11px | 600 | uppercase, `letter-spacing: 0.05em` |
| Hero percentage (`86%`) | 96px | 800 | `letter-spacing: -0.05em`, `font-variant-numeric: tabular-nums` |
| Provider name in panel | 14px | 650 | uppercase |
| Metadata label (`REMAINING`, `RESETS`) | 11px | 600 | uppercase, `letter-spacing: 0.04em`, color: `--muted-ink` |
| Metadata value (date, token count) | 28px | 700 | `font-variant-numeric: tabular-nums` |
| Footer module labels | 10px | 600 | uppercase, `letter-spacing: 0.05em` |
| Tier sub-label (Current session, Fable) | 12px | 600 | |
| Tier sub-value | 18px | 700 | `font-variant-numeric: tabular-nums` |

---

## 5. Spacing system (4px base)

```
4, 8, 12, 16, 20, 24, 32, 40, 48, 56, 64
```

Internal padding:
- Panel outer: 28px top/bottom, 24px left/right
- Header: 32px padding-bottom to separate from tabs
- Provider panels: 28px all sides
- Footer modules: 20px all sides
- Between providers: 0px (they stack directly, separated by a 1px border)

---

## 6. Window size

Edit `desktop/src-tauri/tauri.conf.json` — the `main` window:

```json
"width": 400,
"height": 740
```

The editorial header + two full-height provider panels + three-tier Claude
data + footer need more vertical space than the current 610px.
740px is the target; if token counts are very large, rely on `.cards { overflow-y: auto }`
(already present).

---

## 7. HTML structure (index.html)

Replace the body content with this structure. The existing `data-i18n` /
`data-provider` / `data-language` / `data-setup` attributes MUST be preserved
because `app.js` queries them.

```html
<body>
  <div class="panel">
    <!-- ===== HEADER ===== -->
    <header class="editorial-header">
      <div class="header-left">
        <h1 class="display-heading" data-i18n="usage">USAGE</h1>
        <p class="header-subtitle">· <span data-i18n="weeklyUsage">WEEKLY USAGE</span></p>
      </div>
      <div class="header-right">
        <span class="header-index" id="header-index">01 / 02</span>
        <span class="header-arrow">↗</span>
      </div>
    </header>

    <!-- ===== PROVIDER TABS ===== -->
    <div class="tab-bar" id="provider-picker">
      <button class="tab" data-provider="codex" id="tab-codex">CODEX</button>
      <button class="tab" data-provider="claude" id="tab-claude">CLAUDE CODE</button>
    </div>

    <!-- ===== CARDS CONTAINER ===== -->
    <div class="cards" id="provider-cards">
      <!-- Populated by app.js: providerCard() -->
    </div>

    <!-- ===== FOOTER ===== -->
    <footer class="footer-strip">
      <div class="footer-module" id="language-picker">
        <span class="footer-label" data-i18n="language">LANGUAGE</span>
        <div class="footer-buttons">
          <button class="footer-btn" data-language="zh-Hans">中文</button>
          <button class="footer-btn" data-language="en">ENGLISH</button>
        </div>
      </div>
      <button class="footer-module footer-refresh" id="refresh-button">
        <span class="footer-label">REFRESH<br>NOW</span>
        <span class="refresh-icon" id="refresh-icon">↻</span>
      </button>
      <button class="footer-module footer-quit" id="quit-button">
        <span class="footer-label">QUIT<br>APP</span>
        <span class="quit-icon">↗</span>
      </button>
    </footer>
  </div>
</body>
```

---

## 8. CSS specification (styles.css)

Replace `desktop/ui/styles.css` entirely. The file is ~125 lines today;
the replacement will be ~350 lines. Below is the complete specification.

### 8.1 Reset + panel container

```css
:root { /* color tokens from Section 3 */ }
@media (prefers-color-scheme: dark) { :root { /* dark tokens */ } }

* { box-sizing: border-box; }
html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; }
body {
  color: var(--ink);
  background: transparent;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-size: 13px;
}
button { font: inherit; color: inherit; cursor: default; border: 0; }

.panel {
  width: 100%; height: 100%;
  display: flex; flex-direction: column;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 2px;
}
```

### 8.2 Header

```css
.editorial-header {
  display: flex; justify-content: space-between; align-items: flex-start;
  padding: 28px 24px 32px 24px;
}
.display-heading {
  font-size: 64px; font-weight: 800; line-height: 0.9;
  letter-spacing: -0.03em; margin: 0;
}
.header-subtitle {
  font-size: 11px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.05em; color: var(--muted-ink); margin: 6px 0 0 0;
}
.header-right {
  display: flex; align-items: center; gap: 12px;
  font-size: 11px; font-weight: 600; color: var(--muted-ink);
}
.header-arrow { font-size: 16px; }
```

### 8.3 Tab bar

```css
.tab-bar { display: flex; }
.tab {
  flex: 1; height: 52px; display: grid; place-items: center;
  font-size: 13px; font-weight: 650; text-transform: uppercase;
  letter-spacing: 0.04em;
  background: var(--white); color: var(--ink);
  border: 1px solid var(--border); border-radius: 0;
}
.tab.active { background: var(--blue); color: white; }
.tab:hover:not(.active) { filter: brightness(0.96); }
```

### 8.4 Cards container

```css
.cards {
  display: flex; flex-direction: column; gap: 0;
  min-height: 0; flex: 1; overflow-y: auto;
}
```

### 8.5 Provider panel (shared)

```css
.provider-panel {
  padding: 28px;
  border-bottom: 1px solid var(--border);
  position: relative;
}
.provider-panel.codex  { background-color: var(--lavender); }
.provider-panel.claude { background-color: var(--coral); }

/* Grid background — subtle, 20px squares */
.provider-panel::before {
  content: "";
  position: absolute; inset: 0; pointer-events: none; z-index: 0;
  background-image:
    linear-gradient(var(--grid-line) 1px, transparent 1px),
    linear-gradient(90deg, var(--grid-line) 1px, transparent 1px);
  background-size: 20px 20px;
}
.provider-panel > * { position: relative; z-index: 1; }
```

### 8.6 Provider identity row

```css
.provider-identity {
  display: flex; align-items: center; gap: 12px; margin-bottom: 24px;
}
.provider-badge {
  width: 52px; height: 52px; display: grid; place-items: center;
  font-size: 18px; font-weight: 800;
  border: 1px solid var(--border);
}
.codex .provider-badge { background: var(--lime); color: var(--ink); }
.claude .provider-badge { background: var(--orange); color: var(--ink); }
.provider-name {
  font-size: 14px; font-weight: 650; text-transform: uppercase;
  letter-spacing: 0.04em;
}
.provider-index { margin-left: auto; font-size: 11px; color: var(--muted-ink); }
```

### 8.7 Hero number + metadata grid

```css
.provider-hero {
  display: grid;
  grid-template-columns: 1fr 1fr;
  grid-template-rows: auto auto;
  gap: 8px 16px;
  margin-bottom: 24px;
}
.hero-pct {
  font-size: 96px; font-weight: 800; line-height: 0.85;
  letter-spacing: -0.05em; font-variant-numeric: tabular-nums;
}
.hero-label {
  font-size: 11px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.04em; color: var(--muted-ink);
  align-self: end;
}
.meta-stack { display: flex; flex-direction: column; gap: 4px; }
.meta-label {
  font-size: 11px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.04em; color: var(--muted-ink);
}
.meta-value {
  font-size: 28px; font-weight: 700; font-variant-numeric: tabular-nums;
  line-height: 1.1;
}
```

### 8.8 Progress bar (editorial)

```css
.progress-bar {
  height: 28px; background: var(--white);
  border: 1px solid var(--border); border-radius: 0;
  margin-bottom: 6px; overflow: hidden;
}
.progress-fill {
  height: 100%; border-radius: 0; transition: width 180ms ease;
}
.codex .progress-fill { background: var(--lime); }
.claude .progress-fill { background: var(--orange); }
.progress-labels {
  display: flex; justify-content: space-between;
  font-size: 10px; font-weight: 600; color: var(--muted-ink);
  text-transform: uppercase; letter-spacing: 0.05em;
}
```

### 8.9 Tier sections (Current session, Fable, etc.)

```css
.tier-section {
  margin-top: 16px; padding-top: 16px;
  border-top: 1px solid var(--border);
}
.tier-heading {
  font-size: 12px; font-weight: 600; margin-bottom: 8px;
}
.tier-row {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 4px;
}
.tier-label {
  font-size: 11px; color: var(--muted-ink); text-transform: uppercase;
  letter-spacing: 0.04em;
}
.tier-value {
  font-size: 18px; font-weight: 700; font-variant-numeric: tabular-nums;
}
.tier-progress {
  height: 6px; background: var(--white);
  border: 1px solid var(--border); border-radius: 0;
  margin-top: 4px; overflow: hidden;
}
.tier-progress-fill {
  height: 100%; border-radius: 0; transition: width 180ms ease;
  background: var(--muted-ink); opacity: 0.5;
}
```

### 8.10 Footer

```css
.footer-strip { display: flex; }
.footer-module {
  flex: 1; display: flex; flex-direction: column; justify-content: center;
  align-items: center; gap: 8px; padding: 20px 8px;
  border-top: 1px solid var(--border);
  background: var(--white);
}
.footer-module:not(:last-child) { border-right: 1px solid var(--border); }
.footer-label {
  font-size: 10px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.05em; text-align: center; line-height: 1.3;
}
.footer-refresh { background: var(--lime); }
.footer-refresh:hover { filter: brightness(0.94); }
.footer-quit { background: var(--ink); color: var(--bg); }
.footer-quit:hover { filter: brightness(0.85); }
.footer-buttons { display: flex; gap: 4px; }
.footer-btn {
  padding: 5px 10px; font-size: 10px; font-weight: 600;
  border: 1px solid var(--border); border-radius: 0;
  background: var(--white); color: var(--ink);
  text-transform: uppercase; letter-spacing: 0.05em;
}
.footer-btn.active { background: var(--blue); color: white; }
.refresh-icon, .quit-icon { font-size: 20px; }
.refresh-icon.spinning { animation: spin 0.8s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
```

### 8.11 Utility

```css
/* Loading / unavailable note inside provider panel */
.provider-note {
  margin-top: 12px; font-size: 11px; display: flex;
  justify-content: space-between; gap: 8px;
}
.setup-link {
  padding: 0; background: transparent; color: var(--blue);
  text-decoration: underline;
}
```

---

## 9. JavaScript specification (app.js)

The Rust backend and all `invoke()` commands are unchanged. The JS data
model (`state`, `copy`, `t()`, `formatDate()`, `formatNumber()`,
`load()`, `saveSettings()`, event listeners) is unchanged.

### 9.1 What to REMOVE

- The entire `providerCard()` function body (replaced).
- The `tierSection()` helper (replaced by the inline logic below).

### 9.2 What to ADD — new `providerCard()`

This function builds one provider panel. The structure is:

```
Panel container (provider-panel codex/claude)
├── Identity row: [C] CODEX    01 ↗
├── Hero grid: 86% | RESETS Jul 17, 2026
│              REMAINING | LOCAL 7-DAY TOKENS 54,539,533
├── Progress bar: fill + 0% / 50% / 100% labels
├── Tier sections: Current session / per-model (Claude only)
└── Note: provider data / loading / sign-in link
```

The JS:

```js
function providerCard(provider, index) {
  const isCodex = provider.id === "codex";
  const cls = provider.id; // "codex" or "claude"
  const name = provider.displayName || (isCodex ? "Codex" : "Claude Code");
  const initial = isCodex ? "C" : "CC";
  const remaining = provider.snapshot?.weekly?.remainingPercent;
  const pct = remaining != null ? Math.round(remaining) : null;
  const heroPct = pct != null ? pct + "%" : "—";
  const heroPctStyle = pct != null && pct >= 100 ? "font-size:80px" : "";

  const note = provider.failure === "loginExpired"
    ? `<button class="setup-link" data-setup="${cls}">${isCodex ? t("signInCodex") : t("signInClaude")}</button>`
    : provider.snapshot
      ? `<span>◈ ${t("providerData")}</span><span>${t("updated")} ${new Intl.DateTimeFormat([], { timeStyle: "short" }).format(new Date(provider.snapshot.fetchedAt))}</span>`
      : `<span>${provider.loading ? t("loading") : t("unavailable")}</span>`;

  // ── tier sub-rows (Claude only) ──
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
      <span class="provider-index">${String(index + 1).padStart(2,"0")} ↗</span>
    </div>
    <div class="provider-hero">
      <div class="hero-pct" style="${heroPctStyle}">${heroPct}</div>
      <div class="meta-stack">
        <span class="meta-label">${t("resets")}</span>
        <span class="meta-value">${formatDate(provider.snapshot?.weekly?.resetAt)}</span>
      </div>
      <div class="hero-label">${t("remaining")}</div>
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

function renderTier(label, w, localTokens) {
  if (!w) return "";
  const r = w.remainingPercent;
  const pct = r != null ? Math.round(r) + "%" : "—";
  return `<div class="tier-section">
    <div class="tier-heading">${label}</div>
    <div class="tier-row"><span class="tier-label">${t("remaining")}</span><span class="tier-value">${pct}</span></div>
    <div class="tier-row"><span class="tier-label">${t("resets")}</span><span class="tier-value" style="font-size:14px">${formatDate(w.resetAt)}</span></div>
    <div class="tier-row"><span class="tier-label">${t("localTokens")}</span><span class="tier-value" style="font-size:14px">${formatNumber(localTokens)}</span></div>
    <div class="tier-progress"><div class="tier-progress-fill" style="width:${r ?? 0}%;opacity:${r != null ? 1 : 0}"></div></div>
  </div>`;
}
```

### 9.3 What to UPDATE in `render()`

Change the cards rendering from `.map(providerCard)` to `.map(providerCard)`
— the signature gained an `index` parameter. Update line ~66:

```js
document.getElementById("provider-cards").innerHTML = state.providers.map(providerCard).join("");
```

Keep this line as-is. The `index` parameter is already handled in the new
`providerCard(provider, index)` signature (`.map` calls with `(element, index)`).

### 9.4 What to ADD — header index update

In `render()`, after the cards line, add:

```js
const primaryIdx = state.providers.findIndex(p => p.id === state.settings.primaryProvider);
document.getElementById("header-index").textContent =
  (primaryIdx >= 0 ? String(primaryIdx + 1).padStart(2, "0") : "01") + " / 02";
```

### 9.5 i18n labels

The existing `copy` objects work. The HTML uses `data-i18n` attributes which
`render()` already processes. No new translation keys are needed.

### 9.6 What is REMOVED from app.js

- The old `tierSection()` helper (replaced by `renderTier()` above).
- The old `providerCard()` body.
- Any reference to `.badge`, `.card-heading`, `.percentage`, `.provider-card`,
  `.cards` styling (these selectors are gone from CSS).

### 9.7 What does NOT change in app.js

- `invoke()`, `listen()`, `openUrl()` setup at the top
- `copy` objects (en / zh-Hans)
- `state` declaration
- `t()` helper
- `formatDate()`, `formatNumber()`
- `render()` — except the two line changes above
- `load()`, `saveSettings()`
- All event listeners (provider-picker, language-picker, refresh, quit)
- The `await listen("usage-updated", …)` / `await load()` bootstrap

---

## 10. App icon (Usage Meter concept)

### 10.1 What exists

The current icons live in `desktop/src-tauri/icons/`:
- `icon.png` (source, used by `tauri icons` to generate the rest)
- `icon.icns` (macOS bundle)
- `icon.ico` (Windows)
- 32×32, 128×128, 128×128@2x, etc. PNGs
- `Square*Logo.png` files for Windows

The Tauri icon pipeline: one 1024×1024 PNG master → `tauri icons` generates
all platform variants. Our current icons were generated this way.

### 10.2 What to create

Create a new 1024×1024 PNG master following the Usage Meter concept:

```
╭────────────────────────────╮
│                      ●     │  ← acid-lime dot, ~40px diameter at 1024
│                            │
│   ■■■     ■■■     □□□      │  ← three vertical meter columns
│   ■■■     ■■■     □□□      │
│   ■■■     ■■■     □□□      │     Column 1: near-black, 5/6 filled
│   ■■■     □□□     □□□      │     Column 2: electric blue, 3/6 filled
│   ■■■     □□□     □□□      │     Column 3: outlined, 1/6 filled
│                            │
│   ████████████░░░░░░░░     │  ← horizontal strip (optional)
╰────────────────────────────╯
```

Colors: warm off-white `#F3F1E9` background with subtle 20px grid.
Segments: 1px near-black borders, square corners, flat fill.
At 1024px: segments ~80×60px each, 5–6 per column, 24px column gaps.

### 10.3 Size-specific variants

Generate manually (NOT by downscaling the 1024px master):

| Size | What changes |
|---|---|
| 1024, 512 | Full: 3 columns × 5–6 segments, grid, lime dot |
| 256, 128 | 3 columns × 4 segments, thicker outlines, no grid |
| 64, 32 | 3 simplified bars (black / blue / outlined), no segments, no grid |
| 16 | 3-pixel pattern: ▮▮▯ |

The 16×16 and 16×16@2x are **menu bar template icons** — monochrome PNG,
system tints it. These go in `icons/` as `icon_16.png` etc.

### 10.4 File placement

Replace these files in `desktop/src-tauri/icons/`:
- `icon.png` (1024×1024 master — used as input to Tauri's icon generator)
- Run `npx tauri icon icon.png` from `desktop/` to regenerate all variants
- Then manually replace the tiny sizes (32, 16) with the simplified versions
- Replace `icon.icns` and `icon.ico`

The existing Tauri-generated `gen/` schemas and `capabilities/` are
**not affected** by icon changes.

### 10.5 Menu bar remains text

The macOS menu bar currently shows `CC 87%` as a text title (no icon).
This behavior is controlled by Rust in `desktop.rs` line 239:
`let _ = tray.set_icon(None);`. **Do not change this.** The menu bar meter
motif is a future design decision, not part of this spec.

---

## 11. What does NOT change

- **Rust code** — all of `src-tauri/src/`, all of `src-tauri/tests/`
- **Tauri config** — except the two numbers in `tauri.conf.json` window
  width/height (400×740)
- **Tray interaction** — click-to-open, click-again-to-close, outside-click
  dismiss (CONTEXT.md seams 8–9)
- **Data flow** — Tauri IPC, `get_app_state`, `save_settings`,
  `refresh_usage`, `quit_app`, `usage-updated` event
- **i18n data** — the `copy` objects in `app.js` are untouched
- **PRIVACY.md** — no new endpoints, no new credential access
- **CI / release workflows**

---

## 12. Execution order

1. Read `CONTEXT.md` and this entire document.
2. Read the current `desktop/ui/index.html`, `desktop/ui/styles.css`,
   `desktop/ui/app.js`, and `desktop/src-tauri/tauri.conf.json`.
3. Update `tauri.conf.json` window width→400, height→740.
4. Replace `desktop/ui/styles.css` entirely per Section 8.
5. Replace `desktop/ui/index.html` `<body>` per Section 7.
6. Edit `desktop/ui/app.js` per Section 9 (replace `providerCard`, add
   `renderTier`, update `render()`, remove deleted CSS class references).
7. Create the 1024×1024 icon master and size variants per Section 10.
   Place them in `desktop/src-tauri/icons/`.
8. Run `npx tauri icon icon.png` from `desktop/` if you have the Tauri CLI.
   Otherwise place the generated PNGs manually.
9. Full Rust test suite (backend unchanged, but verify):
   `cargo test --tests`, `cargo clippy --all-targets -- -D warnings`,
   `cargo fmt --check`
10. Build: `npm run tauri build -- --target universal-apple-darwin --bundles app`
11. Manual verification checklist (report each explicitly):
    - Panel opens on click, closes on outside click
    - Hero percentages render correctly
    - Progress bars proportional
    - Header index changes with primary provider
    - Tab bar switches active provider
    - Language toggle works
    - Refresh icon spins
    - Quit works
    - Claude card shows tier sections (Current session + per-model)
    - Dark mode toggles correctly (System Settings > Appearance)
    - Content scrolls if taller than window
    - Chinese locale renders correctly
12. Commit. Do not push unless authorized.

---

## 13. Standing constraints

- Never `git reset`, `git clean`, or `git checkout --` uncommitted changes.
- Never log or print OAuth tokens, keychain contents, account identifiers.
- Never make model API calls to test quota display.
- Do not delete the Swift implementation (`Sources/`).
- Do not push, create a remote, or publish without explicit user direction.
