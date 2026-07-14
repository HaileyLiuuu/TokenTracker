# TokenTracker v4 — Panel Size Fix + TokenTracker Rename

**Status: EXECUTABLE SPEC. Read CONTEXT.md first.**

## 0. Four issues to fix

| # | Issue | Root cause |
|---|---|---|
| 1 | Panel too large | Window is 400×680px. For a macOS menu bar popover, standard is ~340×520. The extra height makes it feel bloated. |
| 2 | Font/component sizes wrong for panel width | When we narrowed from 400→340px, the 42px headline and 64px hero % will overflow. Everything must scale proportionally to the new width. |
| 3 | Claude card "Current session" missing | The `renderTier` JS logic is correct (it checks `if (!w) return ""`). The data IS populated from `parse_claude_usage` → `session`. The issue is: (a) the `provider.session` field is separate from the card header display, and (b) the tier section for session may be masked by an empty `models` array or a DOM layout issue. The execution must verify that after a fresh fetch, `provider.session` is non-null in Claude cards. |
| 4 | App called "AIUsageBar" everywhere — rename to TokenTracker | Name is in HTML title, Cargo.toml, tauri.conf.json, README, tray tooltip, and i18n strings. |

## 1. Panel size: 340 × 520

A macOS menu bar popover should be compact. Standard reference sizes:
- macOS Wi-Fi popover: ~350×400
- macOS Bluetooth popover: ~330×350
- macOS Battery popover: ~340×280

For TokenTracker with two stacked provider panels + tabs + footer:
- **Width: 340px** (fits editorial typography without cramping)
- **Height: 520px** (enough for header + tabs + codex panel + claude panel + footer; overflow scrolls)

Edit `desktop/src-tauri/tauri.conf.json`:
```json
"width": 340,
"height": 520
```

The `.cards { overflow-y: auto }` already handles content taller than 520px. Users scroll to see the full Claude panel with tier rows.

## 2. Typography and component sizing (scaled to 340px panel)

Panel content area: 340px - 2px border = 338px internal.
With 16px horizontal padding: ~306px content width.
With 20px horizontal padding: ~298px content width.

### All sizes — compare before and after

| Element | Before (400px panel) | After (340px panel) |
|---|---|---|
| Header padding | 20px sides, 24px bottom | 16px sides, 18px bottom |
| `USAGE` headline | 42px | 32px |
| Subtitle | 10px | 9px |
| Tab height | 40px | 36px |
| Tab font | 11px | 10px |
| Panel padding | 18px | 14px |
| Badge size | 40×40 | 34×34 |
| Badge font | 15px | 13px |
| Provider name | 12px | 11px |
| Hero % | 64px | 48px |
| Meta value | 20px | 16px |
| Meta label | 10px | 9px |
| Progress bar height | 20px | 16px |
| Progress labels | 10px | 9px |
| Tier heading | 11px | 10px |
| Tier value | 15px | 13px |
| Tier value-sm | 13px | 11px |
| Tier label | 10px | 9px |
| Tier progress height | 5px | 4px |
| Tier section gap | 12px | 10px |
| Footer padding | 14px 6px | 10px 4px |
| Footer label | 9px | 8px |
| Footer button font | 9px | 8px |
| Refresh/quit icon | 18px | 15px |
| Provider note | 11px | 10px |
| Hero grid gap | 6px 12px | 5px 10px |
| Hero grid margin-bottom | 16px | 12px |
| Identity margin-bottom | 16px | 12px |
| 0%/50%/100% labels | 10px | 9px |

### CSS variable approach (replace all hardcoded sizes)

The sizes above are binding. The executing agent must replace every `px` value in `styles.css` that changed. The color system (Section 2 of DESIGN-V3.md) remains identical.

## 3. Claude three-tier display

The data path IS correct. Both `load_claude` and `initial_view` copy `snapshot.session` into `ProviderView.session`. The JS `renderTier` renders it when non-null.

But there's a verification step the executing agent must do:

**After building, verify:**
```bash
python3 -c "
import json
c = json.load(open('$HOME/Library/Application Support/com.haileyliu.aiusagebar/usage-cache.json'))
s = c.get('claude', {}).get('snapshot')
if s:
    ses = s.get('session')
    print(f'session in cache: {ses}')
    print(f'models: {len(s.get(\"models\",[]))} entries')
else:
    print('No claude snapshot — wait for first fetch')
"
```

If `session` is `None` in the cache, the parser didn't capture `five_hour` — check `parse_claude_usage` in `lib.rs` (lines ~379-392). If `session` exists in cache but doesn't show in the panel, check:
1. `ProviderView.session` is populated in `load_claude` (service.rs ~212)
2. `renderTier(t("currentSession"), provider.session, ...)` is called (app.js ~72)
3. `provider.session` is not null in the rendered `state.providers[]`

The Claude card layout should render:
```
┌─ Provider panel (coral bg) ─────────────┐
│ [CC] CLAUDE CODE                   02 ↗  │
│ 86%              RESETS Jul 17, 2026    │
│ REMAINING        LOCAL 7-DAY TOKENS     │
│                  54,539,533             │
│ [████████████████████░░░░]              │
│ 0%              50%             100%    │
│ ─────────────────────────────────────── │ ← tier divider
│ Current session              93%        │
│ Resets  2:19 PM               12,450    │
│ ─────────────────────────────────────── │
│ Fable                         76%        │
│ Resets  Jul 17, 2026          12,450    │
│ ◈ Provider data  Updated 10:15 AM       │
└──────────────────────────────────────────┘
```

