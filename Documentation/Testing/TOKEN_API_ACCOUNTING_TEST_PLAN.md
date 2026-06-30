# Token/API Accounting Test Plan

## Rules

- Use mocks and fixtures only.
- Do not call real OpenAI APIs.
- Do not print or store API keys, Authorization headers, raw prompts, raw Codex logs, raw request bodies, or private full paths.
- Keep actual OpenAI API cost separate from estimated local Codex cost.

## Existing Coverage

The current custom runner covers:

- OpenAI-style usage JSON parsing.
- OpenAI HTTP error classification for 429, 404, 5xx, and timeout.
- OpenAI redirect policy.
- Local estimated cost math.
- Codex `token_count` parsing with `last_token_usage`.
- `cached_input_tokens` preservation.
- parser truncation warnings.
- preservation of same-shaped token requests.
- prompt-like line skipping in Codex session streams.
- invalid non-token line skipping.
- project metadata hashing/labeling.
- Codex permission metadata parsing.
- permission preset writer safety for backup symlink and hardlinked config.
- store aggregation, daily history, display model, legacy migrations, incremental cursors.
- private file symlink/hardlink refusal.
- oversized structured JSON refusal.
- report privacy redaction.
- Markdown actual API cost labels.

## Required Next Fixtures

### OpenAI Usage API

- Multi-page usage response with cursor/next-page fields.
- Missing, empty, and extra fields.
- `model`, `project_id`, and `api_key_id` group-by combinations.
- Audio token fields.
- Reasoning token fields if the API exposes them.

### OpenAI Costs API

- Multi-page costs response.
- Empty amount fields.
- Project/API-key cost breakdowns.
- Costs success while Usage fails.
- Usage success while Costs fails.

### API Errors

- 400 with sanitized body.
- 401 and 403.
- 408.
- 429 with and without `Retry-After`.
- 500, 502, 503.
- Invalid JSON.
- Oversized non-JSON error body.
- Redirect policy with cross-host, downgrade, and same-host cases.

### Local Codex Logs

- Session crossing midnight.
- Timezone boundaries.
- Rotated/truncated files.
- Source replacement with preserved and changed file identity.
- Very long private non-token lines.
- `total_tokens` different from `input_tokens + output_tokens`.
- `reasoning_tokens` or reported-total fields if Codex emits them.

### Reports and Exports

- Markdown golden output.
- JSON export privacy.
- No secrets or raw request bodies.
- No private full paths.
- Source labels: Local Codex logs, OpenAI Usage API, OpenAI Costs API, Estimated local cost.

## Acceptance Criteria

- `swift build` passes.
- `Scripts/test.sh` passes.
- No test performs a real OpenAI API call.
- No fixture contains real secrets or raw private prompts.
- Actual cost and estimated local cost never share one field or one generic label.

