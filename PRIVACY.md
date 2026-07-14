# Privacy

TokenTracker is a local desktop utility. It has no analytics, advertising, telemetry, user account, or AI model of its own.

## Data read on the device

- Codex sign-in state from the user's existing `CODEX_HOME` or `.codex/auth.json`.
- Claude Code sign-in state from the operating-system credential store, with `.claude/.credentials.json` as a supported fallback.
- Codex and Claude Code local JSONL session logs, only to add token-count fields inside the current weekly window.

TokenTracker does not inspect, retain, display, or transmit prompt and response text.

## Network requests

- Codex credentials are sent only to `chatgpt.com` to request the same weekly-usage data used by the Codex Usage screen.
- Claude Code credentials are sent only to `api.anthropic.com` to request Claude Code usage data.

No credential or usage data is sent to the project maintainer or any third-party analytics service.

## Data stored by TokenTracker

The app stores language and primary-provider settings. It also stores the last successful normalized usage snapshot and provider-request backoff time so a temporary rate limit does not blank the panel. Stored snapshots contain percentages, reset time, and update time; they do not contain access tokens, refresh tokens, account IDs, prompts, responses, or local token totals.

Removing TokenTracker's application-data directory clears these settings and snapshots. It does not modify Codex or Claude Code credentials.
