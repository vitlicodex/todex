# Top 3 Killer Features Implementation Log

## Working Tree Notice

This implementation started from a dirty working tree on an existing integration branch. The existing changes were from the prior security/orchestration pass and were not reverted.

New feature work is being layered on branch `codex/top3-foundation`.

## Track A - Data Model, Parser, and Accounting Foundation

Intended files:

- `Sources/TokenUsageCore/TokenUsageModels.swift`
- `Sources/TokenUsageCore/TokenUsageParser.swift`
- `Sources/TokenUsageCore/TokenUsageStore.swift`
- `Sources/TokenUsageCore/CostEstimator.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`
- `Documentation/Codex/TODEX_KILLER_FEATURES_TOP3.md`
- `Documentation/Features/TOP3_IMPLEMENTATION_LOG.md`

Changes:

- Added `reasoningTokens` to `TokenUsageSample`.
- Added `reportedTotalTokens` to preserve explicit totals separately from computed totals.
- Added computed helpers for input/output and input/output/reasoning totals.
- Preserved legacy decoding defaults.
- Parser now preserves reasoning token aliases and reported totals when present.
- Cost estimator now aggregates sample-level reasoning tokens.

Verification:

- `swift run TokenUsageCoreTestRunner` passed.

## Track E - UI, Reports, and Integration

Intended files:

- `Sources/TokenUsageCore/TokenUsageDisplayModel.swift`
- `Sources/TokenUsageCore/TokenUsageEngine.swift`
- `Sources/TokenUsageMenuBar/TokenMenuHeaderView.swift`
- `Sources/TokenUsageMenuBar/TokenUsageMenuBarApp.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`
- `Documentation/Features/README.md`
- `Documentation/Features/TOP3_IMPLEMENTATION_LOG.md`

Changes:

- Menu header now prefers `EST. LOCAL` when estimated local daily cost is available.
- Overview exposes estimated local daily/monthly cost and actual API daily/monthly cost as separate rows.
- Reports include estimated local Codex cost labels.
- Menu now includes an `AI Spend Firewall` section with alerts, context finding count, and privacy-safe evidence snippets.
- Worker computes context findings and firewall alerts from local numeric samples.
- Feature switches now include estimated local cost, context detector, and spend firewall.

Verification:

- `swift run TokenUsageCoreTestRunner` passed.
- `swift build` passed.
- Final `swift build && Scripts/test.sh` passed after integration.

## Known Limitations

- Pricing profile editing is available from the menu, but not yet a full standalone preferences window.
- Firewall actions are user-triggered. TODEX does not automatically stop Codex or mutate running work in response to spend alerts.
- Context explosion detection is heuristic and intentionally avoids inspecting prompts or file contents.
- Actual OpenAI API costs and estimated local Codex costs are displayed separately.

## OpenAI Usage/Costs Pagination Follow-up

Intended files:

- `Sources/TokenUsageCore/OpenAIUsageClient.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`
- `Documentation/Features/OPENAI_USAGE_COSTS_PAGINATION.md`
- `Documentation/Features/README.md`
- `Documentation/Features/TOP3_IMPLEMENTATION_LOG.md`

Changes:

- Added bounded pagination for Usage API and Costs API responses.
- Added cursor support for `next_page`, `next_cursor`, and `after`.
- Added duplicate cursor, malformed cursor, and max-page guards.
- Preserved partial usage/cost data when later pages fail.
- Kept Usage API and Costs API partial failures independent.
- Fixed issue propagation when Costs endpoint is disabled.
- Kept actual OpenAI API cost separate from estimated local Codex cost.

Verification:

- Added mocked tests for usage pagination, costs pagination, partial page failure, duplicate cursor, malformed cursor, max-page guard, independent Usage/Costs failures, and sanitized error bodies.
- `swift run TokenUsageCoreTestRunner` passed.

## Context Explosion Calibration Follow-up

Intended files:

- `Sources/TokenUsageCore/ContextExplosionDetector.swift`
- `Sources/TokenUsageCore/MonitorSettings.swift`
- `Sources/TokenUsageCore/SpendFirewallEvaluator.swift`
- `Sources/TokenUsageMenuBar/TokenUsageMenuBarApp.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`
- `Documentation/Features/CONTEXT_EXPLOSION_DETECTOR.md`
- `Documentation/Features/TOP3_IMPLEMENTATION_LOG.md`

Changes:

- Added `ContextExplosionSettings` to persisted monitor settings.
- Added `ContextExplosionConfidence`.
- Added `triggeredBy` and machine-readable `evidenceMetrics` to findings.
- Added minimum request/sample/token-volume guards.
- Reduced false positives for stable heavy sessions with meaningful output.
- Required repeated-large-context detection to also be input-dominated.
- Surfaced detector confidence through firewall context alerts and menu context rows.

Verification:

- Added tests for stable-heavy false-positive guard, low sample guard, custom threshold settings, confidence, trigger explanations, and evidence metrics.
- `swift run TokenUsageCoreTestRunner` passed.

## Pricing Profile UI Follow-up

Intended files:

