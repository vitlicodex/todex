# Pricing Profile Editor

TODEX can estimate local Codex cost from local token logs without treating that value as actual billing.

## Purpose

Local Codex session logs expose token counts, but OpenAI Costs API data may not include Codex desktop usage. The pricing profile editor lets the user choose the local estimate assumptions used for:

- estimated local Codex daily cost;
- estimated local Codex weekly cost;
- estimated local Codex monthly cost;
- project-level estimated local cost;
- firewall burn-rate checks.

Actual OpenAI API cost remains separate and comes only from OpenAI Costs API responses.

## Editable Fields

The editor is available from **Settings & Security -> Estimated local Codex cost -> Edit Pricing Profile...**.

It supports:

- profile name;
- input price per 1M tokens;
- cached input price per 1M tokens;
- output price per 1M tokens;
- optional reasoning price per 1M tokens;
- multiplier;
- notes.

Reasoning price can be left blank. Blank reasoning price is stored as zero.

## Validation

TODEX validates pricing profiles before saving:

- profile name cannot be empty;
- prices cannot be negative;
- multiplier must be positive.

Invalid profiles are rejected before they are written to settings storage.

## Default Profiles

The menu includes **Reset to Default Profile** with built-in editable defaults:

- Default Local Codex Estimate;
- Priority Local Codex Estimate;
- Low-Cost Local Estimate.

Resetting changes only local estimate settings. It does not call OpenAI APIs and does not change billing.

## Privacy

Pricing settings contain only numeric estimate assumptions, a profile name, and optional notes. They do not store:

- API keys;
- prompts;
- raw Codex logs;
- raw request bodies;
- full private source paths.

Settings are written through the same private local file writer used by the rest of TODEX settings.

## Labels

All local estimate UI/report labels must use wording equivalent to:

> Estimated local Codex cost

Actual OpenAI cost labels must remain separate:

> Actual OpenAI API cost

Reports also state:

> OpenAI Costs API may not include Codex desktop usage.
