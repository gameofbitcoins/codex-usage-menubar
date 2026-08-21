# Privacy

Codex Usage is a local macOS menu-bar utility.

## Data the utility requests

The utility asks the locally installed Codex app-server for the `account/rateLimits/read` result. It uses:

- percentage of a usage window already consumed;
- usage-window duration;
- usage-window reset timestamp;
- available reset-credit count, when supplied.

It does not intentionally request conversation content, prompt content, repository content, browser data, or account credentials.

## Data stored locally

The utility can store:

- the filesystem path of the discovered Codex executable;
- startup/refresh/error diagnostic logs;
- a LaunchAgent plist when **Launch at Login** is enabled.

No raw successful rate-limit response is persisted by the utility.

## Network behavior

Codex Usage does not implement its own HTTP client or analytics/telemetry service. It launches the locally installed Codex app-server. Codex may communicate with OpenAI using the user's existing authenticated session.

## Sharing diagnostics

Diagnostic errors may contain machine-specific details such as filesystem paths. Review and redact logs before sharing them in public GitHub issues.

## Credentials

Do not provide this utility with API keys, passwords, cookies, or tokens. It does not require them.
