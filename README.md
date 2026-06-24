# TODEX

<img src="Assets/Brand/todex-logo-graphite.svg" alt="TODEX logo" width="420">

Native macOS menu bar app for monitoring Codex token usage, OpenAI API usage, and local Codex permission risk.

TODEX is built for people who run Codex all day and want a quiet, local-first usage monitor that does not become another heavy desktop app.

![Main menu overview](Documentation/Help/images/menu-overview.png)

## Highlights

- Native AppKit menu bar app.
- Compact menu bar status item: `TODEX`. Full usage details live in the dropdown and tooltip.
- Local Codex `token_count` monitoring from `~/.codex/sessions/**/*.jsonl`.
- Optional OpenAI Usage API and Costs API monitoring.
- Encrypted local API key vault with macOS device-owner authentication.
- Codex permission monitoring with five local policy presets.
- Safe numeric Markdown and JSON reports.
- Persistent day, week, and month usage history.
- Daily Codex project token breakdown without storing full project paths.
- Apple Silicon native release bundle support.
- No prompt content storage.
- No third-party telemetry.

## Privacy Model

The app stores numeric usage statistics and technical metadata only.

It does not store:

- prompt contents;
- completion contents;
- plaintext API keys;
- raw request bodies;
- chat transcripts.

Raw Codex session files may contain private content. The app stream-reads only token and permission metadata where possible, and warns before opening raw source files.

## Install Locally

Requirements:

- macOS 13 or newer
- Xcode command line tools
- Swift 6 compatible toolchain

Build and run from source:

```bash
swift run TODEX
```

Install a local app bundle:

```bash
Scripts/install-app.sh
open "$HOME/Applications/TODEX.app"
```

The installed app appears in the macOS menu bar. It keeps running until **Quit App** is selected from the dropdown.

The app is a background menu bar utility, so it does not appear in the Dock or Cmd-Tab. A small control window opens on launch with an **Open Menu** button in case macOS hides the `TODEX` menu bar item.

## Build

```bash
swift build
Scripts/test.sh
Scripts/make-app-bundle.sh
```

On Apple Silicon Macs, `Scripts/make-app-bundle.sh` builds a native `arm64` release binary and marks the app for native execution.

## Menu Structure

The dropdown starts with a compact dashboard and groups everything else by workflow:

- **Overview**: refresh, token totals, input/output, averages, costs.
- **Usage Log**: today, yesterday, week, month, week/month calendar, and Codex projects today.
- **Reports & Data**: reports, exports, source file, model/project/API key breakdowns.
- **Codex Permissions**: current permission state and local policy toggles.
- **API Key & Security**: unlock, lock, set, clear, clipboard session key.
- **App Settings**: launch at login.
- **Advanced**: feature switches, resets, diagnostics.

If the menu bar is crowded, launch the app again and use the control window's **Open Menu** button.

## Data Sources

### Local Codex Logs

The primary Codex source is:

```text
~/.codex/sessions/**/*.jsonl
```

For Codex `token_count` events, the app imports `last_token_usage` as the per-request sample and ignores cumulative `total_token_usage` to avoid double counting.

Daily, weekly, and monthly history is computed from the local persisted sample store:

```text
~/Library/Application Support/TODEX/stats.json
```

The current day's totals are not reset when the app restarts. **Reset Session Statistics** only starts a new session baseline; it does not clear day/month history. **Reset All Statistics** clears persisted history after confirmation.

When Codex `session_meta` or `turn_context` metadata contains a workspace path, the app stores only:

- a stable hash of the normalized path;
- the last folder name as the project label.

It does not store full Codex project paths in project breakdown rows.

Custom source paths can be provided before launch:

```bash
CODEX_TOKEN_USAGE_PATHS="/path/to/usage.json:/path/to/logs" swift run TODEX
```

### OpenAI Usage API

Optional API mode uses:

```text
GET /v1/organization/usage/completions
GET /v1/organization/costs
```

The API key must have access to organization usage and cost endpoints. These endpoints count OpenAI Platform API usage; they do not count Codex desktop chat tokens.

## API Key Security

The key is saved in:

```text
~/Library/Application Support/TODEX/api-key.vault.json
```

Vault behavior:

- AES-GCM encryption.
- PBKDF2-HMAC-SHA256 key derivation.
- 600,000 PBKDF2 iterations for new vaults.
- Random per-vault salt.
- Authenticated vault metadata.
- `0600` file permissions.
- Owner, mode, and symlink validation before decrypting.
- Local encryption password plus Touch ID or macOS password before decrypting.
- Clipboard clearing after the app pastes a matching key.
- Auto-lock after 10 minutes.

The local encryption password must be at least 16 characters and use a mix of character types.

## Codex Permission Monitoring

![Codex permissions](Documentation/Help/images/permissions.png)

The app monitors local Codex permission metadata from:

```text
~/.codex/config.toml
~/.codex/sessions/**/*.jsonl
```

The menu shows approval policy, sandbox policy, filesystem policy, network access, trusted workspace count, and local policy violations.

TODEX permission presets are an alert policy for the monitor. They compare the current Codex session against the selected risk level and flag violations. They do not silently change the permissions of an already-running Codex Desktop session.

The **Apply Preset to Codex CLI Config** action can write the selected preset to:

```toml
approval_policy = "..."
sandbox_mode = "..."

[sandbox_workspace_write]
network_access = true
```

That action creates a local backup and affects new Codex CLI sessions after restart. Existing Codex Desktop sessions may continue using their current permission mode until changed in Codex or restarted.

Permission presets:

- **Level 1: Full Access**
- **Level 2: Automation**
- **Level 3: Balanced**
- **Level 4: Guarded**
- **Level 5: Locked Down**

This policy layer is local to the menu bar app. It does not silently rewrite Codex runtime permissions.

## Stored Files

```text
~/Library/Application Support/TODEX/stats.json
~/Library/Application Support/TODEX/settings.json
~/Library/Application Support/TODEX/api-key.vault.json
~/Library/Logs/TODEX.log
```

Stored files are written with private user permissions where possible.

## Launch at Login

Enable **Launch at Login** from the installed `.app` bundle. The app refuses to create a LaunchAgent when running through `swift run` or a build folder.

The LaunchAgent is written to:

```text
~/Library/LaunchAgents/local.todex.plist
```

## Documentation

The in-app help is maintained in [Documentation/Help/HELP.md](Documentation/Help/HELP.md).

Brand assets live in [Assets/Brand](Assets/Brand). The logo system uses a simple TODEX wordmark, a token-meter `O`, and a small gold crown accent.

Regenerate help images:

```bash
swift Scripts/generate-help-images.swift
```

Regenerate the macOS app icon:

```bash
swift Scripts/generate-app-icon.swift
```

## Security

See [SECURITY.md](SECURITY.md).

Security boundaries:

- Device-owner authentication gates decrypt; it does not make a same-user compromised process impossible to inspect.
- A weak local encryption password can still be attacked offline if the vault file is stolen.
- Public binary releases should use Developer ID signing, hardened runtime, and notarization.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

Before opening a pull request:

```bash
swift build
Scripts/test.sh
Scripts/make-app-bundle.sh
```

## License

MIT. See [LICENSE](LICENSE).
