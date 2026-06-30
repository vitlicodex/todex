# Firewall Action Center

The AI Spend Firewall remains advisory by default. It does not kill, pause, or control Codex automatically.

## Purpose

The action center turns firewall alerts into safe next-step commands that help the user reduce spend risk without mutating running work unexpectedly.

## Alert Sources

TODEX can create firewall alerts from:

- high estimated local burn rate;
- estimated daily budget risk;
- project token concentration;
- low output share;
- possible repeated high-token loop pattern;
- context explosion findings;
- permission risk overlap.

Alert evidence is numeric and metadata-only. It must not include raw prompts, raw logs, API keys, Authorization headers, raw request bodies, or full private paths.

## Recommended Actions

Alerts can expose these action-center commands:

- **Open project/session breakdown**: opens the sanitized numeric report.
- **Copy reduce-context prompt**: copies a generic prompt asking Codex to summarize state and shrink context.
- **Suggest restart or compact context**: shows a non-destructive checklist.
- **Switch TODEX policy to Guarded**: changes TODEX monitoring policy only.
- **Switch TODEX policy to Locked Down**: changes TODEX monitoring policy only.
- **Apply Codex CLI Safe Mode config**: requires explicit confirmation and writes a conservative Codex CLI config preset.

The Safe Mode action warns that new CLI sessions or Codex Desktop may need restart before config changes are reflected.

## Confirmation Boundary

Actions that only open reports, copy generic text, or change TODEX monitoring settings do not modify Codex config.

Actions that write Codex CLI config are marked:

- requires confirmation;
- modifies Codex config.

The confirmation dialog explains that TODEX does not alter the already-running Codex Desktop session.

## Cooldown Controls

The firewall menu includes alert cooldown controls:

- Off;
- 5 minutes;
- 15 minutes;
- 60 minutes.

Cooldown suppresses repeated alert kinds for the configured interval. It does not hide new alert kinds or different project-specific alerts.

## Current Limitations

- TODEX does not and should not automatically stop Codex.
- Pause/stop behavior is intentionally left as future research only because it can corrupt active work or surprise the user.
- Firewall actions are based on token/cost metadata and permission metadata, not prompt contents.
