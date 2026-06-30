# TODEX Multi-Track Orchestration Summary

This document records the coordinated execution of the "Mega Goal - Parallel / Multi-Agent Style Orchestrator" prompt.

## Executive Summary

Four parallel read-only audit tracks were used to map ownership, risks, and safe next changes. Code changes were then applied sequentially in one integration branch because the project currently has a shared custom test runner and no separate Swift test modules. This avoided concurrent edits to the same file while preserving the intended track boundaries.

Implemented in this pass:

- Added explicit OpenAI API redirect policy: only HTTPS same-host/same-port redirects are allowed.
- Added regression coverage for redirect policy.
- Fixed Codex permission parsing for string-valued `sandbox_policy.network_access` values such as `restricted`, `disabled`, and `enabled`.
- Added regression coverage for those permission metadata shapes.
- Renamed generic cost labels in menu/report surfaces to make clear that `dailyCostUSD` and `monthlyCostUSD` are actual OpenAI Platform API costs, not estimated local Codex costs.
- Added Markdown report coverage to prevent generic cost labels from returning.

Completed in later follow-up passes:

- OpenAI Usage/Costs pagination.
- Local estimated cost fields in `TokenUsageStatistics`.
- TOML-aware trusted workspace parsing for project tables.

Still not implemented:

- A centralized `ReportRenderer`.
- LaunchAgent and API-key vault pure-validator extraction.

## Track Plans and Ownership

### Track A - Parser and Accounting

Plan:

1. Lock parser semantics with tests before behavior changes.
2. Strengthen date-boundary and reset semantics tests.
3. Keep local estimated-cost plumbing separate from actual OpenAI API costs.
4. Avoid mixing API cost, local cost, and raw token accounting.

Owned files:

- `Sources/TokenUsageCore/TokenUsageParser.swift`
- `Sources/TokenUsageCore/TokenUsageModels.swift`
- `Sources/TokenUsageCore/TokenUsageStore.swift`
- `Sources/TokenUsageCore/TokenUsageEngine.swift`
- `Sources/TokenUsageCore/CostEstimator.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`

Outcome:

- No parser/accounting code was changed in this pass because existing coverage already preserved `cached_input_tokens`, `last_token_usage`, parser truncation warnings, and same-shaped request preservation.
- Track A risks were documented for follow-up: stronger fixed-date aggregation tests, reset semantics tests, source replacement tests, and estimated-local-cost fields.

### Track B - API Client and Error Handling

Plan:

1. Keep `fetchStatistics` API stable.
2. Harden transport first.
3. Add mocked fixtures for Usage and Costs.
4. Add pagination and partial-failure coverage in a later staged pass.

Owned files:

- `Sources/TokenUsageCore/OpenAIUsageClient.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`

Outcome:

- Added `OpenAIRedirectPolicy`.
- Default `URLSession` now uses a redirect delegate.
- Cross-host, HTTPS downgrade, and port-changing redirects are blocked.
- Same-host HTTPS redirects are allowed.

### Track C - Security and Permission Monitoring

Plan:

1. Audit permission metadata parsing.
2. Audit config writer safety.
3. Check API-key vault and LaunchAgent validation surfaces.
4. Add safe parser tests where the current behavior was under-specified.

Owned files:

- `Sources/TokenUsageCore/CodexPermissionMonitor.swift`
- `Sources/TokenUsageCore/CodexPermissionConfigWriter.swift`
- `Sources/TokenUsageCore/PrivateFileIO.swift`
- `Sources/TokenUsageMenuBar/APIKeyStore.swift`
- `Sources/TokenUsageMenuBar/LaunchAtLoginController.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`

Outcome:

- `sandbox_policy.network_access` now uses the same network policy parser as top-level and permission-profile network fields.
- String values `restricted` and `disabled` are no longer treated as unknown.
- String value `enabled` is treated as enabled.

### Track D - UI, Reports, and Documentation

Plan:

1. Align menu/report labels with actual data sources.
2. Keep actual OpenAI Costs API values separate from future local estimates.
3. Centralize report rendering in a later pass.
4. Keep privacy warnings and report labels truthful.

Owned files:

- `Sources/TokenUsageCore/TokenUsageDisplayModel.swift`
- `Sources/TokenUsageCore/TokenUsageEngine.swift`
- `Sources/TokenUsageMenuBar/TokenUsageMenuBarApp.swift`
- `Sources/TokenUsageMenuBar/TokenMenuHeaderView.swift`
- `Documentation/**`
- `Sources/TokenUsageCoreTestRunner/main.swift`

Outcome:

- Header metric now says `API COST`.
- Overview now says `Actual API daily cost` and `Actual API monthly cost`.
- Markdown reports now say `Actual OpenAI API daily/monthly cost`.
- Added regression coverage for core Markdown report labels.

## Overlap Detection

Shared file:

- `Sources/TokenUsageCoreTestRunner/main.swift`

Resolution:

- The shared test runner was edited sequentially after each track patch.
- No agents edited the repository directly.
- No overlapping code ownership files were edited at the same time.

## Privacy Invariants Preserved

- Tests use mocked OpenAI responses only.
- No real OpenAI API calls are required.
- No API keys, Authorization headers, raw prompts, raw Codex logs, raw request bodies, or private full paths are stored in the new docs.
- Actual OpenAI API costs remain separate from estimated local Codex cost primitives.
- Reports continue to use privacy redaction before export.

## Verification

Intermediate verification:

- `swift run TokenUsageCoreTestRunner` passed after Track B.
- `swift run TokenUsageCoreTestRunner` passed after Track C.
- `swift run TokenUsageCoreTestRunner` passed after Track D code changes.

Final verification must include:

- `swift build`
- `Scripts/test.sh`

## Remaining Risks

| ID | Severity | Area | Risk | Recommended Follow-Up |
| --- | --- | --- | --- | --- |
| TDX-ORCH-001 | Fixed | API accounting | Usage/Costs pagination was missing in the initial pass. | Keep max-page, duplicate-cursor, malformed-cursor, and partial-page fixtures current. |
| TDX-ORCH-002 | Fixed | API UX | Usage success + Costs failure and Costs success + Usage failure needed stronger fixture coverage. | Keep endpoint-aware partial-failure fixtures current. |
| TDX-ORCH-003 | Fixed | Cost accounting | Local estimated cost existed as a pure estimator but was not represented in `TokenUsageStatistics`. | Keep actual API cost and estimated local Codex cost labels separate in every new surface. |
| TDX-ORCH-004 | Medium | Reports | Markdown report rendering is duplicated between core and menu worker paths. | Extract a pure `ReportRenderer` and golden tests. |
| TDX-ORCH-005 | Fixed | Permission monitor | Trusted workspace parsing was line-based, not TOML table-aware. | Keep project-table fixtures for top-level, unrelated table, trusted, and untrusted cases. |
| TDX-ORCH-006 | Low | Release hardening | Signing, hardened runtime, notarization, and release metadata need a release checklist. | Add release workflow docs and CI checks. |
