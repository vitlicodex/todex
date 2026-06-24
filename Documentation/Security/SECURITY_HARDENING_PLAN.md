# TODEX Security Hardening Plan

Date: 2026-06-25

This plan follows the defensive audit in `PORT_AND_API_SECURITY_AUDIT.md`. It separates completed hardening from release-blocking and post-release work.

## Principles

- Local-first by default: no telemetry, no prompt storage, no local network listener.
- Secrets never leave the local machine except as an explicit OpenAI API Authorization header to an HTTPS OpenAI endpoint.
- Reports and exports contain numeric usage data and technical metadata only.
- Actual OpenAI Costs API values must never be blended with estimated local Codex costs.
- Permission controls must be honest about whether they only monitor risk or also mutate Codex config.

## P0 Completed in This Audit

| Item | Status | Evidence | Test plan |
| --- | --- | --- | --- |
| Redact local paths in JSON/Markdown reports | Done | `TokenReportPrivacy`, `TokenUsageStore.saveReportJSON`, menu worker report export | `Report privacy redaction` |
| Redact paths and API keys in debug logs | Done | `AppDebugLogger.redact` | Covered by build; add dedicated log-redaction tests in P1 |
| Reject hardlinked private files | Done | `PrivateFileIO.validateOwnerAndMode`, `APIKeyStore.validatePrivateFile` | `Private file hardlink refusal` |
| Refuse non-HTTPS OpenAI API URLs before Authorization | Done | `OpenAIUsageClient.requestJSON` | Covered by build; add mock URLProtocol tests in P1 |
| Harden LaunchAgent plist writes and bundle validation | Done | `LaunchAtLoginController.install`, `validatedAppExecutablePath` | Covered by build; add pure validator tests in P1 |
| Fix CI bundle verification path | Done | `.github/workflows/ci.yml` verifies `.build/TODEX.app` | CI |

## P1 Release-Blocking Hardening

### 1. OpenAI API Transport Controls

Problem:

- `URLSession` default redirect handling is not explicitly constrained.
- 429, 5xx, timeout, and endpoint-unavailable errors are generic.
- Usage/Costs pagination is not implemented.

Plan:

- Introduce a small `OpenAIUsageTransport` abstraction so tests can inject responses without live API calls.
- Add redirect delegate logic:
  - allow only HTTPS;
  - allow only same host as configured base URL;
  - never forward Authorization to a different host.
- Add typed issues:
  - `apiRateLimited(retryAfter:)`;
  - `apiServerError(status:)`;
  - `apiEndpointUnavailable`;
  - `apiTimeout`;
  - `apiPermissionScopeMissing`.
- Implement pagination for Usage and Costs responses if `next_page`, `has_more`, or cursor fields are present.

Tests:

- mock non-HTTPS URL refuses before request creation;
- mock cross-host redirect is blocked;
- mock same-host HTTPS redirect preserves behavior;
- 429 parses `Retry-After`;
- 500 maps to server error;
- paginated Usage/Costs buckets merge correctly.

### 2. Full Privacy Mode

Problem:

- Path redaction is now centralized, but project names and API key IDs can still reveal sensitive metadata.

Plan:

- Extend `MonitorSettings.privacyMode` to redact:
  - project labels;
  - API key IDs;
  - source filenames if strict mode is enabled;
  - report issue details;
  - menu tooltips.
- Add `PrivacyLevel`:
  - `off`;
  - `redactPaths`;
  - `strict`.
- In strict mode, show stable hashed aliases:
  - `Project 8F3A`;
  - `API key 19C2`;
  - `Source 4A91`.

Tests:

- UI display model contains no private project label in strict mode;
- JSON report contains no full paths, project names, or API key IDs;
- Markdown report contains no full paths, project names, or API key IDs.

### 3. Parser Estimated Mode Opt-In

Problem:

- Normal Codex session parsing avoids prompt lines, but generic estimated mode can read prompt-like text in memory for explicit non-session sources.

Plan:

- Add a setting: `allowPromptTextEstimation`.
- Default it to `false`.
- When disabled, only parse numeric token fields and Codex `token_count` events.
- If enabled, show a clear local-only warning:
  - prompt text is read in memory;
  - prompt text is not stored;
  - reports still contain only numeric statistics.

Tests:

- prompt-like JSON produces no estimated sample by default;
- prompt-like JSON produces estimated sample only when opt-in is true;
- exported reports never include prompt text.

### 4. LaunchAgent Validator Tests

Problem:

- LaunchAgent validation currently depends on `Bundle.main`, which makes edge cases hard to test.

Plan:

- Extract a pure `LaunchAgentBundleValidator`.
- Inputs:
  - bundle URL;
  - executable URL;
  - allowed install roots.
- Validate:
  - real `.app` directory;
  - no `.build`;
  - no symlink bundle/executable;
  - executable inside `Contents/MacOS`;
  - owner and mode are acceptable.

Tests:

- rejects `.build/TODEX.app`;
- rejects symlinked app bundle;
- rejects symlinked executable;
- rejects executable outside bundle;
- accepts installed app-shaped temp fixture.

## P2 Accounting and Cost Correctness

### 5. Token Schema Fidelity

Problem:

- Cached input is tracked, but reasoning tokens and reported-vs-computed totals are not first-class fields.

Plan:

Extend `TokenUsageSample`:

```swift
public var inputTokens: Int
public var cachedInputTokens: Int
public var outputTokens: Int
public var reasoningTokens: Int
public var reportedTotalTokens: Int?
public var computedTotalTokens: Int {
    inputTokens + cachedInputTokens + outputTokens + reasoningTokens
}
```

