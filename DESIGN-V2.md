# AIUsageBar v2 — Interaction Contract + Per-Model Usage

Status: **DESIGN ONLY — do not implement from memory.** This is the spec an
executing agent follows. Read `CONTEXT.md` and `PLAN.md` first.

Supersedes `DESIGN-MODEL-BREAKDOWN.md` (delete that file — it is folded in here).

---

## Part 0 — Root cause: why the panel interaction regressed

This must be understood before touching any code, or it will regress a third time.

The Swift app fixed this in commit `334da4e` ("Close usage panel on outside
clicks"). Its commit message records the hard-won fact:

> *NSPopover transient behavior did not reliably dismiss the menu-bar panel, so
> monitor local and global mouse-down events while it is open.*

The Tauri port replaced that deliberate mechanism with a **weaker approximation**:
a single `WindowEvent::Focused(false)` handler (`desktop.rs`, in `run()`'s setup).
Worse, `show_popup` only calls `window.set_focus()` when `clicked == true`. A
hover-opened panel therefore never holds focus, so `Focused(false)` never fires,
so the panel cannot be dismissed by clicking away.

**The systemic failure:** a fix that existed only in Swift source + a commit
message was silently downgraded during the port. Nothing in `CONTEXT.md` declared
the dismissal behavior as a contract, so no reviewer or test caught the
downgrade.

**The structural remedy (mandatory, not optional):** the interaction rules below
become **numbered test seams in `CONTEXT.md`**. Section 5 of this document
specifies exactly what to add. An executing agent must add those seams in the
same commit as the code, or the work is incomplete.

---

## Part 1 — The interaction contract (non-negotiable)

These are the user's explicit requirements. Any implementation that violates one
of these is wrong, regardless of how clean the code looks.

| # | Rule | Current state |
|---|------|---------------|
| **I1** | **Hover does nothing.** Moving the pointer over the tray icon must NOT open the panel. | ❌ Violated — `TrayIconEvent::Enter` opens it |
| **I2** | **Click the tray icon to open** the panel. | ✅ Works |
| **I3** | **Click the tray icon again to close** it (toggle). | ⚠️ Fragile — see the focus-race in Part 2.3 |
| **I4** | **Click anywhere outside the panel closes it** — desktop, another app, the menu bar, the Dock. | ❌ Violated — hover-opened panels never had focus, so nothing dismisses them |
| **I5** | The panel must NOT close while the user is interacting inside it (clicking buttons, switching language/provider). | ✅ Works |

### What to DELETE (hover machinery — all of it)

Removing hover is not "disable a flag"; it is deleting a whole subsystem. Leaving
any part of it alive is how this regresses.

In `desktop/src-tauri/src/desktop.rs`:
- `TrayIconEvent::Enter { .. } => show_popup(...)` arm in `build_tray`
- `TrayIconEvent::Leave { .. } => schedule_hover_close(...)` arm in `build_tray`
- the entire `schedule_hover_close` function (the 450 ms timer)
- the `set_window_hovered` `#[tauri::command]`
- `set_window_hovered` from the `tauri::generate_handler![...]` list
- the `pointer_over_window` field on `PopupState`
- the `opened_by_click` field on `PopupState` (with hover gone, every open is a
  click; the flag is meaningless)

In `desktop/ui/app.js`:
- `document.body.addEventListener("mouseenter", ...)` → `invoke("set_window_hovered", ...)`
- `document.body.addEventListener("mouseleave", ...)` → `invoke("set_window_hovered", ...)`

After deletion, `PopupState` shrinks to only what I3 needs (see Part 2.3).

---

## Part 2 — How to implement the contract correctly

### 2.1 Open: always focus the window

`show_popup` currently focuses only on click. With hover gone, **every** open is a
click, so it must **always** focus:

```rust
fn show_popup<R: Runtime>(app: &AppHandle<R>, x: f64, y: f64) {
    // note: the `clicked: bool` parameter is deleted — every open is a click
    let Some(window) = app.get_webview_window("main") else { return; };
    position_popup(&window, x, y);
    let _ = window.show();
    let _ = window.set_focus();   // ALWAYS — this is what makes I4 work
    // ... existing is_stale refresh trigger stays unchanged ...
}
```

**Why this single line carries I4:** outside-click dismissal is implemented by the
OS taking focus away from our window and Tauri reporting `Focused(false)`. A window
that was never focused can never lose focus. This is precisely the bug.

### 2.2 Close on outside click

Keep the existing handler in `run()`'s setup — it is correct **once the window is
always focused**:

```rust
window.on_window_event(move |event| {
    if matches!(event, WindowEvent::Focused(false)) {
        hide_popup(&app_handle);
    }
});
```

**Window configuration is load-bearing.** Verify in `desktop/src-tauri/tauri.conf.json`
that the `main` window has:
- `"decorations": false`
- `"alwaysOnTop": true`
- `"skipTaskbar": true`
- `"focus": true`   ← must be true, or `set_focus()` is a no-op on some platforms
- `"visible": false` (it starts hidden; the tray shows it)

If `focus` is `false` or absent, fix it. Nothing else in this design works without it.

**Verification note for macOS:** `Focused(false)` fires when the user clicks another
app, the desktop, or the Dock. If manual testing (Part 6) shows a click on the
*menu bar itself* failing to dismiss, that is the known `NSPopover`-class gap the
Swift version hit. The fallback is a native mouse-down monitor via the `objc2`
crates already in the dependency tree, mirroring `StatusItemController.swift`'s
`addGlobalMonitorForEvents`. **Do not add that complexity preemptively** — test the
simple path first, and only reach for it if manual verification fails.

### 2.3 Close on second tray click (I3) — the focus race

This is subtle and is the one place a naive implementation breaks.

When the panel is open (and focused) and the user clicks the tray icon, macOS
delivers events in this order:

1. `WindowEvent::Focused(false)` → the existing handler runs `hide_popup` → window hidden
2. `TrayIconEvent::Click` → `toggle_popup` runs → sees `is_visible() == false` → **reopens the panel**

Net effect: the panel flickers and stays open. It can never be closed by clicking
the icon. A user experiences this as "the toggle is broken."

**Fix — a short suppression window.** Record when the panel was hidden, and have
`toggle_popup` ignore an open request that arrives immediately after a hide:

```rust
#[derive(Default)]
struct PopupState {
    /// When the panel was last hidden. Used to suppress the reopen that would
    /// otherwise follow the focus-loss → tray-click event pair, which is how a
    /// second click on the tray icon closes the panel (contract rule I3).
    hidden_at: Option<std::time::Instant>,
}

fn hide_popup<R: Runtime>(app: &AppHandle<R>) {
    if let Some(state) = app.try_state::<DesktopState>() {
        state.popup.lock().expect("popup state").hidden_at =
            Some(std::time::Instant::now());
    }
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.hide();
    }
}

fn toggle_popup<R: Runtime>(app: &AppHandle<R>, x: f64, y: f64) {
    let Some(window) = app.get_webview_window("main") else { return; };
    if window.is_visible().unwrap_or(false) {
        hide_popup(app);
        return;
    }
    // The panel is hidden. If it was hidden micro-seconds ago, this click is the
    // same gesture that dismissed it (focus loss fired first) — not a request to
    // reopen. Swallow it.
    let just_hidden = app
        .try_state::<DesktopState>()
        .and_then(|state| state.popup.lock().expect("popup state").hidden_at)
        .is_some_and(|at| at.elapsed() < std::time::Duration::from_millis(250));
    if just_hidden {
        return;
    }
    show_popup(app, x, y);
}
```

**On the 250 ms constant:** it must be long enough to cover the OS's focus-loss →
tray-click gap, and short enough that a deliberate second click (a human
double-take is ≳400 ms) still reopens the panel. Do not tune it below 150 ms or
above 400 ms without re-testing both directions manually.

---

## Part 3 — Tray display

Two defects visible in the user's screenshot (a boxed `11` glyph sitting next to
the text `C 11%`):

1. The label uses **`A`** for Claude Code. It must be **`CC`**.
2. The tray renders **both** a hand-drawn bitmap (`tray_image` — digits plus a
   progress bar) **and** a text title. They duplicate each other and look broken.
   The user wants only the clean text, rendered in the menu bar's own color.

### 3.1 Label

In `update_tray` (`desktop.rs`), the initial is chosen with an if/else. Change the
Claude arm from `"A"` to `"CC"`. **While you are there, remove the duplication:**
the same provider metadata is currently re-derived in three places (`update_tray`,
`tray_image`, and `providerCard` in `app.js`). Give `ProviderId` the metadata once,
in `lib.rs`:

```rust
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
```

Then `update_tray` calls `provider.initial()` / `provider.display_name()`. The JS
card should read the display name from the serialized view model rather than
re-deriving it (add `displayName` to `ProviderView`), so a rename can never again
disagree between tray and panel.

### 3.2 Icon: text only on macOS

macOS menu-bar items are expected to be a template image and/or a title. This app
only needs the title. On macOS, **stop drawing a bitmap** and let the title stand
alone:

```rust
// in update_tray, replacing the unconditional set_icon call
if cfg!(target_os = "macos") {
    let _ = tray.set_icon(None);          // text-only; the menu bar styles it
} else {
    let _ = tray.set_icon(Some(tray_image(remaining, provider)));  // Windows keeps the icon
}
```

Also update `build_tray`'s initial `.icon(...)`: on macOS pass a fully transparent
1×1 image (Tauri's `TrayIconBuilder` requires an icon at construction), then the
`set_icon(None)` in the first `update_tray` clears it. Keep `.icon_as_template(true)`
on macOS so that, if an icon ever is shown, the system tints it correctly for
light and dark menu bars.

**Windows keeps `tray_image`.** A Windows tray has no text title, so the drawn
bitmap is the only way to show a number there. Do not delete `tray_image` — it
becomes Windows-only. Do not "simplify" it away.

**Result on macOS:** the menu bar shows exactly `C 11%` or `CC 87%`, in the system
color, and nothing else.

---

## Part 4 — Per-model usage breakdown

### 4.1 The data is already being fetched and thrown away

The Claude OAuth usage response already carries per-model windows. `lib.rs` models
it as:

```rust
struct ClaudePayload {
    seven_day: Option<ClaudeWindow>,         // all models combined
    seven_day_sonnet: Option<ClaudeWindow>,
    seven_day_opus: Option<ClaudeWindow>,
}
```

and then `parse_claude_usage` collapses them with `.or().or()` — taking the first
non-null and **discarding the rest**. The per-model numbers the user wants (Fable,
Opus, Sonnet, …) are in the response body already. No new endpoint, no new
credential, no new network call. This is purely a parsing and rendering change,
and it therefore does not touch any boundary in `PRIVACY.md`.

### 4.2 Parse every model tier, dynamically

Do **not** add `seven_day_fable` as a fourth hardcoded field. The tier list changes
whenever Anthropic ships a model; hardcoding guarantees this breaks again. Parse
the response as a map and accept every `seven_day*` key:

```rust
/// One model tier from the Claude usage API.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelUsage {
    /// Key suffix from the API: "" for the all-models total, else "fable",
    /// "opus", "sonnet", "haiku", or a tier that did not exist when this was written.
    pub model_key: String,
    pub display_name: String,
    pub weekly: UsageWindow,
}
```

`parse_claude_usage` iterates `serde_json::Map`, keeps keys starting with
`seven_day`, strips that prefix (and a leading `_`) to get `model_key`, builds a
`UsageWindow` per tier, and sorts with the all-models total first, then the named
tiers alphabetically. A key it does not recognize gets a title-cased fallback name
(`"some_new_tier"` → `"Some New Tier"`), so **a new model appears in the UI with
zero code changes** — that is the whole point of the dynamic approach.

Malformed individual windows are skipped, not fatal: one bad tier must not blank
the whole Claude card. If **no** `seven_day*` key parses, return the existing
`UsageError::MissingWeeklyWindow`, which already routes to the last-known-good
cached snapshot.

### 4.3 Carry it to the UI

Add to `UsageSnapshot`:

```rust
/// Per-model breakdown. Empty for Codex. For Claude, entry 0 is the all-models
/// total and `weekly` above is a copy of it.
#[serde(default)]
pub models: Vec<ModelUsage>,
```

`#[serde(default)]` is what makes an existing `usage-cache.json` — written before
this field existed — still deserialize. **Do not skip it**, or every user's cache
is invalidated on upgrade and the UI blanks on first launch after update.

`ProviderView` (the Rust→JS view model in `desktop.rs`) gains `models: Vec<ModelUsage>`,
copied from the snapshot in `service.rs` (`load_codex`, `load_claude`, `initial_view`);
empty when there is no snapshot. Serde already emits camelCase, so JS reads
`provider.models[i].displayName` and `.weekly.remainingPercent`.

`app.js` renders, inside the Claude card only (i.e. when `models.length > 1`), a
divider followed by one compact row per named tier — name, remaining %, and a thin
muted progress bar. Skip the `modelKey === ""` entry: it is the total, already shown
as the card's headline number. Reuse the existing `.progress` CSS structure at a
smaller height rather than inventing a second bar component.

### 4.4 Out of scope (state this to avoid scope creep)

- The **tray** still shows only the primary provider's total. No per-model tray text.
- **Local 7-day tokens** stay a single number. Per-model local token attribution is
  a separate feature.
- **Codex** has no equivalent breakdown in its payload. `models` stays empty. The
  Codex card must render exactly as it does today.

---

## Part 5 — Encode the contract so it cannot regress (mandatory)

This is the part that prevents a fourth occurrence. **Do this in the same commit
as the code.**

### 5.1 Add to `CONTEXT.md` under "Confirmed test seams"

Append these seams (renumber to follow the existing list):

```markdown
8. The tray panel opens only on a tray-icon click. Pointer hover over the tray
   icon never opens, closes, or schedules the closing of the panel; no hover
   handling exists in the tray, the window, or the web UI.
9. Clicking the tray icon while the panel is open closes it, and a click anywhere
   outside the panel closes it. The panel is always focused when shown, because
   outside-click dismissal is implemented as focus loss; a panel that is shown
   without focus cannot be dismissed. (Regressed once during the Swift→Tauri port —
   see commit 334da4e, which added global mouse-down monitoring after
   NSPopover.transient proved unreliable.)
10. The macOS tray shows a text title only ("C 12%" / "CC 87%"); Claude Code's
    label is "CC". Windows renders the drawn tray bitmap because a Windows tray
    has no text title.
11. Claude's usage payload is parsed into every seven_day* model window it
    contains, including tiers unknown at build time, without collapsing them into
    a single window.
```

### 5.2 Automated tests (what a test can actually reach)

Add to `desktop/src-tauri/tests/`:

- **`usage_contract.rs`** — extend. A multi-tier Claude payload
  (`seven_day` + `seven_day_opus` + `seven_day_sonnet` + an invented
  `seven_day_futuremodel`) must yield: `weekly` = the all-models total (unchanged
  from today's assertions), `models.len() == 4`, entry 0 is the total, the unknown
  tier is present with a title-cased name. Also: a payload with only `seven_day`
  still produces `models.len() == 1` — this is what proves the old cache/UI path
  did not break.
- **New `tray_contract.rs`** — assert `ProviderId::Claude.initial() == "CC"` and
  `ProviderId::Codex.initial() == "C"`. Trivial, but it is what makes "A" a
  compile-and-test failure instead of a visual one nobody notices.
- **A guard test for hover removal.** The strongest available check without a
  window server: a test (or a `grep`-based CI step) asserting the strings
  `set_window_hovered`, `schedule_hover_close`, `TrayIconEvent::Enter`, and
  `pointer_over_window` do not appear in `desktop/src-tauri/src/` or `desktop/ui/`.
  This is unusual, and it is justified: the *absence* of the hover subsystem is the
  contract, and absence is exactly what a normal unit test cannot assert.

### 5.3 What remains manual

Focus loss, real tray clicks, and click-through-to-desktop cross the native window
boundary and cannot be asserted in `cargo test`. They stay on the packaged-app
checklist in Part 6 — which is why Part 6 is not optional.

---

## Part 6 — Execution order (for the implementing agent)

Work top to bottom. Each step's gate must pass before the next.

1. **Read** `CONTEXT.md`, `PLAN.md`, `PRIVACY.md`, and this document. Then read
   `desktop/src-tauri/src/desktop.rs` end to end — the tray, popup, and window
   event code is one interacting system and cannot be edited hunk-wise.
2. **Delete the hover subsystem** (Part 1 list). Compile. `cargo clippy --all-targets
   -- -D warnings` will surface anything left dangling — that is the point of doing
   the deletion as its own step.
3. **Rewrite open/close** per Part 2: `show_popup` always focuses; `PopupState`
   holds only `hidden_at`; `toggle_popup` gets the 250 ms suppression guard.
4. **Tray label and icon** per Part 3: `ProviderId::initial()` / `display_name()`
   in `lib.rs`; `update_tray` uses them; macOS text-only, Windows keeps `tray_image`.
5. **Add the tests from 5.2 and the seams from 5.1 first** for the model breakdown
   — the multi-tier test must FAIL against the current parser. That failure is the
   TDD gate; do not write the parser until you have seen it fail.
6. **Implement the model breakdown** per Part 4: `ModelUsage`, dynamic
   `parse_claude_usage`, `UsageSnapshot.models` with `#[serde(default)]`,
   `ProviderView.models`, `service.rs` wiring, `app.js` rows, `styles.css`.
7. **Full local checks:** `cargo test --tests`, `cargo clippy --all-targets -- -D
   warnings`, `cargo fmt --check`, and the legacy `swift run AIUsageBarCoreTests`.
8. **Build the packaged app** — interaction cannot be verified in `tauri dev`:
   `npm run tauri build -- --target universal-apple-darwin --bundles app`
9. **Manual verification in the packaged app.** Every line must pass; report each
   one explicitly rather than summarizing as "works":
   - Hover the tray icon, do not click → panel does **not** appear.
   - Click the tray icon → panel appears.
   - Click the tray icon again → panel closes (and stays closed — no flicker-reopen).
   - With the panel open, click the desktop → closes.
   - With the panel open, click another app's window → closes.
   - With the panel open, click the menu bar → closes. *(If this one fails, that is
     the known gap in Part 2.2 — report it; do not silently ship it.)*
   - With the panel open, click the language toggle and the provider toggle → panel
     stays open, settings apply and persist across a relaunch.
   - macOS menu bar reads `C 11%` / `CC 87%` — the `CC` label, no boxed digit glyph
     beside it.
   - The Claude card lists per-model rows (Fable / Opus / Sonnet / …) whose values
     match the Claude Code usage screen; the Codex card is unchanged.
10. **Then** `/code-review`, fix findings, re-run step 7, commit. Do not push.

## Part 7 — Standing constraints

- Uncommitted working-tree changes are intentional user work: never `git reset`,
  `git clean`, or `git checkout --` them.
- Never log or print OAuth tokens, keychain contents, account identifiers, prompts,
  or responses.
- Never make model API calls to test the quota display — quota HTTP only.
- Do not delete the Swift implementation under `Sources/`; it is the behavioral
  reference and its regression suite still runs.
- Do not choose a license, create a remote, push, or publish without explicit user
  direction.
