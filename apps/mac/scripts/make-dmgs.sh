#!/bin/zsh
# Builds two optimized, signed DMGs: OMNIServers-<ver>-AppleSilicon.dmg (arm64)
# and OMNIServers-<ver>-Intel.dmg (x86_64). Each app is single-architecture
# end to end: our binary is built for one arch, and every embedded Mach-O
# (Sparkle, its XPC services, Autoupdate) is thinned to that arch too.
#
# Signing identity: "Developer ID Application" if present (required for other
# Macs to open it without a Gatekeeper warning), else "Apple Development"
# (fine for your own Macs). Override with SIGN_ID="…".
# Notarization (Developer ID only): set NOTARY_PROFILE to a profile created with
#   xcrun notarytool store-credentials <profile>
set -euo pipefail
# xcodebuild can't run from the command-line-tools directory; use the full Xcode when that is what's selected.
[[ "$(xcode-select -p)" == *Xcode*.app* ]] || export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ROOT=${0:A:h:h}
PROJ="$ROOT/craftpanel-Swift/craftpanel-Swift.xcodeproj"
OUT="${CRAFTPANEL_BUILD_OUT:-$ROOT/dist}"
WORK=$(mktemp -d /tmp/cp-dmg.XXXX)
trap 'rm -rf "$WORK"' EXIT

if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
  [[ -z "$SIGN_ID" ]] && SIGN_ID=$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
fi
[[ -z "$SIGN_ID" ]] && { echo "No code-signing identity found."; exit 1; }
echo "Signing with: $SIGN_ID"
mkdir -p "$OUT"

for ARCH in arm64 x86_64; do
  LABEL=$([[ $ARCH == arm64 ]] && echo AppleSilicon || echo Intel)
  echo "== $LABEL ($ARCH)"
  DD="$WORK/dd-$ARCH"
  xcodebuild -project "$PROJ" -scheme craftpanel-Swift -configuration Release \
    -skipPackageUpdates \
    -destination "generic/platform=macOS" -derivedDataPath "$DD" \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule \
    GCC_OPTIMIZATION_LEVEL=s DEAD_CODE_STRIPPING=YES \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=all COPY_PHASE_STRIP=YES \
    DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
    CODE_SIGN_IDENTITY="$SIGN_ID" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build -quiet
  APP="$DD/Build/Products/Release/OMNIServers.app"
  STAGE="$WORK/stage-$ARCH"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/OMNIServers.app"
  APP="$STAGE/OMNIServers.app"

  # Thin every universal Mach-O to this arch.
  find "$APP" -type f -perm +111 -print0 | while IFS= read -r -d '' f; do
    if lipo -info "$f" 2>/dev/null | grep -q "Architectures in the fat file"; then
      lipo "$f" -thin "$ARCH" -output "$f.thin" && mv "$f.thin" "$f"
    fi
  done

  # Re-sign inside-out (thinning invalidated the nested signatures).
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE" ]]; then
    for x in "$SPARKLE"/Versions/B/XPCServices/*.xpc "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app"; do
      [[ -e "$x" ]] && codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$x"
    done
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$SPARKLE"
  fi
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
  codesign --verify --deep --strict "$APP"
  lipo -archs "$APP/Contents/MacOS/OMNIServers"

  VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
  DMG="$OUT/OMNIServers-$VER-$LABEL.dmg"
  rm -f "$DMG"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "OMNIServers $VER" -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$DMG" -quiet
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

  if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_ID" == Developer\ ID* ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
  echo "-> $DMG ($(du -h "$DMG" | cut -f1))"
done
