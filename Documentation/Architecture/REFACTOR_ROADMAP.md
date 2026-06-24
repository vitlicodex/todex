# TODEX Refactor Roadmap

Date: 2026-06-25

This roadmap intentionally avoids a big-bang rewrite. TODEX is a small native utility, so the fastest path to production quality is to create sharper seams first, then split targets only where the seams have tests.

## Non-Negotiable Constraints

- Preserve local-first privacy.
- Do not store prompts, completions, raw Codex lines, API keys, Authorization headers, or full private paths.
- Do not call real OpenAI APIs in tests.
- Keep actual OpenAI Costs API values separate from estimated local Codex cost.
- Keep AppKit UI responsive by rendering from cached snapshots.
- Keep old state files decodable.

## Target Module Boundaries

```text
TokenUsageCore
  Models, parser primitives, aggregation math, cost estimation.

TokenUsageStorage
  State persistence, settings persistence, migrations, private file IO.

TokenUsageAPI
  OpenAI transport, Usage API parser, Costs API parser, mock transport.

TokenUsageSecurity
  API-key vault, redaction, permission monitoring, permission config writer.

TokenUsageReports
  Sanitized Markdown/JSON report rendering.

TokenUsageMenuBar
  AppKit status item, menus, windows, icons, user actions.
```

## Phase 0: Stabilize Behavior Before Moving Files

Status: in progress.

Already covered:

- cached input propagation;
- truncation warning;
- same-shaped request dedup;
- path redaction in reports/logs/menu summaries;
- actor-backed refresh for main menu path;
- API partial Usage/Costs failure behavior;
- typed API errors for 429/404/5xx/timeout;
- core cost estimator primitive.

Next tasks:

- add timing instrumentation;
- add fileID/inode fingerprint;
- add aggregate cache validator;
- remove or deprecate legacy synchronous view model refresh path.

Exit criteria:

- `swift build` and `Scripts/test.sh` pass;
- synthetic large-log benchmark exists;
- exported reports remain redacted;
- no UI path directly calls parser/store/API on main actor.

## Phase 1: Extract Reports Boundary

Why first:

- Reports are pure formatting and easy to test.
- Report duplication exists today.
- Privacy guarantees depend on consistent report rendering.

Steps:

1. Create `ReportRenderer` in Core or new `TokenUsageReports` target.
2. Move Markdown rendering from `TokenUsageEngine` and `TokenRefreshWorker` into the renderer.
3. Keep JSON export through `TokenUsageReport.privacyRedactedForReport`.
4. Add fixtures for:
   - empty stats;
   - local Codex stats;
   - API stats;
   - stats with issues;
   - privacy mode.

Rollback:

- Keep old renderer functions for one release and compare output in tests.

## Phase 2: Extract API Boundary

Why second:

- API correctness affects cost/accounting trust.
- Tests need mocked transport and fixtures.

Steps:

1. Introduce `OpenAIUsageTransport` protocol:
   - request path;
   - query items;
   - headers;
   - response data/status/headers.
2. Split `OpenAIUsageClient` into:
   - transport;
   - Usage response parser;
   - Costs response parser;
   - statistics builder.
3. Add redirect policy at transport layer.
4. Add pagination support if response includes cursor/next page.
5. Add fixtures for status classes and partial failures.

Rollback:

- Keep current `OpenAIUsageClient` API stable and route through old path if transport feature flag is disabled.

## Phase 3: Improve Storage and Aggregation

Why third:

- This is the highest performance payoff but also the most migration-sensitive area.

Steps:

1. Add `TokenUsageAggregateState`:
   - daily summaries;
   - current month summary;
   - project/day summaries;
   - last 10 ring;
   - peak sample;
   - schema version.
2. Update aggregate state in `TokenUsageStore.add`.
3. Keep full recomputation in debug/test validation.
4. Add migration from old state with samples only.
5. Add state compaction policy if sample history grows too large.

Tests:

- aggregate equals full recomputation;
- old state decodes;
- reset session vs reset all;
- midnight/week/month boundaries;
- project metadata enrichment;
- cached input propagation.

