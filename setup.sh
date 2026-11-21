#!/usr/bin/env bash
# OMNIServers setup. One command from a fresh clone:
#   ./setup.sh            build and run the app for this computer (Mac app on macOS, desktop app on Linux)
#   ./setup.sh mac        the SwiftUI Mac app
#   ./setup.sh desktop    the Avalonia app (Windows and Linux; also runs on a Mac for testing)
#   ./setup.sh android    the Android app (builds a debug APK)
#   ./setup.sh site       the website, served at http://localhost:8080
#   ./setup.sh --check    only look for what is missing and say how to get it; build nothing
# It never installs anything and never uses sudo: it tells you what to install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CHECK=0; TARGET=""
for a in "$@"; do case "$a" in --check) CHECK=1 ;; mac|desktop|android|site) TARGET="$a" ;; -h|--help) sed -n 2,10p "$0"; exit 0 ;; *) echo "Unknown option: $a (try --help)"; exit 2 ;; esac; done
if [ -z "$TARGET" ]; then case "$(uname -s)" in Darwin) TARGET=mac ;; *) TARGET=desktop ;; esac; fi

ok()   { printf '  ✓ %s\n' "$1"; }
miss() { printf '  ✗ %s\n    → %s\n' "$1" "$2"; MISSING=1; }
MISSING=0
export PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

need_dotnet() {
  if command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then ok ".NET 10 SDK ($(dotnet --version))"
  else miss ".NET 10 SDK" "install it from https://dotnet.microsoft.com/download/dotnet/10.0 (or: brew install --cask dotnet-sdk)"; fi
}

echo "OMNIServers setup: $TARGET"
case "$TARGET" in
  mac)
    [ "$(uname -s)" = Darwin ] && ok "macOS $(sw_vers -productVersion)" || miss "macOS" "the Mac app only builds on a Mac; use './setup.sh desktop' here"
    if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then ok "$(xcodebuild -version | head -1)"
    else miss "Xcode" "install Xcode from the App Store, open it once, then: sudo xcode-select -s /Applications/Xcode.app"; fi
    [ "$CHECK" = 1 ] || [ "$MISSING" = 1 ] && { [ "$MISSING" = 1 ] && exit 1 || exit 0; }
    cd "$ROOT/apps/mac/craftpanel-Swift"
    echo "Building (a few minutes the first time)…"
    xcodebuild -project craftpanel-Swift.xcodeproj -scheme craftpanel-Swift -configuration Release \
      -destination 'platform=macOS' -derivedDataPath "$ROOT/build/mac" build -quiet
    APP="$(find "$ROOT/build/mac/Build/Products/Release" -maxdepth 1 -name '*.app' | head -1)"
    echo "Built: $APP"; open "$APP"
    ;;
  desktop)
    need_dotnet
    [ "$CHECK" = 1 ] || [ "$MISSING" = 1 ] && { [ "$MISSING" = 1 ] && exit 1 || exit 0; }
    cd "$ROOT/apps/desktop" && exec dotnet run --project src/CraftPanel.App -c Release
    ;;
  android)
    if command -v java >/dev/null 2>&1; then ok "Java ($(java -version 2>&1 | head -1))"; else miss "JDK 17 or newer" "install it (for example: brew install --cask temurin@17)"; fi
    if [ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]; then ok "Android SDK (${ANDROID_HOME:-$ANDROID_SDK_ROOT})"; else miss "Android SDK" "install Android Studio, then set ANDROID_HOME (Mac: ~/Library/Android/sdk)"; fi
    [ "$CHECK" = 1 ] || [ "$MISSING" = 1 ] && { [ "$MISSING" = 1 ] && exit 1 || exit 0; }
    cd "$ROOT/apps/android" && ./gradlew assembleDebug && echo "APK: apps/android/app/build/outputs/apk/debug/"
    ;;
  site)
    command -v python3 >/dev/null 2>&1 && ok "python3" || miss "python3" "install Python 3"
    [ "$CHECK" = 1 ] || [ "$MISSING" = 1 ] && { [ "$MISSING" = 1 ] && exit 1 || exit 0; }
    echo "Serving the site at http://localhost:8080 (Ctrl-C to stop)"; cd "$ROOT/site" && exec python3 -m http.server 8080
    ;;
esac
