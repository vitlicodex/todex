# TODEX Port and API Security Audit

Date: 2026-06-25

Scope: defensive audit of TODEX, a native macOS Swift menu bar app that monitors local Codex token usage, OpenAI Usage/Costs API data, and Codex permission risk.

## Executive Summary

TODEX does not appear to expose an inbound network surface. Static searches found no listener/server frameworks or socket accept loops, and a safe runtime smoke test found zero TCP listening sockets and zero UDP sockets owned by the TODEX process.

The largest practical risks are local, not remote:

- reports, debug logs, and UI tooltips can accidentally reveal local paths unless all export paths are consistently redacted;
- the encrypted API-key vault depends on local password strength and file-system integrity checks;
- LaunchAgent persistence must only point at a real installed app bundle;
- Codex log parsing must stay numeric-only for normal session logs and must not silently overcount, truncate, or store prompt text;
- OpenAI API cost data and local Codex token data must remain visibly separate because they describe different billing surfaces.

This audit implemented several small hardening fixes:

- redacted local source paths in JSON/Markdown reports, debug logs, and menu source summaries;
- rejected hardlinked private files before writes and API-key vault reads;
- refused to send OpenAI Authorization headers to non-HTTPS API URLs;
- wrote the LaunchAgent plist through the private file writer and rejected build-folder/symlink app bundles;
- fixed the CI bundle verification path for `TODEX.app`;
- added tests for hardlink refusal and report path redaction.

Remaining work is mostly product hardening: stricter privacy mode for project labels/API key IDs, prompt-text estimation opt-in, Developer ID signing, hardened runtime, notarization, and release checksums.

## Method

Static analysis used repository searches for:

`NWListener`, `listen`, `bind`, `socket`, `accept`, `localhost`, `127.0.0.1`, `0.0.0.0`, `WebSocket`, `Bonjour`, `NetService`, `Vapor`, `NIO`, `GCDWebServer`, `Swifter`, `XPC`, `NSXPC`, `CFMessagePort`, `mach_port`, debug servers, metrics, dashboards, local IPC, `URLSession`, `Authorization`, and API endpoints.

Safe runtime smoke test:

```sh
swift run TODEX >/tmp/todex-audit-runtime.log 2>&1 &
pgrep -x TODEX
lsof -nP -a -p "$TODEX_PID" -iTCP -sTCP:LISTEN
lsof -nP -a -p "$TODEX_PID" -iUDP
netstat -anv -p tcp
netstat -anv -p udp
```

Runtime result:

- `todex_pid=found`
- `tcp_listen_rows=0`
- `udp_socket_rows=0`
- system-wide `netstat` showed other TCP/UDP rows, but none were owned by TODEX.

## Ports and Local Listeners

Static search found no inbound listener implementation in TODEX source:

- no `NWListener`;
- no `socket`/`bind`/`listen`/`accept` server loop;
- no localhost HTTP server;
- no WebSocket server;
- no Bonjour/NetService registration;
- no Vapor/NIO/GCDWebServer/Swifter dependency;
- no XPC or message-port service.

The runtime lsof check supports the static result: TODEX owned no TCP LISTEN socket and no UDP socket during the smoke test.

Assessment: no opened ports or local network listener were found.

## Inbound and Outbound Surfaces

### Inbound

TODEX inbound surface is local-only:

- macOS menu bar UI actions;
- local file parsing from Codex logs and configured usage files;
- local LaunchAgent plist for login persistence;
- local encrypted API-key vault;
- optional opening of raw source files through Finder/default editor after warning.

No LAN, localhost, or browser-accessible listener was found.

### Outbound

OpenAI API calls are made by `OpenAIUsageClient` through `URLSession`:

- `GET /v1/organization/usage/completions`;
- `GET /v1/organization/costs`;
- `Authorization: Bearer <key>`;
- `Accept: application/json`;
- default base URL: `https://api.openai.com/v1`;
- ephemeral session configuration;
- reload ignoring local cache;
- request/resource timeouts;
- limited concurrent host connections.

Hardening implemented in this audit: `OpenAIUsageClient.requestJSON` now refuses non-HTTPS URLs before attaching or sending the Authorization header.

Remaining risks:

- redirects are not explicitly pinned to the original HTTPS host;
- 429, 5xx, timeout, and unavailable endpoint errors are still mostly generic;
- Usage/Costs pagination is implemented with bounded cursor handling;
- Costs API data can be available even when Usage API fails, so partial-failure status stays visible in UI.

