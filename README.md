# AIUsageBar

AIUsageBar is a compact menu-bar and system-tray utility for real Codex and Claude Code weekly usage.

## What users get

- A compact remaining-usage progress indicator and percentage in the macOS menu bar or Windows system tray.
- A click or hover panel showing Codex and Claude Code remaining percentage, reset time, and local seven-day tokens.
- A selectable primary provider and Chinese/English interface.
- Automatic refresh with Claude request coalescing, five-minute throttling, `Retry-After` support, and last-known-good data during rate limits.

## Supported systems

- macOS 13 or later, Apple Silicon and Intel (Universal build).
- Windows 10 or 11, x64.

Users need to be signed in to Codex or Claude Code on the same computer for that provider's account quota to appear. One provider can be unavailable while the other remains fully usable. On macOS, the first Claude Code read may show one Keychain authorization prompt; choose **Always Allow** so automatic refresh does not ask again.

AIUsageBar does not make model requests and does not consume Codex or Claude tokens. See [PRIVACY.md](PRIVACY.md) for exactly what it reads, sends, and stores.

## Data sources

- **Codex quota:** reuses the existing Codex login and requests the same weekly-usage backend used by the Codex Usage screen.
- **Claude Code quota:** reuses the existing Claude Code OAuth login and requests Claude Code's usage endpoint.
- **Local tokens:** scans token-count fields in local Codex and Claude Code JSONL logs. This is explicitly a local seven-day total, not an account-wide cross-device total.

Provider usage endpoints can change because they are not documented as stable third-party APIs. The parser and live integration test isolate that maintenance risk.

## Install from GitHub Releases

After the first signed release:

1. Download the macOS `.dmg` or Windows installer from Releases.
2. Install and launch AIUsageBar.
3. Authorize Claude Code credential access once if the operating system asks.
4. Select the primary provider and language in the panel.

No API keys or usage limits need to be entered manually.

## Build the cross-platform app

Requirements: Node.js 22+, Rust stable, and the platform prerequisites documented by Tauri 2.

```bash
cd desktop
npm install
npm run tauri dev
```

Cross-platform core tests:

```bash
cd desktop/src-tauri
cargo test --tests
```

The previous Swift/AppKit macOS implementation remains in `Sources/` while the Tauri version is validated by users. Its regression suite is:

```bash
swift run AIUsageBarCoreTests
```

Release signing and GitHub Actions secrets are documented in [RELEASING.md](RELEASING.md).
