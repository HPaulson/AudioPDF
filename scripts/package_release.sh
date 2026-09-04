#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
VOICE_ASSETS="$PROJECT_ROOT/VoiceAssets"
INSTALL_APP="${APP_INSTALL_PATH:-/Applications/AudioPDF.app}"
LEGACY_INSTALL_APP="/Applications/OfflinePDFReader.app"
PREVIOUS_INSTALL_APP="/Applications/AudioPDF.app"

while (( $# > 0 )); do
  case "$1" in
    --voice-assets)
      [[ $# -ge 2 ]] || { print -u2 "Missing directory after --voice-assets"; exit 2; }
      VOICE_ASSETS=$2
      shift 2
      ;;
    --no-voice-assets)
      VOICE_ASSETS=""
      shift
      ;;
    *)
      print -u2 "Unknown argument: $1"
      exit 2
      ;;
  esac
done

if [[ -n "$VOICE_ASSETS" && ! -d "$VOICE_ASSETS" ]]; then
  print -u2 "Voice assets directory does not exist: $VOICE_ASSETS"
  exit 2
fi

command -v swift >/dev/null || { print -u2 "Apple Swift Command Line Tools are required."; exit 1; }

# Prefer the full Xcode installation even when xcode-select is still pointed
# at CommandLineTools. SwiftPM needs the full Xcode developer directory for a
# reliable macOS app build and for agents running in fresh environments.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [[ -d "$(/usr/bin/xcode-select -p 2>/dev/null || true)" && -x "$(/usr/bin/xcode-select -p)/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR=$(/usr/bin/xcode-select -p)
  else
    print -u2 "Full Xcode is required to build AudioPDF.app. Install Xcode or set DEVELOPER_DIR to Xcode.app/Contents/Developer."
    exit 1
  fi
fi

if ! /usr/bin/env DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcodebuild -version >/dev/null 2>&1; then
  print -u2 "Xcode is selected but unavailable at: $DEVELOPER_DIR"
  print -u2 "If the license has not been accepted, run: sudo xcode-select --switch $DEVELOPER_DIR && sudo xcodebuild -license accept"
  exit 1
fi

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/audio-pdf-release.XXXXXX")
cleanup() {
  /bin/rm -rf "$STAGING"
}
trap cleanup EXIT

cd "$PROJECT_ROOT"
/bin/mkdir -p "$PROJECT_ROOT/.cache/clang"

# SwiftPM can reuse a generated module after the selected Xcode/SDK changes.
# That leaves binary-package modules (such as SherpaOnnxRuntime) compiled for
# one SDK while the app is compiled for another. Clean generated build output
# before each release build; SwiftPM keeps the downloaded binary artifacts.
swift package clean

SWIFT_ENV=(
  DEVELOPER_DIR="$DEVELOPER_DIR"
  CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.cache/clang"
  SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.cache/clang"
)

/usr/bin/env "${SWIFT_ENV[@]}" \
  swift build --disable-sandbox -c release --product AudioPDFApp

BUILT_BIN_PATH="$(/usr/bin/env "${SWIFT_ENV[@]}" swift build --disable-sandbox -c release --show-bin-path)"
BUILT_EXECUTABLE="$BUILT_BIN_PATH/AudioPDFApp"
[[ -x "$BUILT_EXECUTABLE" ]] || { print -u2 "Release executable was not produced."; exit 1; }

if [[ -n "$VOICE_ASSETS" ]]; then
  "$PROJECT_ROOT/scripts/verify_voices.sh" "$VOICE_ASSETS"
fi

APP="$STAGING/AudioPDF.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/ditto "$BUILT_EXECUTABLE" "$APP/Contents/MacOS/AudioPDF"
/bin/chmod +x "$APP/Contents/MacOS/AudioPDF"
/usr/bin/ditto "$PROJECT_ROOT/AudioPDF/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/ditto \
  "$PROJECT_ROOT/AudioPDF/PrivacyInfo.xcprivacy" \
  "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
/usr/bin/ditto \
  "$PROJECT_ROOT/AudioPDF/Resources/AppIcon.png" \
  "$APP/Contents/Resources/AppIcon.png"

if [[ -n "$VOICE_ASSETS" ]]; then
  /bin/mkdir -p "$APP/Contents/Resources/VoiceAssets"
  /usr/bin/ditto "$VOICE_ASSETS" "$APP/Contents/Resources/VoiceAssets"
fi

/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

/bin/mkdir -p "$PROJECT_ROOT/dist"
FINAL_APP="$PROJECT_ROOT/dist/AudioPDF.app"
if [[ -e "$FINAL_APP" ]]; then
  /bin/rm -rf "$FINAL_APP.previous"
  /bin/mv "$FINAL_APP" "$FINAL_APP.previous"
fi
/usr/bin/ditto "$APP" "$FINAL_APP"

/bin/mkdir -p "$STAGING/Licenses"
/usr/bin/ditto "$PROJECT_ROOT/LICENSE" "$STAGING/LICENSE"
/usr/bin/ditto "$PROJECT_ROOT/LICENSES" "$STAGING/Licenses"
/usr/bin/ditto "$PROJECT_ROOT/README.md" "$STAGING/README.md"

OUTPUT="$PROJECT_ROOT/dist/Audio-PDF-macOS-ad-hoc.zip"
if [[ -e "$OUTPUT" ]]; then
  /bin/rm -f "$OUTPUT.previous"
  /bin/mv "$OUTPUT" "$OUTPUT.previous"
fi
(
  cd "$STAGING"
  /usr/bin/ditto -c -k --sequesterRsrc . "$OUTPUT"
)
/usr/bin/unzip -tq "$OUTPUT"

# Keep the user's Applications copy in sync with every successful build.
# APP_INSTALL_PATH can override this for CI or another local install location.
if [[ -e "$INSTALL_APP" ]]; then
  /bin/rm -rf "$INSTALL_APP"
fi
/bin/mkdir -p "${INSTALL_APP:h}"
/usr/bin/ditto "$FINAL_APP" "$INSTALL_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
if [[ "$LEGACY_INSTALL_APP" != "$INSTALL_APP" && -e "$LEGACY_INSTALL_APP" ]]; then
  /bin/rm -rf "$LEGACY_INSTALL_APP"
fi
if [[ "$PREVIOUS_INSTALL_APP" != "$INSTALL_APP" && -e "$PREVIOUS_INSTALL_APP" ]]; then
  /bin/rm -rf "$PREVIOUS_INSTALL_APP"
fi

print "Built app: $FINAL_APP"
print "Created zip: $OUTPUT"
print "Installed app: $INSTALL_APP"
