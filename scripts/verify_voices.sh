#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
VOICE_ASSETS=${1:-"$PROJECT_ROOT/VoiceAssets"}

[[ -d "$VOICE_ASSETS" ]] || {
  print -u2 "Voice assets directory does not exist: $VOICE_ASSETS"
  exit 2
}

SWIFT_ENV=(
  DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
  CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.cache/clang"
  SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.cache/clang"
)

cd "$PROJECT_ROOT"
# Build the verifier as a real SwiftPM product. A standalone swiftc invocation
# cannot reliably reconstruct SwiftPM's module search paths and target settings
# across GitHub runner/Xcode versions.
/usr/bin/env "${SWIFT_ENV[@]}" \
  swift build --disable-sandbox -c release --product VoiceVerification
BUILD_ROOT="$(/usr/bin/env "${SWIFT_ENV[@]}" swift build --disable-sandbox -c release --show-bin-path)"
VERIFIER="$BUILD_ROOT/VoiceVerification"
[[ -x "$VERIFIER" ]] || {
  print -u2 "Voice verification executable was not produced."
  exit 1
}

voices=("$VOICE_ASSETS"/*(/N))
(( ${#voices} > 0 )) || {
  print -u2 "No voice folders found in: $VOICE_ASSETS"
  exit 1
}
for voice in "${voices[@]}"; do
  "$VERIFIER" "$voice"
done
