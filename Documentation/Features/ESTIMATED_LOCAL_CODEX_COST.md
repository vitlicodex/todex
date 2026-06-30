# Estimated Local Codex Cost

## Purpose

TODEX can estimate local Codex-equivalent cost from local token samples even when the OpenAI Costs API does not expose Codex desktop usage.

This value is always an estimate. It must not be described as a bill, charge, or actual OpenAI cost.

## Actual vs Estimated

TODEX keeps two cost surfaces separate:

- **Actual OpenAI API cost**: values returned by the OpenAI Costs API.
- **Estimated local Codex cost**: local Codex token samples multiplied by a user-editable pricing profile.

Local estimated cost never writes to `dailyCostUSD` or `monthlyCostUSD`.

## Formula

```text
nonCachedInput = max(inputTokens - cachedInputTokens, 0)
inputCost = nonCachedInput / 1_000_000 * inputPrice
cachedCost = cachedInputTokens / 1_000_000 * cachedInputPrice
outputCost = outputTokens / 1_000_000 * outputPrice
reasoningCost = reasoningTokens / 1_000_000 * reasoningPrice
total = (inputCost + cachedCost + outputCost + reasoningCost) * multiplier
```

## Data Model

`TokenPricingProfile` contains:

- `id`
- `name`
- input price per million tokens
- cached input price per million tokens
- output price per million tokens
- reasoning price per million tokens
- multiplier
- optional notes

`TokenCostEstimate` contains:

- component costs;
- total cost;
- pricing profile name;
- `isEstimated = true`.

`TokenUsageStatistics` keeps estimated local fields separate:

- `estimatedLocalSessionCostUSD`
- `estimatedLocalDailyCostUSD`
- `estimatedLocalWeeklyCostUSD`
- `estimatedLocalMonthlyCostUSD`
- `estimatedLocalTotalCostUSD`
- `estimatedLocalPricingProfileName`

`UsageBreakdown` can also carry `estimatedLocalCostUSD` for project-level local estimates.

## Default Profiles

TODEX ships editable estimate profiles. They are starting assumptions, not official prices:

- Default Local Codex Estimate
- Priority Local Codex Estimate
- Low-Cost Local Estimate

Users should update prices when their actual model/pricing assumptions differ.

## Privacy

Estimated cost uses numeric token counts and safe project metadata only.

It does not require prompts, completions, raw Codex logs, API keys, Authorization headers, request bodies, or full private paths.

## Limitations

- Estimated local Codex cost may not match actual billing.
- Cached input semantics depend on what local Codex logs report.
- Reasoning tokens are only included when present in parsed token samples.
- UI editing for pricing profiles is a follow-up integration task.