- `Sources/TokenUsageCore/CostEstimator.swift`
- `Sources/TokenUsageCore/MonitorSettings.swift`
- `Sources/TokenUsageCore/TokenUsageDisplayModel.swift`
- `Sources/TokenUsageMenuBar/TokenUsageMenuBarApp.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`
- `Documentation/Features/PRICING_PROFILE_EDITOR.md`
- `Documentation/Features/TOP3_IMPLEMENTATION_LOG.md`

Changes:

- Added pricing profile validation for empty names, negative prices, and non-positive multipliers.
- Added settings helpers to apply a validated pricing profile and reset to bundled defaults.
- Added a native menu-driven pricing profile editor for estimated local Codex cost assumptions.
- Added default-profile reset menu actions.
- Updated display labels to distinguish `Estimated local Codex cost` from `Actual OpenAI API cost`.
- Added the OpenAI Costs API / Codex desktop usage caveat to report output.

Verification:

- Added tests for pricing validation, persistence, reset, and cost recalculation after profile changes.
- `swift run TokenUsageCoreTestRunner` passed.

## Firewall Action Center Follow-up

Intended files:

- `Sources/TokenUsageCore/SpendFirewallEvaluator.swift`
- `Sources/TokenUsageMenuBar/TokenUsageMenuBarApp.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`
- `Documentation/Features/FIREWALL_ACTION_CENTER.md`
- `Documentation/Features/TOP3_IMPLEMENTATION_LOG.md`

Changes:

- Added typed firewall action items while preserving legacy string recommendations.
- Added safe actions for project/session breakdown, generic reduce-context prompt copy, restart/compact-context suggestion, TODEX policy switch, and Codex CLI Safe Mode config.
- Marked Codex CLI Safe Mode as confirmation-required and config-modifying.
- Added menu action center and alert cooldown controls.
- Replaced unsafe stop-style recommendation wording with advisory-only language.
- Redacted config/backup paths in config-apply result messages.

Verification:

- Added tests for high burn actions, context actions, Safe Mode confirmation, cooldown, and privacy-safe evidence/actions.
- `swift run TokenUsageCoreTestRunner` passed.

## Track D - AI Spend Firewall

Intended files:

- `Sources/TokenUsageCore/SpendFirewallEvaluator.swift`
- `Sources/TokenUsageCore/MonitorSettings.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`
- `Documentation/Features/AI_SPEND_FIREWALL.md`
- `Documentation/Features/TOP3_IMPLEMENTATION_LOG.md`

Changes:

- Added `SpendFirewallSettings`.
- Added `MonitorFeatureFlag.spendFirewall`, `.contextExplosionDetector`, and `.estimatedLocalCost`.
- Added `SpendFirewallAlertKind`.
- Added `SpendFirewallAlert`.
- Added `SpendFirewallEvaluator`.
- Evaluator supports high burn rate, daily budget risk, project dominance, low output share, possible agent loop, context explosion, permission risk overlap, and cooldown suppression.
- Evidence is numeric and privacy-safe.

Verification:

- `swift run TokenUsageCoreTestRunner` passed.

## Track C - Context Explosion Detector

Intended files:

- `Sources/TokenUsageCore/ContextExplosionDetector.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`
- `Documentation/Features/CONTEXT_EXPLOSION_DETECTOR.md`
- `Documentation/Features/TOP3_IMPLEMENTATION_LOG.md`

Changes:

- Added `ContextExplosionFinding`.
- Added `ContextExplosionDetector`.
- Added shared `SpendFirewallSeverity` for context and firewall features.
- Detector evaluates recent-vs-baseline input/request, absolute large context, input dominance, missing cached input, repeated large context, and project-level spikes.
- Evidence is numeric and privacy-safe.

Verification:

- `swift run TokenUsageCoreTestRunner` passed.
- `swift build && Scripts/test.sh` passed after Track A.

## Track B - Estimated Local Codex Cost

Intended files:

- `Sources/TokenUsageCore/CostEstimator.swift`
- `Sources/TokenUsageCore/TokenUsageModels.swift`
- `Sources/TokenUsageCore/TokenUsageStore.swift`
- `Sources/TokenUsageCore/TokenUsageEngine.swift`
- `Sources/TokenUsageMenuBar/TokenUsageMenuBarApp.swift`
- `Sources/TokenUsageCoreTestRunner/main.swift`
- `Documentation/Features/ESTIMATED_LOCAL_CODEX_COST.md`
- `Documentation/Features/TOP3_IMPLEMENTATION_LOG.md`

Changes:

- Added pricing profile `id`, `notes`, default editable estimate profiles, and legacy decoding.
- Added `TokenCostEstimate` with `isEstimated`.
- Kept `EstimatedTokenCost` as a compatibility typealias.
- Added estimated local cost fields to `TokenUsageStatistics`.
- Added project-level `estimatedLocalCostUSD` to `UsageBreakdown`.
- Local store now computes session/day/week/month/total/project estimated cost from local samples.
- Markdown reports label estimated local Codex cost separately from actual OpenAI API cost.

Verification:

- `swift run TokenUsageCoreTestRunner` passed.
