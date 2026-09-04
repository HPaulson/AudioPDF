#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}

cd "$PROJECT_ROOT"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CLANG_CACHE="$PROJECT_ROOT/.cache/clang"
mkdir -p "$CLANG_CACHE"
export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_CACHE"

print "Running Swift tests..."
swift test

print "Compiling release app with Swift 6 concurrency diagnostics..."
swift build --disable-sandbox -c release --product AudioPDFApp \
  -Xswiftc -strict-concurrency=complete

print "Fetching and validating bundled voices..."
./scripts/fetch_voice_assets.sh

print "Building and packaging the release app..."
./scripts/build_app.sh

ARCHIVE="$PROJECT_ROOT/dist/Audio-PDF-macOS-ad-hoc.zip"
[[ -f "$ARCHIVE" ]] || {
  print -u2 "Release archive was not produced: $ARCHIVE"
  exit 1
}

print "Verifying release archive..."
unzip -tq "$ARCHIVE"

print "Pre-release checks passed."
print "Run for manual testing: open /Applications/AudioPDF.app"