## File Parsing Surfaces

Codex session parsing is designed around numeric metadata:

- normal Codex sessions are read from `.codex/sessions`;
- session JSONL is streamed in chunks rather than fully loaded;
- only lines containing `token_count`, `turn_context`, `session_meta`, or `environment_context` are parsed for Codex sessions;
- `last_token_usage` is counted instead of cumulative `total_token_usage`;
- prompt/content/message traversal is blocked for structured traversal;
- `cached_input_tokens` is preserved at sample level;
- samples include line/location in the stable ID to avoid merging same-shaped requests;
- large files, long lines, deep JSON, and sample-count truncation are bounded.

Remaining risks:

- explicit non-session files can still use prompt-like fields for estimated mode. The raw text is not stored, but it is read in memory to estimate token count. This should become explicit opt-in for privacy-sensitive users.
- parser CPU/battery cost can still be noticeable on very large files if many sources become active at once.
- reasoning tokens and reported-vs-computed totals are not fully modeled yet.

## LaunchAgent Surface

Launch at login uses:

- plist label: `local.todex`;
- path: `~/Library/LaunchAgents/local.todex.plist`;
- `ProgramArguments` with one validated executable path;
- `RunAtLoad=true`;
- stdout/stderr to `/dev/null`;
- `launchctl bootstrap/bootout`.

Hardening implemented in this audit:

- plist is written with `PrivateFileIO.writePrivateString`;
- LaunchAgents directory is created/validated as private;
- app bundle must be a real `.app` directory;
- `.build` bundles are rejected;
- executable must be inside `Contents/MacOS`;
- bundle and executable symlinks are rejected;
- legacy label cleanup remains supported.

Remaining risks:

- this is still ad-hoc/local persistence until a signed release adopts Developer ID, hardened runtime, and notarization.

## Secret Handling

API-key vault behavior:

- key is encrypted locally with AES-GCM;
- key material is derived with PBKDF2-HMAC-SHA256;
- current vault uses 600,000 iterations;
- random 32-byte salt;
- authenticated associated data on v2 vaults;
- local password required;
- macOS Touch ID or device-owner authentication required to unlock;
- private app support directory and vault file permissions;
- symlink and hardlink checks before vault read/write;
- API key redaction in debug logs;
- clipboard key is cleared only when it still matches the submitted key.

Remaining risks:

- decrypted API key exists in process memory while unlocked;
- crash dumps or process inspection by a privileged local attacker can still expose unlocked memory;
- local password quality still matters because the vault is password-derived;
- the app does not use Secure Enclave key wrapping yet.

## Token and Cost Accounting Risks

Important model distinctions:

- local Codex logs are local token-count events, not OpenAI billing records;
- OpenAI Usage API data is OpenAI Platform API usage;
- OpenAI Costs API data is OpenAI Platform API cost, not necessarily Codex desktop cost;
- local estimated costs, when added, must be labeled as estimated and kept separate from actual Costs API values.

Known accounting risks:

- `request` and visible user `prompt` are not identical concepts. Background context reloads and tool/model requests can make average tokens per request differ from user-visible prompt averages.
- `last_token_usage` should remain the only counted Codex token delta; cumulative `total_token_usage` would double count.
- cached input is now preserved, but reasoning tokens and reported-vs-computed total token fields are not fully represented.
- thresholds should be profile-based; heavy Codex automation makes small fixed daily thresholds noisy.

## UI, Reports, Exports, and Privacy

Hardening implemented:

- JSON report export redacts local paths before serialization;
- Markdown report export redacts local paths;
- menu source summary shows redacted folder/source tooltips;
- debug logger redacts API keys, Authorization headers, environment-style key names, and local paths;
- raw source opening still prompts the user first.

Remaining risks:

- project labels are derived from local project metadata and can reveal sensitive folder names;
- privacy mode should redact project labels and API key IDs everywhere, not only paths;
- help screenshots must be reviewed before release to ensure no private data is visible.

## Build and Release

Current release posture:

- native macOS menu bar app with `LSUIElement`;
- ad-hoc signing for local builds;
- empty local entitlements file;
- app bundle script builds `.build/TODEX.app`;
- CI bundle verification path now targets `.build/TODEX.app`.

