# TODEX Architecture Review

Date: 2026-06-25

Scope: native macOS Swift menu bar app for local Codex token monitoring, OpenAI Usage/Costs API data, permission risk, encrypted API-key storage, reports, settings, and launch-at-login.

## Executive Summary

TODEX already has several good architectural instincts:

- core parsing, storage, API, and permission logic live outside the AppKit controller;
- the main menu path uses an actor-backed `TokenRefreshWorker`;
- local Codex JSONL parsing is streaming and incremental for append-only files;
- reports are redacted before export;
- OpenAI API calls are outbound-only and cached by a key/settings signature;
- no local listener or server surface was found in the previous security audit.

The architecture is still too compressed into two targets:

- `TokenUsageCore` contains parsing, aggregation, storage, settings, redaction, permissions, API client, private file IO, reporting helpers, and app paths.
- `TokenUsageMenuBar` contains UI, refresh orchestration, API-key vault, launch-at-login, help rendering, menu rendering, and some legacy view model logic.

The main performance risks are not "one obviously bad loop"; they are ownership blur:

- the store recomputes statistics from all retained samples on each snapshot;
- discovery and refresh still use path-based identity rather than fileID/inode;
- sync disk IO is safely off the main menu path in the current controller, but still present in legacy UI code;
- report generation and settings/storage writes are scattered rather than owned by a reporting/storage boundary;
- API cost and local estimated cost are now modeled separately, but report rendering remains split across Core and MenuBar paths.

## Current Architecture Map

| Concern | Current owner | Notes |
| --- | --- | --- |
| Codex log discovery | `TokenSourceDiscovery` | Finds configured files and common `.codex` files/directories; caps files per directory by recent mtime. |
| Token parsing | `TokenUsageParser` | Streams JSONL/log files; parses structured JSON; filters Codex sessions to token/metadata lines; tracks cached input. |
| Incremental local pipeline | `TokenUsageEngine` + `TokenUsageStore` | Keeps fingerprints and scan cursors; parses appended bytes when file size grows. |
| Aggregation/history | `TokenUsageStore` | Stores all samples, seen IDs, source fingerprints/cursors; computes session/day/week/month snapshots on demand. |
| OpenAI Usage API | `OpenAIUsageClient` | Fetches organization usage buckets through `URLSession`; computes daily/monthly summaries and breakdowns. |
| OpenAI Costs API | `OpenAIUsageClient` | Fetches cost buckets and merges costs into usage statistics; partial failure behavior exists. |
| Local estimated cost | `CostEstimator`, `TokenPricingProfile`, `TokenUsageStatistics` estimated fields | Wired into settings, store statistics, menu display model, and reports as estimated-only data. |
| API-key vault | `APIKeyStore` | AppKit target; AES-GCM/PBKDF2 vault with Touch ID/macOS auth and private file checks. |
| Permission monitoring | `CodexPermissionMonitor` | Reads Codex config and recent session `turn_context` metadata; produces risk snapshot. |
| Permission config writer | `CodexPermissionConfigWriter` | Updates selected top-level TOML keys and keeps backup. |
| Menu bar UI | `TokenStatusController`, `TokenMenuHeaderView`, `UsageCalendarMenuView` | Builds the status item, menu, header, calendar, controls, and settings actions. |
| Refresh orchestration | `TokenStatusController` + `TokenRefreshWorker` | Main controller schedules timer and dispatches work to actor; actor runs local/API refresh. |
| Settings persistence | `MonitorSettingsStore` | Stored in Core with app support path and private file writer. |
| Reports/exports | `TokenUsageEngine`, `TokenRefreshWorker`, `TokenUsageStore` | Markdown/JSON report logic is split across core and menu worker. |
| Launch at login | `LaunchAtLoginController` | AppKit target; writes user LaunchAgent plist with bundle validation. |
| Help window | `HelpWindowController` | AppKit/WebKit markdown renderer for bundled help. |

