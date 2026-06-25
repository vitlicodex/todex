# OpenAI Usage and Costs API Pagination

TODEX uses mocked tests for OpenAI Usage API and Costs API behavior. Tests must not call real OpenAI endpoints.

## Purpose

OpenAI organization usage and costs endpoints can return paginated responses. A single-page parser can undercount usage or cost when additional pages exist.

TODEX now reads bounded pagination for:

- `/v1/organization/usage/completions`;
- `/v1/organization/costs`.

## Pagination Inputs

TODEX recognizes these cursor fields:

- `next_page` / `nextPage` -> sent as `page`;
- `next_cursor` / `nextCursor` -> sent as `cursor`;
- `after` -> sent as `after`.

If a response says more pages are available but does not provide a valid string or numeric cursor, TODEX keeps the already-read data and surfaces a warning issue.

## Safety Guards

Pagination is bounded:

- maximum 20 pages per endpoint request;
- duplicate cursor detection;
- malformed cursor detection;
- partial data preserved when later pages fail;
- first-page failure still fails the whole source.

The max-page guard prevents loops and runaway requests.

## Partial Failure Behavior

Usage API and Costs API are treated independently:

- Usage succeeds and Costs fails: token usage remains visible, actual API cost is `n/a`, issue is shown.
- Costs succeeds and Usage fails: actual API cost remains visible, token usage remains zero/unknown, issue is shown.
- Later paginated page fails: earlier pages remain visible, issue is shown, status becomes warning.

Actual OpenAI API cost remains separate from estimated local Codex cost.

## Error Sanitization

Non-2xx response bodies are sanitized before becoming UI/report issues. Sanitization redacts:

- API-key-shaped strings;
- bearer tokens;
- Authorization header values;
- environment-style API key assignments.

Errors are truncated to keep diagnostics concise.

## Tests

Mocked tests cover:

- usage multi-page aggregation;
- costs multi-page aggregation;
- later-page server failure preserving partial usage;
- duplicate cursor guard;
- malformed cursor warning;
- max-page guard;
- independent Usage/Costs partial failures;
- sanitized error bodies.

No test uses a real OpenAI API call.
