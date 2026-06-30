# AI Spend Firewall

## Purpose

The AI Spend Firewall turns TODEX from a passive token monitor into an active local warning system for runaway Codex usage.

It evaluates numeric local usage, estimated local cost, context explosion findings, and permission risk metadata. It never needs prompts, completions, raw request bodies, API keys, Authorization headers, or full private paths.

## Alert Types

TODEX currently supports:

- **High burn rate**: estimated local cost in the last hour exceeds configured thresholds.
- **Daily budget risk**: estimated local daily cost reaches configured budget ratios.
- **Project dominance**: one project dominates today's local token usage.
- **Low output share**: most tokens are input/context rather than useful output.
- **Possible agent loop**: many similar high-token requests happen in a short window.
- **Context explosion**: integrated from the Context Explosion Detector.
- **Permission risk overlap**: risky permissions overlap with spend risk, such as network enabled with approval disabled.

## Threshold Settings

`SpendFirewallSettings` includes:

- enabled;
- daily estimated budget USD;
- hourly burn warning USD;
- hourly burn critical USD;
- max tokens per request warning;
- max tokens per request critical;
- max project share warning;
- low output share warning;
- agent loop detection enabled;
- context explosion detection enabled;
- alert cooldown minutes.

## Evidence Model

Firewall alert evidence is deliberately constrained to safe technical metadata:

- estimated local cost;
- request count;
- token totals;
- token share percentages;
- pricing profile name;
- safe project label/hash;
- permission mode labels.

It does not contain raw prompts, completions, source paths, Codex log lines, API keys, or Authorization headers.

## Recommended Actions

Alerts recommend actions such as:

- open usage breakdown;
- summarize state and restart Codex;
- reduce workspace scope;
- review generated files;
- switch Codex policy to Guarded or Locked Down.

## Cooldown

Alerts can be suppressed when an equivalent alert was recently emitted. The default cooldown is 15 minutes.

Cooldown matching uses alert kind plus project identity. It does not inspect private content.

## Limitations

- Burn rate is estimated from local token samples and a pricing profile.
- Budget risk uses estimated local cost, not actual OpenAI billing.
- Agent-loop detection is heuristic.
- Firewall actions are currently recommendations; automatic intervention should be added only with explicit user control.

