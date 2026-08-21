#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Codex Usage"
BUNDLE_ID="com.codexusage.menubar"
INSTALL_DIR="$HOME/Applications"
APP_DIR="$INSTALL_DIR/$APP_NAME.app"
BUILD_DIR=".build"
LAUNCH_AGENT_LABEL="com.codexusage.menubar"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"
LEGACY_LAUNCH_AGENT="$LAUNCH_AGENT_DIR/com.local.codex-usage-menubar.plist"
EXECUTABLE="$BUILD_DIR/CodexUsage"

echo "Building Codex Usage menu-bar app…"

# Capture a Codex executable for the menu-bar app. Prefer the same bundled
# app-server binary used by the current ChatGPT/Codex desktop app; fall back to
# a standalone CLI if one is available in Terminal.
CODEX_PATH=""

for candidate in \
  "/Applications/ChatGPT.app/Contents/Resources/codex" \
  "/Applications/Codex.app/Contents/Resources/codex" \
  "$HOME/Applications/ChatGPT.app/Contents/Resources/codex" \
  "$HOME/Applications/Codex.app/Contents/Resources/codex" \
  "$HOME/.codex/packages/standalone/current/codex" \
  "$HOME/.codex/packages/standalone/current/bin/codex"
do
  if [[ -x "$candidate" ]]; then
    CODEX_PATH="$candidate"
    break
  fi
done

if [[ -z "$CODEX_PATH" ]]; then
  CODEX_PATH="$(command -v codex 2>/dev/null || true)"
fi

CONFIG_DIR="$HOME/Library/Application Support/Codex Usage"
mkdir -p "$CONFIG_DIR"

if [[ -n "$CODEX_PATH" && -x "$CODEX_PATH" ]]; then
  printf '%s\n' "$CODEX_PATH" > "$CONFIG_DIR/codex-path"
  echo "Found Codex app-server:"
  echo "  $CODEX_PATH"
else
  rm -f "$CONFIG_DIR/codex-path"
  echo
  echo "Note: no bundled or standalone Codex executable was found."
  echo "The app will make one final interactive-shell lookup after launch."
  echo
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo
  echo "Apple Command Line Tools are required."
  echo "Run: xcode-select --install"
  exit 1
fi

# Stop any older invisible copy before replacing the bundle.
pkill -f "$APP_DIR/Contents/MacOS/CodexUsage" 2>/dev/null || true
sleep 0.3

mkdir -p "$BUILD_DIR"
xcrun swiftc \
  -O \
  -framework Cocoa \
  src/CodexUsageMenu.swift \
  -o "$EXECUTABLE"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/CodexUsage"
chmod +x "$APP_DIR/Contents/MacOS/CodexUsage"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexUsage</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.10</string>
  <key>CFBundleVersion</key>
  <string>11</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS treats the locally built bundle more cleanly.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

# Enable Launch at Login by default. This per-user LaunchAgent only asks
# LaunchServices to open the installed app at login.
mkdir -p "$LAUNCH_AGENT_DIR"
rm -f "$LEGACY_LAUNCH_AGENT"

# Escape characters that are special in XML element text.
xml_escape() {
  printf '%s' "$1" \
    | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g'
}

APP_DIR_XML="$(xml_escape "$APP_DIR")"

cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-g</string>
    <string>${APP_DIR_XML}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

chmod 644 "$LAUNCH_AGENT"

echo
echo "Installed to:"
echo "  $APP_DIR"
echo
echo "Launch at Login:"
echo "  Enabled"
echo
echo "Opening it now…"
open "$APP_DIR"
echo
echo "Look for “Codex …” in the macOS menu bar."
echo "Use the “Launch at Login” menu item to turn automatic startup on or off."