Rollback:

- If aggregate validation fails, ignore aggregate cache and compute from samples.

## Phase 4: Harden Local Source Identity

Why fourth:

- File identity changes touch parser correctness and source persistence.

Steps:

1. Extend `FileFingerprint`:
   - size;
   - mtime;
   - file resource identifier string if available;
   - optional volume identifier if available.
2. Detect:
   - append;
   - truncation;
   - replacement;
   - unreadable file;
   - symlink source if policy rejects it.
3. Add source issue types for replacement/truncation.
4. Keep old fingerprints decodable.

Tests:

- append uses cursor;
- truncate does not seek past EOF;
- replacement parses safely;
- symlink source policy;
- unavailable file does not clear existing stats.

Rollback:

- If fileID is unavailable or unstable, fall back to path+size+mtime.

## Phase 5: Split Security and Storage Targets

Why later:

- Security and storage code touches app support paths, vault, permissions, settings, and reports.
- Moving files before tests are mature increases release risk.

Steps:

1. Move `PrivateFileIO`, settings store, app paths, and state persistence into `TokenUsageStorage`.
2. Move API key vault, redaction, permission monitor, permission writer into `TokenUsageSecurity`.
3. Keep public APIs source-compatible for `TokenUsageMenuBar`.
4. Run privacy scans after each move.

Tests:

- vault save/unlock/delete manual smoke;
- settings load/save;
- permissions snapshot;
- config writer backup;
- report redaction.

Rollback:

- Revert target split without changing behavior; file movement commits should not mix behavior changes.

## Phase 6: Wire Estimated Local Cost to Product

Why after estimator:

- The estimator is now pure and tested.
- UI requires copy/design/settings decisions.

Steps:

1. Add pricing profile settings:
   - built-in profiles;
   - custom profile;
   - multiplier.
2. Add separate statistics fields:
   - `actualAPIDailyCostUSD`;
   - `actualAPIMonthlyCostUSD`;
   - `estimatedLocalDailyCostUSD`;
   - `estimatedLocalMonthlyCostUSD`;
   - profile name.
3. Update reports:
   - actual API cost source;
   - estimated local cost source;
   - no blended cost label.
4. Update menu UI:
   - keep compact header;
   - show estimate only when enabled;
   - use `estimated` label.

Tests:

- estimate uses cached discount;
- actual and estimated fields stay separate;
- JSON/Markdown reports label source correctly;
- UI display model includes correct labels.

Rollback:

- Hide estimated local cost without removing persisted pricing settings.

## Phase 7: AppKit UI Cleanup

Steps:

1. Delete or quarantine `TokenUsageViewModel` if unused.
2. Move menu construction into smaller builders:
   - overview;
   - usage calendar;
   - permissions;
   - settings/security;
   - reports/actions.
3. Keep all builders pure over `TokenUsageStatistics`, `CodexPermissionSnapshot`, and `MonitorSettings`.
4. Avoid disk/network calls in menu builders.

Tests:

- display model snapshot tests;
- menu signature stability;
- no parser/store/API calls in menu build path.

Rollback:

- Keep current `TokenStatusController` until each builder is covered.

## Safe Rollout Order

1. Tests for current behavior.
2. Pure helper extraction.
3. Internal implementation switch behind stable public API.
4. Debug validation comparing old and new outputs.
5. Remove old path after at least one clean release.

## Risks

- Aggregate cache can make incorrect totals look fast. Keep full recompute validation.
- FileID behavior can vary by filesystem. Keep fallback.
- Estimated local cost can be mistaken for actual billing. Label aggressively.
- Target split can create circular dependencies. Move reports/API first because they are easiest to isolate.
- Timing instrumentation can become privacy risk if it logs source identifiers. Keep metrics numeric and phase-only.

## Rollback Checklist

- Disable new aggregate cache.
- Fall back to old source fingerprint behavior.
- Hide estimated local cost UI.
- Route API through old direct client.
- Revert target split commits independently from behavior commits.
- Keep state decoders backward-compatible before and after rollback.
