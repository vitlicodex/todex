# TODEX Features

TODEX is evolving into a local-first AI spend firewall for Codex power users.

Feature docs:

- [Estimated Local Codex Cost](ESTIMATED_LOCAL_CODEX_COST.md)
- [Pricing Profile Editor](PRICING_PROFILE_EDITOR.md)
- [OpenAI Usage and Costs API Pagination](OPENAI_USAGE_COSTS_PAGINATION.md)
- [Context Explosion Detector](CONTEXT_EXPLOSION_DETECTOR.md)
- [AI Spend Firewall](AI_SPEND_FIREWALL.md)
- [Firewall Action Center](FIREWALL_ACTION_CENTER.md)
- [Top 3 Implementation Log](TOP3_IMPLEMENTATION_LOG.md)

## Privacy Baseline

These features use numeric usage statistics and technical metadata only.

They must not store prompts, completions, raw Codex lines, raw request bodies, API keys, Authorization headers, or full private paths.

## Cost Baseline

Actual OpenAI API cost and estimated local Codex cost are separate.

Any local Codex cost computed from local logs is labeled estimated.
