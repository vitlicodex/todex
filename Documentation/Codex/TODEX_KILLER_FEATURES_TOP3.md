# TODEX Killer Features Build Plan

This document expands the top 3 killer features for TODEX and provides a multi-agent Codex orchestrator to build them safely.

Repository: `https://github.com/vitlicodex/todex`

Top 3 features:

1. AI Spend Firewall
2. Context Explosion Detector
3. Estimated Local Codex Cost

Product positioning:

> TODEX is a local AI spend firewall for Codex power users. It tells you how much Codex is burning, why it is burning, and when to stop it.

---

## Global Rules

Use these rules for every agent, track, and implementation stage.

- Defensive/product work only.
- Do not call real OpenAI APIs in tests; use mocks and fixtures.
- Do not print real API keys, Authorization headers, prompts, raw Codex logs, raw request bodies, or full private paths.
- Preserve local-first privacy guarantees.
- Do not store prompt/completion content.
- Store only numeric usage, metadata, stable project hash, and safe project label.
- Keep actual OpenAI Costs API data separate from estimated local Codex-equivalent cost.
- Any cost based on local Codex logs must be labeled `estimated`.
- Prefer TDD: add failing tests or fixtures first, then implement.
- Keep patches small and staged.
- Run `swift build` and `Scripts/test.sh` after code changes.
- If a change is risky, document it instead of silently implementing.
- Avoid multiple agents editing the same files at the same time.

---

# Feature 1 — AI Spend Firewall

## Goal

Detect runaway Codex usage early and warn the user before cost explodes.

TODEX should move from passive reporting to active protection:

- detect high burn rate;
- detect runaway token growth;
- detect dangerous project-level spend;
- detect expensive agent-loop behavior;
- recommend concrete actions;
- optionally trigger local-safe actions such as switching TODEX policy or suggesting Codex Safe Mode.

## User Story

As a Codex power user, I want TODEX to warn me when Codex starts burning tokens abnormally, so I can stop an agent loop, restart a session, reduce context, or switch permissions before spending hundreds or thousands of dollars.

## Core Signals

The firewall should evaluate these signals from local Codex logs and available API/cost data:

1. Tokens per minute.
2. Estimated dollars per hour.
3. Tokens per request.
4. Input/output ratio.
5. Output share.
6. Project share of total daily spend.
7. Request frequency.
8. Repeated request pattern.
9. Permission risk overlap, such as network enabled with no approval.
10. Current budget usage and forecast.

## Alert Types

### Alert 1 — High Burn Rate

Trigger when estimated local burn rate exceeds configured threshold.

Example:

```text
High AI burn rate detected.
Current pace: 18.4M tokens/hour.
Estimated cost: $92/hour.
```

### Alert 2 — Daily Budget Risk

Trigger when estimated daily cost exceeds configured budget percentage.

Example:

```text
Daily AI budget risk.
Estimated local Codex cost reached 82% of today's budget.
```

### Alert 3 — Project Dominance

Trigger when one project consumes most daily tokens.

Example:

```text
Project spend concentration detected.
todex consumed 91% of local Codex tokens today.
```

### Alert 4 — Expensive Low-Output Work

Trigger when output is unusually low relative to input.

Example:

```text
Most spend is input/context.
Output is only 0.4% of total tokens.
```

### Alert 5 — Agent Loop Suspected

Trigger when repeated requests happen quickly with similar token sizes and low output variation.

Example:

```text
Possible agent loop detected.
212 requests in 20 minutes with similar token sizes.
```

## Recommended Actions

The UI should provide actions, not only warnings:

- Open session breakdown.
- Show project breakdown.
- Suggest restarting Codex session.
- Suggest asking Codex to summarize state and start a fresh session.
- Suggest reducing workspace scope.
- Suggest reviewing generated/build folders.
- Suggest switching TODEX policy to Guarded or Locked Down.
- If supported safely: apply Codex CLI Safe Mode config.
- Copy a short “reduce context” prompt.

## Configuration

Add settings:

```text
Firewall enabled: true/false
Daily estimated budget USD
Hourly burn warning USD
Hourly burn critical USD
Max tokens per request warning
Max tokens per request critical
Max project share warning
Agent loop detection enabled
Context explosion detection enabled
Alert cooldown minutes
```

## Data Model Proposal

Add or adapt:

```swift
public enum SpendFirewallSeverity: String, Codable, Sendable {
    case info
    case warning
    case critical
}

public enum SpendFirewallAlertKind: String, Codable, Sendable {
    case highBurnRate
    case dailyBudgetRisk
    case projectDominance
    case lowOutputShare
    case possibleAgentLoop
    case contextExplosion
    case permissionRiskOverlap
}

public struct SpendFirewallAlert: Codable, Equatable, Sendable {
    public var id: String
    public var kind: SpendFirewallAlertKind
    public var severity: SpendFirewallSeverity
    public var title: String
    public var detail: String
    public var evidence: [String]
    public var recommendedActions: [String]
    public var projectID: String?
    public var projectName: String?
    public var createdAt: Date
}
```