For the **Codex** card, NO tier sections appear (Codex has no session/per-model breakdown).

### Key JS assertion

After `load()` returns in app.js, `state.providers[1]` (Claude) should have:
- `state.providers[1].session` — non-null `{ remainingPercent, resetAt, ... }`
- `state.providers[1].models` — array with at least `[{ modelKey: "", ... }, { modelKey: "fable", ... }]`

If either is falsy after a fresh fetch, the parser or service wiring is broken.

## 4. Rename to TokenTracker

Only surface-level strings change. No Rust type renames, no file renames, no bundle ID change.

### Files to edit

**desktop/ui/index.html** — line 6:
```html
<title>TokenTracker</title>
```

**desktop/src-tauri/tauri.conf.json**:
```json
"productName": "TokenTracker",
"title": "TokenTracker",
```

**desktop/src-tauri/Cargo.toml**:
```toml
name = "TokenTracker"
```

(And update the `[[bin]]` name if there is one)

**desktop/package.json**:
```json
"name": "token-tracker",
"productName": "TokenTracker",
```

**desktop/ui/app.js** — i18n strings (lines 9, 17):
```js
quit: "Quit TokenTracker",
// 中文:
quit: "退出 TokenTracker",
```

**desktop/src-tauri/src/desktop.rs** — tray tooltip line ~380:
```rust
let _ = tray.set_tooltip(Some(format!("{}: {value}% remaining", provider.display_name())));
```
This already uses `provider.display_name()` which returns "Codex" / "Claude Code" — no change needed here. But the initial tooltip at line ~208 says `"AIUsageBar"`:
```rust
.tooltip("AIUsageBar")
```
Change to:
```rust
.tooltip("TokenTracker")
```

**README.md** — replace "AIUsageBar" → "TokenTracker" throughout.

### Files NOT to rename
- Bundle identifier `com.haileyliu.aiusagebar` stays (changing it would invalidate the Keychain authorization).
- Rust module names, test names, file names stay.
- Git repo name stays (that's a separate `git remote` operation).

## 5. Execution order

1. Read `CONTEXT.md` and this document.
2. Read the current `styles.css`, `app.js`, `index.html`, `tauri.conf.json`.
3. Replace `tauri.conf.json` window size: 340×520.
4. Rewrite `styles.css` with ALL the scaled sizes from the table in Section 2.
   This is a find-and-replace job: every `px` value changes. Do not change the
   color system or structure — only sizes.
5. Update `index.html` title: "TokenTracker".
6. Update `tauri.conf.json` productName and title: "TokenTracker".
7. Update `Cargo.toml` name.
8. Update `package.json` name/productName.
9. Update `desktop.rs` tray tooltip from "AIUsageBar" → "TokenTracker".
10. Update `app.js` i18n quit strings.
11. Run `cargo test --tests`, `cargo clippy --all-targets -- -D warnings`,
    `cargo fmt --check`.
12. Build: `npm run tauri build -- --target universal-apple-darwin --bundles app`.
13. **Clear the old cache** so session data is captured fresh:
    `rm -f "$HOME/Library/Application Support/com.haileyliu.aiusagebar/usage-cache.json"`
14. Launch the app. Wait 10s for first fetch.
15. Verify: Claude card shows three sections (main card + Current session + per-model tiers).
    Panel doesn't overflow at 340×520. Content scrolls if needed.
16. Commit. Do not push.

## 6. Standing constraints

- Never `git reset`, `git clean`, `git checkout --`.
- Never log or print OAuth tokens, keychain contents, account identifiers.
- Never make model API calls to test quota display.
- Do not delete the Swift implementation (`Sources/`).
- Do not push without explicit user direction.

---

## 7. App Icon (Usage Meter — already generated, just verify)

The app icon has been redesigned and placed in `desktop/src-tauri/icons/`.
It follows the Usage Meter concept from the Claude Design project
`AI Coding Usage Monitor` — three vertical meter columns (near-black /
electric-blue / acid-lime) on a warm off-white squircle with editorial grid.

### 7.1 What was generated (already done)

| File | Size | Description |
|---|---|---|
| `icon.png` | 1024×1024 | Master: 6 segments/column, 64px grid, lime dot |
| `128x128@2x.png` | 512×512 | Master at 512px |
| `128x128.png` | 256×256 | Master without grid |
| `64x64.png` | 128×128 | Medium: 3×3 segments, thicker strokes |
| `32x32.png` | 64×64 | Medium at 64px |
| `icon.icns` | — | Regenerated from .iconset |

The old icons are backed up at `desktop/src-tauri/icons-old/` (do not delete them,
but do not reference them from the build).

### 7.2 What the executing agent must verify

- Run the build. The app bundle should show the new Usage Meter icon in Finder,
  the Dock, and Launchpad.
- If the old icon appears instead: check that `tauri.conf.json` `bundle.icon`
  is not explicitly set (Tauri auto-discovers `icons/icon.png`).
- The **menu bar** still shows text (`CC 87%`, `C 11%`) — do not change this.
  The tray uses `tray.set_icon(None)` on macOS per CONTEXT.md seam 10.

### 7.3 To regenerate the icon set in future

Run the Python script that generated the PNGs (saved as part of the project):

```bash
# Script is in desktop/src-tauri/icons-new/ — the generation logic is in the
# shell history. To regenerate: re-run the Python script in this commit's log.
```

Or use the SVG source at `icons-new/icon-master.svg` and convert via `rsvg-convert`.
