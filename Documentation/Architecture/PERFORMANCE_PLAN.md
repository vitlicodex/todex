# TODEX Performance Plan

Date: 2026-06-25

This plan focuses on keeping the macOS menu bar app responsive while monitoring large local Codex session logs and optional OpenAI Usage/Costs API data.

## Performance Goals

- Menu open should render from a cached snapshot and avoid disk, crypto, network, or heavy parsing.
- Refresh work should run off the AppKit main thread.
- Large append-only JSONL logs should be parsed incrementally.
- Repeated refreshes should avoid full rescans and repeated aggregation work.
- API latency should not block local token display.
- Instrumentation must never log prompts, completions, raw lines, API keys, Authorization headers, or full private paths.

## Current Bottlenecks

| Priority | Bottleneck | Current behavior | Risk |
| --- | --- | --- | --- |
| P0 | Legacy main-thread refresh path | `TokenUsageViewModel` calls `engine.refresh()` from `@MainActor`. | UI freeze if reused. |
| P0 | Aggregate recomputation | `TokenUsageStore.statistics` filters/reduces all samples for day/week/month/session. | Menu/report gets slower as history grows. |
| P0 | Actual vs estimated cost model | Actual API cost and estimated local Codex cost now use separate fields and labels. | Keep label drift from reappearing as UI changes. |
| P1 | File identity | Source state uses path, size, mtime; no fileID/inode. | Rotation/replacement edge cases. |
| P1 | Discovery scanning | Candidate directories are enumerated after cache expiry. | Large `.codex` trees can delay refresh. |
| P1 | Structured JSON loading | Non-JSONL JSON path can map/load entire file. | Memory spikes for explicit large files. |
| P1 | API error classes | Generic non-2xx handling hides actionability. | Bad retry/key-permission UX. |
| P2 | Report rendering | Markdown report generation exists in multiple places. | Drift and repeated formatting work. |
| P2 | Permission scan duplication | Permission monitor scans session files independently. | Duplicate IO. |
| P2 | Missing benchmark baselines | No benchmark fixtures for large JSONL or aggregation growth. | Regressions are hard to detect. |

## Safe Timing Instrumentation

Add a small content-free phase timer:

```text
refresh.total_ms=42
refresh.discovery_ms=3
refresh.parse_ms=21
refresh.store_ms=8
refresh.api_ms=0
refresh.source_count=12
refresh.sample_count=37
```

Rules:

- phase names and numeric durations only;
- no raw source path;
- no prompt/completion text;
- no API key fingerprint in logs unless already hashed and non-reversible;
- keep logs behind existing debug logger redaction.

Suggested implementation:

- `PerformanceSpan` in Core or diagnostics boundary;
- use `ContinuousClock`;
- actor-safe result struct returned with `TokenUsageStatistics` or logged only at debug level;
- tests assert no raw path or secret-like value appears in formatted metrics.

## P0 Fix Plan

### 1. Keep UI Open Fast

Current status:

- Main menu path renders from `statistics` already in memory.
- Refresh is launched through `Task` and `TokenRefreshWorker` actor.
- Menu rebuild has a render signature guard.

Next actions:

- remove or quarantine `TokenUsageViewModel`;
- expose only the actor-backed refresh path;
- ensure all menu actions that write reports/settings remain async when they touch disk;
- add a testable rule: menu display model generation must not call parser/store/API.

Rollback:

- keep existing `TokenStatusController` path unchanged while deleting or deprecating legacy view model.

### 2. Incremental Aggregates

Current status:

- Samples are persisted, deduped by ID, and sorted.
- Statistics are computed from samples on demand.

Plan:

- Add persisted aggregate cache:
  - daily summaries keyed by local day;
  - project summaries keyed by day+project alias;
  - total/month/session counters;
  - last 10 token sample ring;
  - peak token sample.
- Update aggregates in `TokenUsageStore.add` when new samples are accepted.
- Keep old full recomputation as a validator during migration.

Tests:

- aggregate cache matches full recomputation for fixtures;
- midnight boundary;
- week/month boundary;
- reset session does not delete persistent daily history;
- reset all clears persistent aggregates but can mark current sources as seen.

Rollback:

- keep full recomputation implementation and feature-flag aggregate cache until confidence is high.

### 3. Local Estimated Cost

Current status:

- `CostEstimator`, `TokenPricingProfile`, and `EstimatedTokenCost` now exist in Core.
- Estimator treats cached input as a subset of input to avoid double-charging.
- Settings, statistics, menu display, and reports expose estimated local Codex cost separately from actual OpenAI Costs API values.

Next actions:

- keep selected pricing profile edits cheap and menu-local;
- add benchmark coverage for estimator recalculation on large histories;
- keep labels explicit:
  - `Actual OpenAI API cost`;
  - `Estimated local Codex cost`;
- continue including the selected pricing profile name in reports.

Tests:

- cached input discount;
- output price;
- reasoning price when available;
- multiplier;
- actual API cost and estimated local cost never merge.

Rollback:

- hide estimated cost UI while leaving estimator tests and model available.

## P1 Fix Plan

### 4. FileID/Inode-Aware Cursors

Current status:

- `FileFingerprint` includes size and mtime.
- `FileScanCursor` includes byte offset, line count, and project metadata.

Plan:

- Extend fingerprint with file resource identifier where available:
  - `.fileResourceIdentifierKey` from URL resource values;
  - fallback to size+mtime on filesystems that do not provide stable IDs.
- If fileID changes for same path, treat as rotation/replacement and full-parse with dedup.
- If file size shrinks, treat as truncation/rotation and full-parse with warning metadata.

Tests:

- append-only file uses offset;
- truncated file does not seek past end;
- replaced file with same path is not skipped;
- cursor persists and reloads.

Rollback:

- keep decoder defaults for old fingerprints.

### 5. Discovery Cache Improvements

Current status:

- discovery caches source list for 15 seconds;
- each directory returns most recent files up to `maxFilesPerDirectory`.

Plan:

- persist most recent active sources separately;
- scan active source first;
- refresh directory enumeration less frequently than file parsing;
- consider directory mtime fingerprint where reliable.

Tests:

- active appended source is parsed even when full discovery is skipped;
- newly created source is found after discovery cache expires;
- max file cap keeps newest files.

Rollback:

- force full discovery on manual refresh.

### 6. API Client Performance and Reliability

Current status:

- `URLSession` is reused;
- request/resource timeouts exist;
- API cache TTL exists in `TokenRefreshWorker`;
- partial Usage/Costs failure behavior exists;
- this pass adds typed 429/404/5xx/timeout issues and an explicit HTTPS same-host/same-port redirect policy.

Plan:

- extract transport and response parser;
- add pagination loop if API exposes cursor/next page;
- keep redirect delegate coverage for cross-host Authorization forwarding;
- add fixtures for empty/malformed/large response bodies.

Tests:

- 401/403 unauthorized;
- 429 retry-after;
- 404 endpoint unavailable;
- 5xx server error;
- timeout;
- costs success + usage failure;
- usage success + costs failure;
- no Authorization on cross-host, downgrade, or port-changing redirect.

Rollback:

- keep current direct `URLSession` client until transport abstraction tests pass.

## Benchmarks

Add a benchmark-style test runner mode or separate executable that can run locally and in CI with conservative limits:

| Benchmark | Fixture | Expected assertion |
| --- | --- | --- |
| Large JSONL streaming | 100k synthetic token_count lines | bounded memory; completes under local threshold. |
| Incremental append | 10k baseline + 1 appended line | second refresh parses only appended bytes. |
| Aggregation growth | 100k samples across 60 days | snapshot time stays below threshold after aggregate cache. |
| Rotated file | same path, smaller size or changed fileID | no skipped new samples. |
| Menu display model | large statistics fixture | no parser/store/API calls. |
| API mocked latency | slow Usage, fast Costs | UI can show cached/local snapshot. |

Benchmark fixtures must contain synthetic numeric data only.

## Implementation Order

1. Keep current actor-based menu path.
2. Add typed API failures and tests. Done in this pass.
3. Add core-only cost estimator and tests. Done in this pass.
4. Add timing spans, initially disabled or debug-only.
5. Add fileID/inode fingerprint migration.
6. Add aggregate cache with full-recompute validation.
7. Wire estimated cost to settings/UI/report.
8. Extract API transport/parser.
9. Split storage/security/reports targets.

## Manual Checks

- Open menu while a synthetic large log refresh is running; menu must open immediately from cached snapshot.
- Put machine to sleep, wake, and verify refresh does not freeze menu bar.
- Rotate a session log and verify totals do not jump backward or duplicate.
- Unlock API key, run mocked/offline tests, and confirm no key appears in logs.
- Export JSON/Markdown and verify no full local paths or prompt text.

## Rollback Plan

- For parser/aggregate changes: retain old full recomputation path and compare outputs in debug builds.
- For API changes: keep old direct client behind a feature flag until mocked fixtures cover all status classes.
- For UI estimated cost: disable display if pricing profile is missing or invalid.
- For target split: do not move files and behavior in the same commit; move only after tests are green.