Add evaluator:

```swift
public struct SpendFirewallEvaluator {
    public func evaluate(
        snapshot: TokenUsageStatistics,
        settings: MonitorSettings,
        pricing: TokenPricingProfile?
    ) -> [SpendFirewallAlert]
}
```

## Privacy Requirements

The firewall must not store or show prompts, completions, raw Codex lines, or full project paths.

Allowed evidence:

```text
tokens per minute
tokens per request
input/output ratio
estimated cost
request count
project label
project hash
permission mode
time window
```

## Tests

Add tests for:

- high burn rate alert;
- critical burn rate alert;
- project dominance alert;
- low output share alert;
- no alert under normal usage;
- alert cooldown;
- estimated cost missing but token alerts still work;
- privacy: no prompt/raw path in alert evidence;
- permission overlap alert when network + approval never are active.

## Documentation

Create:

```text
Documentation/Features/AI_SPEND_FIREWALL.md
```

Include:

- feature purpose;
- signal definitions;
- thresholds;
- examples;
- privacy guarantees;
- limitations;
- future actions.

---

# Feature 2 — Context Explosion Detector

## Goal

Detect when Codex starts sending too much context repeatedly, causing massive input token usage.

This is the likely driver behind many huge Codex bills: input tokens dominate output tokens because the tool repeatedly sends a large workspace/session context.

## User Story

As a heavy Codex user, I want TODEX to detect when context/request suddenly grows, so I can restart the session, compact context, narrow the task, or clean up the repo.

## Core Signals

1. Average input tokens per request.
2. Median input tokens per request.
3. Recent-window input/request vs baseline.
4. Input/output ratio.
5. Output share.
6. Cached input share.
7. Repeated large input requests.
8. Project-level input spike.
9. Session age or request count.
10. Sudden growth after a project or file set changes.

## Detection Heuristics

### Heuristic 1 — Relative Spike

Trigger when recent input/request is much higher than baseline.

Example:

```text
recent average input/request > baseline average * 4
and recent average input/request > 50,000
```

### Heuristic 2 — Absolute Large Context

Trigger when input/request exceeds a configured threshold.

Example:

```text
input/request > 100,000
```

### Heuristic 3 — Input Dominance

Trigger when most tokens are input.

Example:

```text
input tokens > 95% of total tokens
and total tokens > 1,000,000 in recent window
```

### Heuristic 4 — Cached Input Missing

Trigger when input is huge but cached input is near zero.

Example:

```text
input > 10,000,000
cachedInput == 0
```

### Heuristic 5 — Repeated Context Reload

Trigger when many consecutive requests have similar large input sizes.

Example:

```text
10+ requests in a short window
input/request variance low
output share low
```

## UI Copy

Example alert:

```text
Context Explosion Detected

Average input/request increased from 18k to 146k.
Most spend is repeated context, not model output.

Likely causes:
- long Codex session;
- repeated workspace reloads;
- large repo context;
- generated files or reports in workspace;
- missing cached input.

Recommended actions:
- ask Codex to summarize state and restart;
- narrow the goal;
- review large generated files;
- reduce workspace scope;
- consider Safe Mode or Guarded mode.
```

## Data Model Proposal

```swift
public struct ContextExplosionFinding: Codable, Equatable, Sendable {
    public var severity: SpendFirewallSeverity
    public var projectID: String?
    public var projectName: String?
    public var baselineInputPerRequest: Double
    public var recentInputPerRequest: Double
    public var inputShare: Double
    public var cachedInputShare: Double?
    public var requestCount: Int
    public var timeWindowDescription: String
    public var likelyCauses: [String]
    public var recommendedActions: [String]
}
```

Add detector:

```swift
public struct ContextExplosionDetector {
    public func detect(
        samples: [TokenUsageSample],
        settings: MonitorSettings
    ) -> [ContextExplosionFinding]
}
```

## Required Parser Support

This feature depends on accurate sample data:

- preserve `cached_input_tokens`;
- preserve reported total;
- preserve computed total;
- keep project hash/label;
- keep timestamp;
- avoid dedup collapsing distinct requests.

## Tests

Add deterministic fixtures:

1. Normal session, no alert.
2. Sudden jump from 10k to 120k input/request.
3. Huge input with low output.
4. Huge input with cached input present, lower severity.
5. Same project context explosion.
6. Multiple projects, only one exploding.
7. Long session with gradual drift.
8. Privacy: no prompt/full path in finding.
9. Same timestamp duplicate requests should not be collapsed before detection.
10. Empty samples should produce no finding.

## Documentation

Create:

```text
Documentation/Features/CONTEXT_EXPLOSION_DETECTOR.md
```

Include:

- problem statement;
- detection heuristics;
- examples;
- limitations;
- privacy model;
- relationship to Spend Firewall.

---

# Feature 3 — Estimated Local Codex Cost

## Goal

Calculate and display estimated cost for local Codex token usage, even when OpenAI Costs API does not include Codex desktop tokens.

This feature must make a strict distinction:

- actual OpenAI Platform API cost from Costs API;
- estimated local Codex-equivalent cost from local logs.

## User Story

As a user who runs Codex locally all day, I want TODEX to estimate how much local Codex usage would cost by token pricing, so I can understand risk and budget even when official billing APIs do not expose Codex desktop usage.

## Core Requirements

1. Add pricing profiles.
2. Estimate local cost from local Codex samples.
3. Separate input, cached input, output, optional reasoning tokens.
4. Support multiplier for priority/fast modes.
5. Clearly label estimated cost.
6. Keep actual OpenAI API Costs separate.
7. Support daily/week/month/project/session summaries.
8. Make costs visible in menu, reports, and alerts.
9. Allow user to configure pricing.
10. Do not claim estimated cost is actual billing.

## Pricing Profile

Suggested data model:

```swift
public struct TokenPricingProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var inputPerMillionUSD: Double
    public var cachedInputPerMillionUSD: Double
    public var outputPerMillionUSD: Double
    public var reasoningPerMillionUSD: Double?
    public var multiplier: Double
    public var notes: String?
}
```

Default profile examples:

```text
Custom
GPT-5.5 Standard Estimate
GPT-5.5 Priority Estimate
Low-Cost Model Estimate
```

Avoid hardcoding claims that may become outdated. Let users edit prices.

## Cost Estimate Model

```swift
public struct TokenCostEstimate: Codable, Equatable, Sendable {
    public var inputCostUSD: Double
    public var cachedInputCostUSD: Double
    public var outputCostUSD: Double
    public var reasoningCostUSD: Double?
    public var totalCostUSD: Double
    public var pricingProfileName: String
    public var isEstimated: Bool
}
```

Cost formula:

```text
nonCachedInput = max(inputTokens - cachedInputTokens, 0)
inputCost = nonCachedInput / 1_000_000 * inputPrice
cachedCost = cachedInputTokens / 1_000_000 * cachedInputPrice
outputCost = outputTokens / 1_000_000 * outputPrice
reasoningCost = reasoningTokens / 1_000_000 * reasoningPrice, if available
total = (inputCost + cachedCost + outputCost + reasoningCost) * multiplier
```

## UI Labels

Use exact labels:

```text
Estimated local Codex cost
Actual OpenAI API cost
OpenAI Costs API does not necessarily include Codex desktop usage
Pricing profile: GPT-5.5 Standard Estimate
```

Avoid:

```text
Codex bill
actual Codex cost
OpenAI cost for Codex
```

unless the code proves it.

## Tests

Add tests for:

- input-only cost;
- output-only cost;
- cached input cost;
- mixed input/cached/output;
- multiplier;
- zero tokens;
- unknown pricing profile;
- project cost sum equals total cost;
- estimated local cost never overwrites actual API cost;
- reports label estimated vs actual correctly;
- UI/report redaction.

## Documentation

Create:

```text
Documentation/Features/ESTIMATED_LOCAL_CODEX_COST.md
```

Include:

- exact formula;
- example calculations;
- actual vs estimated explanation;
- pricing profile configuration;
- limitations;
- privacy model.

---

# Multi-Agent Implementation Orchestrator

Use this `/goal` after saving this file as:

```text
Documentation/Codex/TODEX_KILLER_FEATURES_TOP3.md
```

## Parallel / Multi-Agent Goal

