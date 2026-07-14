# AIUsageBar — Architecture & Execution Plan

Status date: 2026-07-13. Written by the planning agent; execution agents should
follow this document phase by phase. Read `CONTEXT.md`, `README.md`,
`PRIVACY.md`, and `RELEASING.md` before starting any phase.

---

## Part 1 — Architecture

### 1.1 Two implementations, one repo

| | Legacy | Target |
|---|---|---|
| Location | `Sources/` (committed, `8f17733`) | `desktop/` (intentionally uncommitted) |
| Stack | Swift / AppKit, macOS only | Tauri 2 + Rust core + static HTML/CSS/JS |
| Role | Stable fallback + regression suite (`swift run AIUsageBarCoreTests`) | The product going forward |

The Swift implementation must not be deleted until the user has validated the
Tauri version. The Swift regression suite stays in the verification loop
because it encodes the historical Claude rate-limit and Keychain fixes.

### 1.2 Layering of the Tauri implementation (`desktop/`)

```
┌─────────────────────────────────────────────────────┐
│ ui/  (index.html, app.js, styles.css)               │
│  panel rendering, zh/en strings, settings controls  │
├──────────────── Tauri IPC (commands/events) ────────┤
│ src-tauri/src/desktop.rs — desktop shell            │
│  AppSettings persistence (language, primary),       │
│  tray title (macOS) / dynamic tray icon (Windows),  │
│  popup lifecycle: click, hover, delayed leave,      │
│  focus-loss / outside-click dismissal               │
├─────────────────────────────────────────────────────┤
│ src-tauri/src/service.rs — orchestration            │
│  UsageService: refresh scheduling, coalescing,      │
│  Claude 5-minute throttle, Retry-After parsing,     │
│  persisted backoff + last-known-good snapshots      │
│  (PersistentCache, credential-free), Keychain       │
│  read-at-most-once state, AppPaths                  │
├─────────────────────────────────────────────────────┤
│ src-tauri/src/lib.rs — pure core (no network)       │
│  UsageSnapshot / UsageWindow / ProviderCache types, │
│  Codex & Claude payload parsers (isolated — the     │
│  upstream endpoints are undocumented),              │
│  credential-file readers (Codex auth.json, Claude   │
│  credentials file), local JSONL token scanners      │
└─────────────────────────────────────────────────────┘
```

Contract tests in `src-tauri/tests/` map 1:1 to the seams in `CONTEXT.md`:
`usage_contract.rs`, `local_tokens_contract.rs`, `credentials_contract.rs`,
`cache_contract.rs`. New behavior lands with a contract test first (TDD).

### 1.3 Load-bearing design decisions (do not regress)

1. **Parsing isolation.** Provider quota endpoints are not stable public APIs.
   All payload interpretation stays in `lib.rs` parser functions so an upstream
   change is a one-module fix.
2. **Last-known-good over blanking.** Rate limits, network failures, and
   payload changes must degrade to the cached snapshot, never to an empty UI.
   Snapshots expire at provider reset time (or 24h fallback).
3. **Credential reuse, never credential entry.** The app reads existing Codex
   auth files and Claude OS-keyring/credential files. No paste-a-key flow.
   Keychain is read at most once per session. The persisted cache never
   contains credentials.
4. **Quota HTTP only.** Refreshing calls usage/quota endpoints; it never makes
   model requests and never consumes provider tokens.
5. **Local logs are counted, not read.** JSONL scanning extracts token totals
   without decoding, retaining, or transmitting prompt content.

### 1.4 Known architectural defect (fix first)

`jsonl_lines()` in `lib.rs` collects every line of every log file into
`Vec<Vec<u8>>`. A hostile or huge JSONL line grows memory without bound.
Target shape: a streaming, per-file bounded line reader with a maximum line
length (oversized lines are skipped, not buffered), driven by a regression
test. This changes `scan_codex_tokens` / `scan_claude_tokens` internals only;
the public signatures and contract-test expectations stay.

---

## Part 2 — Execution plan

Phases are ordered by dependency. Each has acceptance criteria; a phase is not
done until they pass. Phases 5 and 8 are gated on user decisions — stop and
ask, do not improvise.

### Phase 1 — Bounded JSONL scanner (TDD)

- Write a failing regression test in `local_tokens_contract.rs`: a log file
  containing an oversized line (e.g. tens of MB) must scan with bounded memory
  and must not corrupt the token total from surrounding valid lines.
