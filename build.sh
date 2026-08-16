#!/bin/bash
# Build ClaudeUsageBar.app from source. Requires Xcode command-line tools (swiftc).
set -euo pipefail

cd "$(dirname "$0")"
APP="ClaudeUsageBar.app"
BIN_NAME="ClaudeUsageBar"

echo "→ Cleaning previous build…"
rm -rf "$APP"

echo "→ Creating bundle structure…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ! -f AppIcon.icns ]; then
    echo "→ AppIcon.icns missing — generating…"
    ./make_icon.sh
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Compiling Swift (release)…"
# Pin the deployment target so the Mach-O min-OS is stamped correctly. Without
# this, newer Swift toolchains can stamp a min-OS *higher* than the running
# macOS, causing Launch Services error -10825 ("can't use this version…").
ARCH="$(uname -m)"                       # arm64 or x86_64
swiftc -O -target "${ARCH}-apple-macos12.0" \
    -o "$APP/Contents/MacOS/$BIN_NAME" \
    -framework AppKit -framework Foundation -framework Security \
    Sources/main.swift

echo "→ Writing Info.plist…"
cp Info.plist "$APP/Contents/Info.plist"

echo "→ Ad-hoc code signing (keeps Keychain “Always Allow” stable)…"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo ""
echo "✅ Built ./$APP"
echo "   Run it:   open ./$APP"
echo "   Install:  mv ./$APP /Applications/"
echo ""
echo "First launch will ask for Keychain access to 'Claude Code-credentials'."
echo "Click \"Always Allow\"."