## Text Dependency Diagram

```text
TODEX.app
  AppDelegate
    TokenStatusController (@MainActor)
      TokenRefreshWorker actor
        TokenUsageEngine
          TokenSourceDiscovery
          TokenUsageParser
          TokenUsageStore
            PrivateFileIO
            TokenReportPrivacy
        OpenAIUsageClient
      PermissionRefreshWorker actor
        CodexPermissionMonitor
      APIKeyStore
        PrivateFileIO
      LaunchAtLoginController
        PrivateFileIO
      HelpWindowController
      TokenMenuHeaderView / UsageCalendarMenuView / StatusBarIconRenderer

TokenUsageCore
  parsing + aggregation + storage + API + permissions + settings + redaction + cost estimation

TokenUsageMenuBar
  UI + orchestration + security vault + launch-at-login + help
```

## Data Flow

```text
Local Codex JSONL files
  -> TokenSourceDiscovery
  -> TokenUsageEngine fingerprints/cursors
  -> TokenUsageParser streaming token_count/session metadata
  -> TokenUsageStore samples + seen IDs + daily/week/month aggregation
  -> TokenRefreshWorker cached snapshot
  -> TokenStatusController menu/header/calendar

OpenAI Admin API key
  -> APIKeyStore encrypted local vault
  -> TokenRefreshWorker in-memory unlocked key
  -> OpenAIUsageClient Usage/Costs API
  -> TokenUsageStatistics API-only costs/breakdowns
  -> merged with local statistics only as labeled actual API cost metadata
```

## Current Bottlenecks

1. `TokenUsageStore.statistics` computes day/week/month/session summaries by filtering and reducing the full retained sample array for every snapshot.
2. `TokenUsageStore.add` sorts all stored samples after each new import.
3. Source fingerprints are size+mtime and keyed by path; file rotation with identical path is handled by size regression, but fileID/inode is not tracked.
4. `TokenSourceDiscovery` recursively enumerates candidate directories every refresh after a short cache window; this can still be expensive on large `.codex` trees.
5. `TokenUsageParser.parse(data:)` still loads non-JSONL structured files into memory and uses `JSONSerialization` recursively.
6. Generic estimated parsing can read prompt-like text from explicit non-session files; normal Codex sessions avoid this, but the ownership boundary is not obvious.
7. `TokenRefreshWorker` protects the current menu path from main-thread parsing, but legacy `TokenUsageViewModel` calls `engine.refresh()` from `@MainActor`.
8. Report generation is duplicated in Core and MenuBar worker paths.
9. API client and cost parser share one type, making transport, pagination, and parsing harder to mock independently.
10. Permission monitoring scans recent session files separately from token parsing, duplicating some file IO over `.codex/sessions`.

## Top 10 Architecture and Performance Findings