- Replace `jsonl_lines()`'s collect-everything approach with a streaming
  bounded reader; cap line length; skip (don't buffer) oversized lines.
- Acceptance: new test passes; all existing contract tests pass;
  `cargo clippy --all-targets -- -D warnings` and `cargo fmt --check` clean.

### Phase 2 — Full local re-verification

Run from the repo root unless noted:

```bash
git diff --check
cd desktop/src-tauri
cargo test --tests
cargo clippy --all-targets -- -D warnings
cargo fmt --check
cd "$HOME/Hailey-Agent-Projects/AIUsageBar"
swift run AIUsageBarCoreTests          # legacy regression suite
cd desktop
npm run tauri build -- --target universal-apple-darwin --bundles app
```

- The existing Universal build predates a test-only launch-env addition —
  rebuild it after Phase 1 code is final.
- Acceptance: everything above passes; fresh Universal `.app` exists.

### Phase 3 — macOS packaged-app interaction verification

Use the freshly built Universal app. Test-only env vars available:
`AIUSAGEBAR_DISABLE_KEYCHAIN=1` (skip Claude Keychain),
`AIUSAGEBAR_SHOW_ON_LAUNCH=1` (open panel immediately).

Verify in the packaged app (not `tauri dev` — these cross native window
boundaries):

- [ ] Click tray opens panel; click anywhere outside closes it.
- [ ] Hover opens; delayed leave closes.
- [ ] Chinese ↔ English switch takes effect and persists across relaunch.
- [ ] Primary-provider switch changes the tray indicator and persists.
- Acceptance: all four confirmed in the packaged app, with a screenshot or
  explicit pass note per item.

### Phase 4 — Real Claude credential reuse (final binary only)

Do this once, on the final binary, so rebuilds don't repeatedly invalidate
macOS Keychain authorization.

- [ ] Real Claude remaining % and reset time render and match the account.
- [ ] Automatic refresh works; Claude requests observe the 5-minute throttle.
- [ ] During a real or simulated 429, the UI keeps the cached snapshot
      (no blanking) and honors `Retry-After`.
- [ ] No repeated Keychain password prompts across refreshes.
- Hard rule: never print credential files, tokens, or account identifiers.
- Acceptance: all four confirmed; Codex values also still correct.

### Phase 5 — Windows verification  ⛔ blocked on user

No Windows machine or CI has run yet, and this repo has **no Git remote**.
Windows CI verification therefore requires the user to first authorize
creating a (private) GitHub repository and pushing (see Phase 8 gate), or to
provide a Windows 10/11 machine. When unblocked, verify:

- x64 compilation and installer build (via `release.yml`/`ci.yml` or locally).
- Native credential discovery (native home paths; WSL is out of scope).
- Tray icon legibility, hover/click, outside-click dismissal.
- Chinese locale rendering; both providers' data.

### Phase 6 — Release workflow review

- Review `.github/workflows/ci.yml` and `release.yml`: Tauri Action usage,
  matrix targets, and the optional macOS/Windows signing branches.
- Reality on this machine: no Apple Developer ID identity, `gh` not
  authenticated, no remote. Unsigned beta artifacts are acceptable;
  Gatekeeper/SmartScreen warnings are expected and should be documented in the
  release notes draft.
- Acceptance: workflows reviewed, findings fixed, YAML parses.

### Phase 7 — Two-axis code review, then commit

- Run a code review on two axes: (a) repository standards, (b) the
  non-negotiable product requirements in the handoff/`README.md`.
- Fix findings, re-run Phase 2 checks.
- Make one intentional commit of the `desktop/` implementation and docs.
  Never commit `desktop/src-tauri/target/` (several GB) or
  `desktop/node_modules/` — both are gitignored; keep them so.
- Acceptance: clean review, green checks, single well-messaged local commit.
  **Do not push.**

### Phase 8 — User decision gate  ⛔ ask the user

Collect explicit decisions before acting on any of these:

1. License choice (`RELEASING.md` leaves it open; MIT is the simple default,
   but it's the user's call).
2. Create the GitHub repository (public/private) and push.
3. Authenticate `gh`; run Windows CI (unblocks Phase 5).
4. Publish the GitHub Releases beta (unsigned artifacts).

### Standing rules for every executing agent

- Every current uncommitted change is intentional user work: never
  `git reset`, `git clean`, `git checkout --`, or overwrite it.
- Never log or print OAuth tokens, API keys, Keychain contents, account IDs,
  prompts, or responses.
- Never make model API calls to test quota display.
- Don't delete `Sources/` (Swift) until the user validates the Tauri app.
- Don't choose a license, create a remote, push, or publish without explicit
  user direction.
