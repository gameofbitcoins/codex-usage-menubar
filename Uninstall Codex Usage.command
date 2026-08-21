#!/bin/zsh
set -euo pipefail
APP="$HOME/Applications/Codex Usage.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.codexusage.menubar.plist"
LEGACY_LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.local.codex-usage-menubar.plist"

pkill -f "$APP/Contents/MacOS/CodexUsage" 2>/dev/null || true
rm -f "$LAUNCH_AGENT" "$LEGACY_LAUNCH_AGENT"
rm -rf "$APP"

echo "Removed:"
echo "  $APP"
echo "  $LAUNCH_AGENT"
echo "  $LEGACY_LAUNCH_AGENT (if present)"
