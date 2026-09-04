# Developing and packaging

This page is for contributors and release maintainers. If you only want to
use the app, follow the [user guide](USER_GUIDE.md) instead.

## Requirements

- macOS 14 or newer
- Apple Silicon for the bundled release
- Full Xcode (the Command Line Tools package alone is not sufficient)
- The repository's local SherpaOnnxRuntime package dependency

The app has no runtime network dependency. Network access is only needed when
fetching dependencies or downloading the optional voice archives.

## Build the app

The canonical build command is:

```bash
./scripts/build_app.sh
```

It creates a distributable app at `dist/AudioPDF.app`, an ad-hoc ZIP at
`dist/Audio-PDF-macOS-ad-hoc.zip`, and installs the runnable app at
`/Applications/AudioPDF.app`. The Applications copy is replaced only after a
successful build and should be used for manual testing. The script detects the
full Xcode installation and sets `DEVELOPER_DIR` for itself, so it still works
when `xcode-select -p` reports `/Library/Developer/CommandLineTools`.

After changing code, agents must run this command and hand off the app bundle
for testing. Launch it with:

```bash
open "/Applications/AudioPDF.app"
```

If the script says the Xcode license has not been accepted, run this one-time
machine setup command and retry:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

Do not use the presence of Command Line Tools alone as evidence that app build
verification is unavailable; the full Xcode app is what provides the required
macOS app build environment.

Build the executable with Swift Package Manager:

```bash
swift build --product AudioPDFApp
```

Run the unit tests from Xcode with **Product → Test**. The portable core tests
cover text cleanup, cache keys, timelines, playback rates, persistence, and
text chunking.

## Fetch the bundled voices

The release bundle uses three checksum-pinned, Sherpa-compatible Piper voices:

```bash
./scripts/fetch_voice_assets.sh
```

The script downloads the archives from the official Sherpa-ONNX TTS release,
checks their SHA-256 values, verifies model cards and required runtime files,
and places them in `VoiceAssets/`. The bundled model cards and notices must
remain with the release.

## Create a release

```bash
./scripts/build_app.sh
```

Packaging builds the release executable, synthesizes a sample with every
voice, validates the ad-hoc signature, includes licenses, and creates:

```text
dist/AudioPDF.app
dist/Audio-PDF-macOS-ad-hoc.zip
```

It also installs the completed app at `/Applications/AudioPDF.app`. The
`APP_INSTALL_PATH` environment variable may override that destination for CI
or another explicitly chosen install location.

To build an app without bundled voices:

```bash
./scripts/package_release.sh --no-voice-assets
```

To verify voices independently after a build:

```bash
./scripts/verify_voices.sh
```

Before publishing, complete [RELEASE_CHECKLIST.md](../RELEASE_CHECKLIST.md).

## Adding a voice

The app discovers a voice folder when it contains:

```text
Voice Name/
├── model.onnx
├── tokens.txt
├── MODEL_CARD
└── espeak-ng-data/
```

Review the model card and training-data license before redistribution. Do not
bundle a voice with research-only or non-commercial training restrictions in a
general-purpose release. Voice models are separate works from the app and
must retain their notices.

## Source layout

- `AudioPDF/App/` — SwiftUI app, PDFKit view, playback, persistence,
  and Sherpa synthesis
- `AudioPDF/Core/` — extraction cleanup models, cache keys, timelines,
  and text chunking
- `AudioPDFTests/` — portable core tests
- `scripts/` — release packaging, voice asset fetching, and voice verification

Generated application data is stored below:

```text
~/Library/Application Support/AudioPDF/
├── AudioCache/
├── Library.sqlite3
└── Voices/
```
