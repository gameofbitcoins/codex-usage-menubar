# Codex Usage

A small native macOS menu-bar utility that shows Codex usage limits without opening the Codex usage menu.

> **Unofficial project.** This project is not affiliated with, endorsed by, or maintained by OpenAI. Codex, ChatGPT, and OpenAI are trademarks of their respective owner.

## What it shows

The menu bar displays remaining usage, for example:

```text
Codex 65%
```

If Codex returns two shared usage windows, both percentages are shown. Click the menu-bar item to see the window duration, reset time, manual refresh, **Launch at Login**, and Quit.

## Requirements

- macOS 13 or later
- Apple Command Line Tools (the installer compiles the small Swift app locally)
- One of:
  - ChatGPT.app with its bundled Codex app-server
  - Codex.app with its bundled Codex app-server
  - a standalone Codex CLI installation

## Install

1. Download or clone this repository.
2. Double-click **Install Codex Usage.command**.
3. If macOS blocks the script, approve this specific file in **System Settings → Privacy & Security**.
4. The app is built locally and installed to:

```text
~/Applications/Codex Usage.app
```

The installer enables **Launch at Login** by default. You can turn it off from the menu-bar dropdown.

If Apple Command Line Tools are missing:

```bash
xcode-select --install
```

## Privacy

Codex Usage is designed to minimize access to personal data:

- It does **not** read browser cookies.
- It does **not** read Codex/ChatGPT auth-token files.
- It does **not** read prompts, conversations, project files, or repositories.
- It does **not** include analytics, telemetry, crash reporting, or advertising.
- It does **not** upload its own logs or data anywhere.
- It launches the Codex app-server already installed on the Mac and requests only `account/rateLimits/read`.
- The quota response is parsed in memory; raw quota responses are not written to disk.
- It stores only the local filesystem path to the discovered Codex executable at:

```text
~/Library/Application Support/Codex Usage/codex-path
```

The Codex app-server itself may communicate with OpenAI using the user's existing Codex/ChatGPT authentication. That behavior belongs to Codex, not to this menu-bar utility.

### Local diagnostics

The utility may create these local-only files:

```text
~/Library/Logs/CodexUsage.log
~/Library/Logs/CodexUsage-appserver.log
```

They are never uploaded automatically. Error logs can sometimes contain local filesystem paths or other machine-specific diagnostic details, so review/redact them before posting them publicly in an issue.

## How it works

The app is a small native AppKit program using `NSStatusItem`.

It discovers a Codex executable from common desktop-app/CLI locations, then starts:

```text
codex app-server --listen stdio://
```

It performs the app-server initialization handshake and requests:

```text
account/rateLimits/read
```

The app prefers the shared `codex` bucket returned in `rateLimitsByLimitId` and falls back to `rateLimits`.

No third-party runtime libraries are bundled.

## Launch at Login

The installer creates a per-user LaunchAgent:

```text
~/Library/LaunchAgents/com.codexusage.menubar.plist
```

The **Launch at Login** menu item adds or removes that file. Disabling it does not quit the currently running app.

## Uninstall

Double-click:

```text
Uninstall Codex Usage.command
```

The uninstaller removes the app and its LaunchAgent. It intentionally does not delete diagnostic logs automatically.

## Build from source

The installer uses the Swift compiler included with Apple Command Line Tools:

```bash
xcrun swiftc -O -framework Cocoa src/CodexUsageMenu.swift -o CodexUsage
```

The installed app is ad-hoc signed locally. Public binary distribution would require your own Apple Developer signing/notarization setup.

## Security

This project never needs your OpenAI password, API key, session token, or browser data. Do not add credentials, logs from your machine, or generated `codex-path` files to commits.

See [PRIVACY.md](PRIVACY.md) for the data-access summary.

## License

MIT. See [LICENSE](LICENSE).