| ID | Severity | Area | Finding | Impact | Current mitigation | Recommended next step |
| --- | --- | --- | --- | --- | --- | --- |
| ARCH-001 | High | UI responsiveness | Current menu path is actor-backed, but legacy `TokenUsageViewModel` performs synchronous refresh on `@MainActor`. | Any future reuse can reintroduce UI freezes. | Main AppKit controller uses `TokenRefreshWorker`. | Remove legacy view model or move it behind the same worker actor. |
| ARCH-002 | High | Aggregation | Store snapshots recompute from all samples on each refresh/menu snapshot. | More samples mean slower menu updates and report generation. | Incremental parsing reduces new input volume. | Add persisted daily/project aggregates and update them incrementally. |
| ARCH-003 | High | File identity | Incremental cursor is path+size+mtime based, not fileID/inode based. | Rotation/replacement edge cases can undercount or rescan. | Size regression disables incremental path. | Add file resource identifier/inode to `FileFingerprint`. |
| ARCH-004 | Medium | Discovery | Source discovery recursively scans candidate directories after cache expiry. | Large session trees can delay refresh. | Discovery cache interval and max files per directory. | Cache discovered source set with directory mtime and prioritize newest active files. |
| ARCH-005 | Medium | Parser | JSONL parser is streaming, but structured JSON path still maps/loads full file. | Large explicit JSON sources can allocate heavily. | Structured JSON file size cap. | Keep caps; document explicit file mode as advanced; add benchmark fixture. |
| ARCH-006 | Medium | API | Usage/Costs client mixes transport, parsing, status classification, and aggregation. | Harder to test redirects/pagination/error policy. | Mockable `URLSession` injection exists. | Extract transport/parser structs before pagination work. |
| ARCH-007 | Fixed | Cost accounting | Actual OpenAI Costs API and local estimated cost needed separate model fields and labels. | Users can misunderstand local Codex spend vs platform API spend. | Actual costs stay in API fields; estimated local Codex costs use separate statistics/report/menu fields. | Keep fixture coverage for actual-vs-estimated labels as UI evolves. |
| ARCH-008 | Medium | Reports | Report Markdown generation is duplicated. | One path can drift from privacy rules or labels. | Both paths now use redacted statistics. | Extract `ReportRenderer` in a small Reports boundary. |
| ARCH-009 | Low | Diagnostics | No safe timing metrics around parse/discovery/store/API phases. | Performance regressions are harder to diagnose. | Debug logger redacts paths/secrets. | Add content-free timing spans with phase names and durations only. |
| ARCH-010 | Low | Boundaries | `TokenUsageCore` is doing too many jobs. | Harder ownership and future test boundaries. | Package targets are still small. | Split gradually into API/Storage/Security/Reports only after seams are tested. |

## Already Improved Before or During This Review

- Codex `last_token_usage` is counted; cumulative `total_token_usage` is ignored.
- `cachedInputTokens` is preserved in parser, store, UI display model, and reports.
- Sample IDs include line/location for same-shaped request preservation.
- Parser emits `sourceTruncated` issue when `maxSamplesPerFile` is hit.
- Local path redaction exists for reports/logs/menu source summaries.
- `TokenRefreshWorker` actor keeps parsing/network work off the main AppKit menu path.
- API partial failure behavior can keep Costs data when Usage fails and vice versa.
- API HTTP error classification now distinguishes 429, 404, 5xx, and timeout.
- `CostEstimator` now feeds explicit estimated-local cost statistics, report fields, and menu labels without overwriting actual OpenAI Costs API values.

## Target Architecture

```text
TokenUsageCore
  Pure models, parser primitives, aggregation math, cost estimation.

TokenUsageStorage
  Stats state, settings state, private file IO, report persistence, migrations.

TokenUsageAPI
  OpenAI transport, Usage parser, Costs parser, mock transport, pagination.

TokenUsageSecurity
  API-key vault, redaction, permission monitor, permission config writer.

TokenUsageReports
  Sanitized Markdown/JSON renderers, privacy mode policies.

TokenUsageMenuBar
  AppKit-only UI, menu rendering, windows, status item, user actions.
```

This target should be reached incrementally. A big-bang target split would create churn without improving runtime behavior by itself.

## Rollout Guidance

1. Preserve current package targets until behavior is covered by tests.
2. Extract pure renderers/parsers first; they are low-risk and easy to test.
3. Add fileID/inode fingerprints and aggregate cache behind migration-compatible decoders.
4. Introduce timing instrumentation as content-free debug metrics.
5. Only then split targets, because the seams will be proven by tests.

## Privacy Constraints

- Never store prompts, completions, raw Codex lines, API keys, Authorization headers, or full private paths.
- Keep Codex session parsing line-filtered to token and metadata events.
- Keep estimated prompt-text parsing opt-in if it remains supported for explicit non-session files.
- Never merge actual OpenAI Costs API values with estimated local Codex cost.
- Logs may contain phase names and numeric durations only, not file paths or raw payloads.