Release gaps:

- no Developer ID signing;
- no hardened runtime;
- no notarization;
- no release artifact checksum/signature workflow;
- no automated secret scan in CI.

## Findings

| ID | Severity | Area | File/line | Risk | Exploit scenario | Evidence | Recommended fix | Test coverage | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| TDX-SEC-001 | Info | Ports/listeners | Static search; runtime lsof/netstat | Hidden listener could expose logs or API key over localhost/LAN. | A malicious webpage or LAN host reaches an unauthenticated local dashboard. | Static search found no listener APIs; runtime lsof for TODEX showed `tcp_listen_rows=0` and `udp_socket_rows=0`. | Keep app listener-free unless a future feature has explicit localhost auth and CSRF protection. | Safe runtime smoke test. | Verified |
| TDX-SEC-002 | Medium | Reports/exports/logs | `Sources/TokenUsageCore/TokenUsageModels.swift:101`, `Sources/TokenUsageCore/TokenUsageStore.swift:279`, `Sources/TokenUsageMenuBar/AppDebugLogger.swift:40`, `Sources/TokenUsageMenuBar/TokenUsageMenuBarApp.swift:1611` | Full local source paths could leak project names or host structure through reports/logs. | User exports a report or shares debug logs that include private local paths. | Report/log/menu redaction is now centralized through `TokenReportPrivacy`. | Keep all future exports going through `privacyRedactedForReport`; extend privacy mode to project labels. | `Report privacy redaction`. | Fixed |
| TDX-SEC-003 | Medium | Private files/vault | `Sources/TokenUsageCore/PrivateFileIO.swift:20`, `Sources/TokenUsageMenuBar/APIKeyStore.swift:266` | Hardlinked private files could redirect writes or weaken vault file integrity assumptions. | Local attacker creates a hardlink so a private write overwrites another user-owned file or vault validation accepts linked storage. | Private file writer and API-key vault now reject multiple hard links. | Keep hardlink checks before read/write; add APIKeyStore-specific integration test when UI target is testable. | `Private file hardlink refusal`. | Fixed |
| TDX-SEC-004 | Medium | OpenAI API outbound | `Sources/TokenUsageCore/OpenAIUsageClient.swift:316` | Authorization header could be sent to a non-HTTPS custom base URL if a developer/test setting changed the endpoint. | Misconfigured build points Usage API client to `http://...` and sends Bearer token in cleartext. | `requestJSON` now rejects non-HTTPS URLs before creating the Authorization request, and the default API session blocks cross-host, downgrade, and port-changing redirects. | Keep redirect policy covered by mocked/unit tests. | `OpenAI redirect policy`; build/test runner; no live API smoke test. | Fixed |
| TDX-SEC-005 | Medium | LaunchAgent | `Sources/TokenUsageMenuBar/LaunchAtLoginController.swift:46`, `Sources/TokenUsageMenuBar/LaunchAtLoginController.swift:121` | Login persistence could point at an unsafe build output or symlinked bundle. | User enables login item from a mutable build folder, then that path is replaced. | Install now rejects `.build`, validates real `.app` bundle/executable, and writes plist with private file IO. | Extract validator into a pure testable type and add symlink/build-path tests. | Build; manual code audit. | Fixed |
| TDX-SEC-006 | Low | Raw file opening | `Sources/TokenUsageMenuBar/TokenUsageMenuBarApp.swift:809`, `Sources/TokenUsageMenuBar/TokenUsageViewModel.swift:57` | Raw Codex source files can contain private prompts and paths. | User clicks "open raw file" and shares the opened file accidentally. | Main app warns before opening; legacy SwiftUI view model now warns too. | Keep warning explicit; add privacy-mode block for raw open. | Build. | Fixed |
| TDX-SEC-007 | Medium | OpenAI API errors | `Sources/TokenUsageCore/OpenAIUsageClient.swift:335` | 429, 5xx, endpoint-unavailable, and timeout errors were collapsed into generic failures. | UI shows vague warning and hides whether retry/backoff or key permission action is needed. | 401/403, 429 with `Retry-After`, 404 endpoint-unavailable, 5xx, and timeout now map to typed issues; response bodies are sanitized. | Keep typed error mapping covered by mocked tests; add permission-scope-specific copy if the API exposes a stable signal. | `OpenAI API HTTP error classification`; `OpenAI API error sanitization` | Fixed |
| TDX-SEC-008 | Medium | OpenAI API pagination | `Sources/TokenUsageCore/OpenAIUsageClient.swift:267`, `Sources/TokenUsageCore/OpenAIUsageClient.swift:316` | Missing pagination could undercount. | Usage/Costs API returns additional pages beyond the first response. | Usage and Costs pagination now follows supported cursors with duplicate, malformed, and max-page guards. | Keep max-page and partial-failure behavior covered by mocked tests. | `OpenAI Usage API pagination`; `OpenAI Costs API pagination`; `OpenAI pagination max page guard`; `OpenAI pagination partial failure` | Fixed |
| TDX-SEC-009 | Medium | Parser privacy/DoS | `Sources/TokenUsageCore/TokenUsageParser.swift:41`, `Sources/TokenUsageCore/TokenUsageParser.swift:668` | Generic estimated parsing reads prompt-like text in memory and very large files can still cost CPU. | User points TODEX at a sensitive non-session log; app reads prompt text to estimate tokens. | Codex sessions filter to token/metadata lines, but generic estimated mode uses prompt-like fields. | Make prompt-like estimated parsing explicit opt-in; reduce scan budgets; surface background parsing state. | Session prompt-skipping tests. | Planned |
| TDX-SEC-010 | Medium | Token/cost accounting | `Sources/TokenUsageCore/TokenUsageParser.swift:560`, `Sources/TokenUsageCore/TokenUsageStore.swift:250` | Misleading averages/costs can cause bad budget decisions. | User treats local Codex tokens as actual OpenAI Costs API billing or treats request average as user prompt average. | Parser counts `last_token_usage`, preserves cached input/reasoning/reported totals, and estimated local cost is modeled separately from actual Costs API values. | Keep actual-vs-estimated labels in reports and UI; continue expanding source-specific fixture coverage. | `Codex reported total and reasoning parsing`; `Usage store estimated local cost separation`; `Pricing profile cost recalculation`; `Markdown actual API cost labels` | Fixed |
| TDX-SEC-011 | Low | Privacy labels | `Sources/TokenUsageCore/TokenUsageParser.swift:753`, `Sources/TokenUsageMenuBar/TokenUsageMenuBarApp.swift:520` | Project labels can reveal sensitive folder/project names. | User shares screenshot/report that includes a private project label. | Project names are compacted, not globally redacted. | Add full privacy mode for project labels, API key IDs, and source labels. | Not covered yet. | Planned |
| TDX-SEC-012 | Info | Build/release | `Scripts/make-app-bundle.sh`, `.github/workflows/ci.yml` | Local ad-hoc app is not production-notarized. | Users download a build without macOS notarization or hardened runtime assurances. | Build uses ad-hoc signing; CI verify path now points at `TODEX.app`. | Add Developer ID signing, hardened runtime, notarization, checksums, and CI secret scanning. | CI build path fixed; local scripts tested by build pipeline. | Planned |
| TDX-SEC-013 | Low | Help WebView | `Sources/TokenUsageMenuBar/HelpWindowController.swift` | Future help links could navigate outside local bundled content. | A future Markdown change adds remote links and WebView opens them inside app context. | Help navigation now allows only bundled/local help file URLs inside the WebView, opens HTTP(S) links externally, and blocks remote image embedding. | Keep local help rendering simple and avoid remote assets. | Build; manual code audit. | Fixed |

## Build and Test Results

Results captured during this audit:

- `swift build`: passed.
- `swift run TokenUsageCoreTestRunner`: passed.
- `Scripts/test.sh`: passed.
- `Scripts/make-app-bundle.sh`: passed; produced a locally ad-hoc signed `TODEX.app` bundle.
- Safe runtime listener check: TODEX process found, zero TCP LISTEN rows, zero UDP socket rows.

Final verification should be repeated before release packaging because documentation and release scripts can change independently of core tests.

## Remaining Uncertainty

- OpenAI Usage/Costs API pagination and redirect behavior were assessed statically; no live OpenAI calls were made.
- API-key vault UI flows were inspected statically; full Touch ID automation is not covered by the CLI test runner.
- LaunchAgent install/uninstall was inspected statically; automated login-item integration tests are still needed.
- Project label sensitivity depends on user workspace naming and screenshots; privacy mode should assume labels can be sensitive.