Compatibility:

- keep existing JSON decode defaults;
- migrate old samples with `cachedInputTokens=0`, `reasoningTokens=0`, `reportedTotalTokens=nil`;
- keep UI labels explicit:
  - input;
  - cached input;
  - output;
  - reasoning;
  - reported total when available.

Tests:

- old state decodes;
- Codex `last_token_usage` with cached input is preserved;
- OpenAI-style response with reasoning tokens is preserved;
- reported total mismatch is surfaced as an issue, not silently hidden.

### 6. Estimated Local Codex Cost

Problem:

- Local Codex logs can show real local token counts, but OpenAI Costs API may not expose Codex desktop cost. Showing `n/a` is honest but incomplete for planning.

Plan:

- Add `TokenPricingProfile`:
  - name;
  - input per 1M;
  - cached input per 1M;
  - output per 1M;
  - reasoning per 1M;
  - multiplier.
- Add `CostEstimator`:
  - computes local estimated cost from local samples;
  - never labels estimated cost as actual;
  - stores selected pricing profile locally.
- UI:
  - `Actual API cost`: OpenAI Costs API only;
  - `Estimated local Codex cost`: local logs x pricing profile;
  - source label next to both.

Tests:

- cached input uses cached price;
- output uses output price;
- multiplier applies last;
- actual Costs API and estimated local cost never merge into one number.

### 7. Request vs Prompt Semantics

Problem:

- A model request is not necessarily a visible user prompt. Codex can spend tokens on background context reloads, tool calls, or retries.

Plan:

- Rename UI labels:
  - `Requests` for model/API requests;
  - `Visible prompts` only if explicitly counted from UI/session metadata;
  - `Avg/request`, not `average tokens per prompt`, unless prompt-level data is real.
- Store:
  - `requestCount`;
  - `visiblePromptCount` when available;
  - `backgroundRequestCount` when detectable.

Tests:

- average request calculation uses requests;
- prompt average is hidden when prompt count is unknown;
- UI snapshot model has no contradictory labels.

## P3 Parser and Performance Hardening

### 8. Incremental and Budgeted Parsing

Problem:

- Large files are bounded, but scanning many large files can still affect battery and startup responsiveness.

Plan:

- Keep per-source cursors and parse only appended bytes whenever possible.
- Add per-cycle CPU budget:
  - stop after N ms;
  - continue next refresh;
  - surface "catching up" status.
- Use background QoS for parsing and avoid main-thread file IO.
- Add backoff when files are unchanged.

Tests:

- appended JSONL is parsed from cursor;
- truncated/rotated source resets cursor safely;
- parse cycle respects sample/time budget;
- UI remains responsive in synthetic large-log test.

### 9. Source File Symlink Policy

Problem:

- Private write paths reject symlinks, but discovered read sources should also avoid surprising link traversal.

Plan:

- For default Codex source discovery:
  - reject symlinked session files by default;
  - optionally allow symlinks in advanced mode;
  - redacted issue if a symlink source is skipped.

Tests:

- symlinked session file skipped by default;
- advanced allowlist parses it;
- report issue redacts path.

## P4 Release Engineering

### 10. Signed Production Builds

Problem:

- Current app bundle is suitable for local development, not a polished public release.

Plan:

- Add Developer ID signing config.
- Enable hardened runtime.
- Notarize release artifacts.
- Generate SHA-256 checksums.
- Attach artifacts to GitHub Releases.
- Document Gatekeeper behavior.

Tests:

- CI verifies signature;
- CI verifies hardened runtime;
- CI verifies notarization ticket stapled;
- clean macOS user can install and launch.

### 11. CI Security Gates

Plan:

- Add secret scanning:
  - API keys;
  - GitHub tokens;
  - private paths;
  - accidental `.codex` log samples.
- Add dependency audit where applicable.
- Add `swiftlint` or equivalent style/static checks if adopted.
- Add release artifact diff/checklist.

Tests:

- CI fails on committed fake secret pattern;
- CI fails on committed absolute home-directory paths in public docs;
- CI passes on redacted placeholders.

## P5 Permission Monitor Accuracy

### 12. Monitor vs Mutate Clarity

Problem:

- Users can confuse permission risk monitoring with actual Codex permission enforcement.

Plan:

- In UI, split:
  - `Observed Codex mode`;
  - `TODEX policy`;
  - `Violations`;
  - `Apply policy to config.toml`.
- Make mutation explicit:
  - preview diff;
  - backup path;
  - apply button;
  - rollback button.

Tests:

- monitor-only mode never writes config;
- apply mode writes atomically;
- rollback restores backup;
- project sections in config are preserved.

### 13. Config Writer Safety

Plan:

- Keep atomic writes with backup.
- Reject symlinked config by default.
- Preserve unknown TOML keys and project sections.
- Use a TOML parser or structured writer if dependency budget allows.

Tests:

- preserves project sections;
- preserves comments where possible or documents if not;
- rejects symlinked config;
- backup created before write;
- interrupted write does not corrupt config.

## Release Checklist

Before a public release:

- `swift build`
- `Scripts/test.sh`
- runtime listener check shows zero TODEX TCP LISTEN and UDP rows
- secret scan passes
- private path scan passes
- help screenshots contain no private data
- LaunchAgent install/uninstall tested from installed `.app`
- API-key vault save/unlock/delete tested manually
- OpenAI Usage/Costs API tested with a low-risk admin key
- Developer ID signed
- hardened runtime enabled
- notarized and stapled
- release notes clearly distinguish local estimated cost from actual OpenAI Costs API
