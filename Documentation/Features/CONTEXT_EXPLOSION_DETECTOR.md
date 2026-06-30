# Context Explosion Detector

## Purpose

The Context Explosion Detector warns when local Codex usage starts spending most tokens on repeated or suddenly enlarged input context.

This is a local-only detector. It uses numeric token samples and safe project metadata only.

## Signals

The detector evaluates:

- recent input tokens per request;
- baseline input tokens per request;
- recent vs baseline multiplier;
- input share of total tokens;
- cached input share;
- repeated large request pattern;
- project-level spikes when project metadata is available.
- confidence based on baseline strength, trigger strength, input dominance, and cached input share.

## Heuristics

TODEX currently detects:

- **Recent input/request spike**: recent average input/request is at least 4x baseline and above the minimum large-context threshold.
- **Absolute large context**: recent input/request is above 100k by default and the recent window is input-dominated.
- **Input dominance**: input tokens are at least 95% of recent total tokens with a large recent token volume.
- **Large uncached input**: recent input is large while cached input is zero.
- **Repeated context reload**: many recent input-dominated requests have similarly large input sizes.

Default false-positive guards:

- at least 10 total samples are required;
- at least 5 recent samples are evaluated;
- at least 5 baseline samples are required for relative-spike detection;
- recent token volume must clear a minimum threshold;
- stable heavy sessions with meaningful output are ignored unless they become input-dominated.

Thresholds are stored in `MonitorSettings.contextExplosion`, so future UI can tune them without changing detector code.

## Severity

- `critical`: huge uncached input or input-dominated work with very low output.
- `warning`: large context with meaningful cached input, or less severe spikes.
- `info`: reserved for future advisory findings.

## Confidence

Findings expose:

- `low`: weak advisory signal or pattern-only finding;
- `medium`: at least one strong trigger;
- `high`: strong baseline plus multiple strong triggers, input dominance, and low cached input.

The AI Spend Firewall includes confidence in context-explosion alert detail and evidence.

## Evidence Fields

Each finding includes:

- `triggeredBy`: stable trigger names;
- `likelyCauses`: generic, privacy-safe explanations;
- `recommendedActions`: generic local actions;
- `evidence`: human-readable numeric evidence;
- `evidenceMetrics`: machine-readable numeric metrics such as baseline input/request, recent input/request, input share, cached share, relative multiplier, and recent request count.

## Recommended Actions

TODEX recommends privacy-safe local actions:

- summarize current state and restart the Codex session;
- narrow the goal or workspace scope;
- review generated files before continuing;
- switch Codex permissions to Guarded or Locked Down if automation is running.

## Privacy

Findings contain:

- numeric token evidence;
- percentages;
- request counts;
- safe project labels/hashes when available.

Findings do not contain:

- prompts;
- completions;
- raw Codex lines;
- raw request bodies;
- API keys or Authorization headers;
- full private paths.

## Relationship To AI Spend Firewall

The AI Spend Firewall can consume context explosion findings as one of its alert signals. Context explosion is usually an input-side spending problem; the firewall turns that into budget/burn-rate alerts and recommended actions.

## Limitations

- The detector is heuristic, not a billing source of truth.
- It cannot know which exact files caused context growth without reading private prompt/content data, which TODEX intentionally avoids.
- Project-level detection requires safe project metadata in local samples.
