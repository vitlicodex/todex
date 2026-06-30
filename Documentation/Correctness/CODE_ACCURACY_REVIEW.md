# Code Accuracy Review

## Scope

This review covers the correctness areas most likely to mislead users:

- token request accounting;
- actual OpenAI API cost labeling;
- local Codex estimated-cost boundaries;
- Codex permission risk classification;
- privacy-safe reports and exports.

## Top Correctness Issues

| ID | Severity | Area | Finding | Status |
| --- | --- | --- | --- | --- |
| TDX-COR-001 | Medium | OpenAI API transport | Redirect behavior was not explicitly constrained to the original HTTPS API host. | Fixed |
| TDX-COR-002 | Medium | Permission monitor | `sandbox_policy.network_access` accepted booleans but did not classify string values like `restricted` or `disabled`. | Fixed |
| TDX-COR-003 | Medium | UI/report labels | Generic `cost` labels could be confused with local Codex estimated cost. | Fixed |
| TDX-COR-004 | High | API accounting | Usage/Costs pagination needed bounded cursor handling. | Fixed |
| TDX-COR-005 | Medium | Cost accounting | Local estimated costs needed separate user-facing statistics and labels. | Fixed |
| TDX-COR-006 | Medium | Permission monitor | Trusted workspace counting was line-based rather than project-table aware. | Fixed |

## Correct Semantics

### Requests

In TODEX, a request means a model/token usage sample. It is not guaranteed to equal a visible user prompt. Background context reloads, tool/model calls, and automation steps can create additional samples.

### Local Codex Tokens

Local Codex token accounting should use `last_token_usage` deltas from `token_count` events. Cumulative `total_token_usage` must not be summed repeatedly.

### Cached Input

`cached_input_tokens` should be preserved separately because it can have different cost semantics from uncached input tokens.

### Actual API Cost

`dailyCostUSD` and `monthlyCostUSD` represent actual OpenAI Platform API cost data when returned by the OpenAI Costs API. They must not be used for estimated local Codex log cost.

### Estimated Local Cost

Local Codex estimated cost should remain explicitly estimated and should use separate fields, labels, and report sections when wired into the product.

## Patches Made

- Added `OpenAIRedirectPolicy` and a default `URLSessionTaskDelegate` that blocks cross-host, downgrade, and port-changing redirects.
- Changed `CodexPermissionMonitor` to parse `sandbox_policy.network_access` through the same policy parser used by other network fields.
- Changed trusted workspace counting to only count trusted Codex project tables.
- Changed user-facing cost labels to `API COST`, `Actual API daily cost`, `Actual API monthly cost`, and `Actual OpenAI API ... cost`.
- Added Usage/Costs pagination with duplicate cursor, malformed cursor, and max-page guards.
- Added estimated local Codex cost fields, pricing profile settings, and report/menu labels.

## Tests Added

- `OpenAI redirect policy`
- `OpenAI Usage API pagination`
- `OpenAI Costs API pagination`
- `OpenAI pagination partial failure`
- `OpenAI usage/costs independent partial failures`
- `Codex permission sandbox network strings`
- `Codex permission network and trust parsing`
- `Usage store estimated local cost separation`
- `Pricing profile cost recalculation`
- `Markdown actual API cost labels`

## Remaining Uncertainty

- A centralized report renderer should be introduced before more report formats are added.
- Privacy mode can still be stricter for project labels and API key IDs in screenshots and reports.