```text
/goal
Read Documentation/Codex/TODEX_KILLER_FEATURES_TOP3.md and build the top 3 TODEX killer features as a coordinated multi-agent program.

Features:
1. AI Spend Firewall
2. Context Explosion Detector
3. Estimated Local Codex Cost

If true parallel agents, multiple worktrees, or parallel tasks are available, split work into separate tracks. If not available, simulate the tracks sequentially while preserving file ownership boundaries.

Global rules:
- Do not call real OpenAI APIs in tests.
- Do not print real API keys, Authorization headers, prompts, raw Codex logs, raw request bodies, or full private paths.
- Preserve local-first privacy guarantees.
- Add tests before fixes where practical.
- Run swift build and Scripts/test.sh after each track and after integration.
- Keep actual OpenAI API cost separate from estimated local Codex cost.
- Mark all local Codex cost as estimated.
- Do not let tracks edit the same files at the same time.
- If working tree is dirty, summarize changes before editing.
- If a change is risky, document it instead of silently implementing.

Track A — Data Model, Parser, and Accounting Foundation
Owns:
- TokenUsageModels
- TokenUsageParser
- core aggregation/accounting files
Focus:
- cached_input_tokens support
- reportedTotal vs computedTotal semantics
- stable dedup identity
- truncation warnings
- sample-level project metadata
- fields needed by all three killer features
Deliver:
- tests for parser/accounting edge cases
- migration-safe model changes
- summary of changed data contracts

Track B — Estimated Local Codex Cost
Owns:
- pricing profile model
- cost estimator
- cost aggregation
- cost tests/fixtures
Focus:
- TokenPricingProfile
- TokenCostEstimate
- default editable pricing profiles
- daily/week/month/project estimated cost
- strict actual vs estimated labels
Deliver:
- Documentation/Features/ESTIMATED_LOCAL_CODEX_COST.md
- tests for formula, multiplier, cached input, and report labels

Track C — Context Explosion Detector
Owns:
- detector logic
- context findings model
- detector tests/fixtures
Focus:
- recent vs baseline input/request
- input dominance
- cached input missing
- repeated context reload pattern
- per-project context explosion
Deliver:
- Documentation/Features/CONTEXT_EXPLOSION_DETECTOR.md
- tests for normal, spike, huge input, low output, cached input, multi-project

Track D — AI Spend Firewall
Owns:
- firewall evaluator
- alert model
- threshold settings
- alert tests/fixtures
Focus:
- high burn rate
- budget risk
- project dominance
- low output share
- possible agent loop
- context explosion integration
- recommended actions
Deliver:
- Documentation/Features/AI_SPEND_FIREWALL.md
- tests for warning/critical alerts, cooldown, privacy-safe evidence

Track E — UI, Reports, and Integration
Owns:
- menu/UI files
- report/export files
- settings UI
- documentation index
Focus:
- show estimated local cost
- show actual API cost separately
- show firewall alerts
- show context explosion findings
- add pricing settings
- add clear labels and privacy-safe text
Deliver:
- UI/report integration
- report redaction tests where practical
- updated help/docs
- integration summary

Coordination:
1. Each track writes a short plan and intended files before editing.
2. Detect file overlap before editing.
3. Prefer branches/worktrees:
   - codex/top3-foundation
   - codex/top3-cost
   - codex/top3-context
   - codex/top3-firewall
   - codex/top3-ui
4. Merge order:
   1. Track A foundation
   2. Track B cost
   3. Track C context detector
   4. Track D spend firewall
   5. Track E UI/report integration
5. Run swift build and Scripts/test.sh after each merge.
6. If conflicts happen, resolve conservatively and rerun tests.
7. Final output must include changed files, tests added, docs added, build/test results, known limitations, and next recommended improvements.

Priority:
P0:
- cached_input_tokens support
- estimated local Codex cost
- actual vs estimated cost separation
- context explosion detection
- high burn-rate alerts

P1:
- agent loop detection
- project dominance alerts
- budget forecast
- pricing profile UI
- report integration

P2:
- advanced timeline views
- goal ROI
- repo hygiene advisor
- permission timeline integration

Start by auditing the current code and tests. Then implement Track A first. Do not begin other tracks until Track A data contracts are clear.
```

---

# Sequential Fallback Orchestrator

Use this if Codex cannot run multiple agents safely.

```text
/goal
Read Documentation/Codex/TODEX_KILLER_FEATURES_TOP3.md and implement the top 3 killer features sequentially.

Order:
1. Foundation: parser/model/accounting fields needed by all features.
2. Estimated Local Codex Cost.
3. Context Explosion Detector.
4. AI Spend Firewall.
5. UI/reports/settings integration.
6. Docs and final polish.

Rules:
- Do not call real OpenAI APIs in tests.
- Do not print keys/prompts/raw logs/full paths.
- Preserve privacy guarantees.
- Add tests before fixes where practical.
- Keep actual API cost separate from estimated local Codex cost.
- Mark local Codex cost as estimated.
- Run swift build and Scripts/test.sh after each stage.
- Document risky or large changes instead of silently implementing.

For each stage:
1. Plan.
2. List files to touch.
3. Add tests/fixtures.
4. Implement.
5. Run build/tests.
6. Summarize.

Final output:
- features completed;
- changed files;
- tests added;
- docs added;
- build/test results;
- remaining limitations;
- next recommended goal.
```
