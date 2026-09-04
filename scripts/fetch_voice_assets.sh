#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
TARGET="$PROJECT_ROOT/VoiceAssets"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/audio-pdf-voices.XXXXXX")

cleanup() {
  /bin/rm -rf "$STAGING"
}
trap cleanup EXIT

typeset -A CHECKSUMS
CHECKSUMS[vits-piper-en_US-kristin-medium.tar.bz2]=c2206f572df2956c50b1ae3367eebce3853c663e890cba8048cd62b1e4dbe6c7
CHECKSUMS[vits-piper-en_US-ljspeech-high.tar.bz2]=00c6408d2409050312193b0d40ae07fde28af7d3d45a56efcc55440db516b935
CHECKSUMS[vits-piper-en_US-norman-medium.tar.bz2]=1f32065d480abe9abc7c7f91442125d0b34c1cc065d1e600466cac408eabf3b8

for archive checksum in ${(kv)CHECKSUMS}; do
  url="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$archive"
  /usr/bin/curl -fL --retry 3 -o "$STAGING/$archive" "$url"
  actual=$(/usr/bin/shasum -a 256 "$STAGING/$archive" | /usr/bin/awk '{print $1}')
  [[ "$actual" == "$checksum" ]] || {
    print -u2 "Checksum mismatch for $archive"
    exit 1
  }
  /usr/bin/tar -xjf "$STAGING/$archive" -C "$STAGING"
done

/bin/mkdir -p "$TARGET"
for voice in \
  vits-piper-en_US-kristin-medium \
  vits-piper-en_US-ljspeech-high \
  vits-piper-en_US-norman-medium; do
  [[ -f "$STAGING/$voice/MODEL_CARD" ]] || {
    print -u2 "Missing model card for $voice"
    exit 1
  }
  [[ -f "$STAGING/$voice/tokens.txt" ]] || {
    print -u2 "Missing tokens for $voice"
    exit 1
  }
  [[ -d "$STAGING/$voice/espeak-ng-data" ]] || {
    print -u2 "Missing espeak data for $voice"
    exit 1
  }
  /bin/rm -rf "$TARGET/$voice"
  /usr/bin/ditto "$STAGING/$voice" "$TARGET/$voice"
done

print "Voice assets are ready at: $TARGET"
