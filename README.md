# AudioPDF

<p align="center">
  <img src="docs/audio-pdf-lockup.svg" alt="AudioPDF — Read deeply. Listen anywhere." width="760" />
</p>

Turn text-based PDFs into a free, offline, and local audiobook library with powerful reading tools and natural-voice audio.

## A better way to read PDFs

AudioPDF keeps the reading experience at the center. Open a PDF in a clean, distraction-free reader, use the tools you need to navigate and understand it, then generate natural-sounding audio whenever you want to listen instead.

- **Reader-first** — Search, zoom, select text, navigate pages, and keep your place while you read.
- **Helpful reading tools** — Play a paragraph from the contextual menu, follow along with highlighted text, and adjust playback speed. Begin audio playback from any selected paragraph.
- **OCR** - Listen to any PDF, even scans and column-based layouts. Just import, generate, and listen.

<p align="center">
   <img width="800" src="https://github.com/user-attachments/assets/5543ed0d-d541-480d-b3ca-b54f55766414" alt="AudioPDF library and player window" />
</p>

## Download and run

1. Open the [latest release](../../releases/latest).
2. Under **Assets**, download **Audio-PDF-macOS-ad-hoc.zip**.
3. Double-click the downloaded ZIP.
4. Move **AudioPDF.app** to your Applications folder, or leave it in
   Downloads.
5. The first time you open it, Control-click the app, choose **Open**, and
   choose **Open** again in the confirmation window.

The app is free and does not require an account, subscription, API key,
Python, Homebrew, or Xcode.

### System requirements

- macOS 14 or newer
- Apple Silicon Mac (M1, M2, M3, M4, or newer)
- A text-based PDF

The release is ad-hoc signed rather than notarized through Apple's paid
developer program. The Control-click → **Open** step is a normal macOS safety
confirmation for this type of free download. Do not disable Gatekeeper or
change your Mac's security settings globally.

## Use the app

1. Click **Import** in the Library sidebar, or press **Command–O**, and choose
   a PDF. Then choose its folder (or **Unfiled**).
2. The PDF opens immediately. Press **Generate Audio** when you want OCR and
   local audio generation to begin.
3. If another PDF is already processing, the newly started PDF is added to the
   processing queue. When **Audio ready** appears, press **Play**.
4. Open **AudioPDF → Settings** to choose the app-wide voice quality.
   Changing quality marks the current audio for regeneration; press **Start
   Audio** to create it.

The app always ties playback to the PDF currently on screen. Switching PDFs
clears the previous player's position and controls. Generated audio is cached,
so reopening the same PDF with the same quality is faster.

## Bundled voices

- **Kristin** — US English, female
- **LJ Speech** — US English, female
- **Norman** — US English, male

## Common questions

See the [plain-language user guide](docs/USER_GUIDE.md) for help with first
launch, scanned PDFs, slow generation, moved files, and playback.

### Privacy

PDF extraction, speech generation, playback, and caching happen on your Mac.
The app has no account, advertising, analytics, telemetry, updater, web view,
or runtime network connection. Your PDF is not uploaded anywhere.

### Licenses

The app is MIT-licensed. sherpa-onnx and ONNX Runtime have their own licenses,
and each bundled voice includes its model card. See [LICENSES](LICENSES) for
the complete notices.

## For developers

Build instructions, voice packaging, tests, and release verification are in
[docs/DEVELOPING.md](docs/DEVELOPING.md). The detailed internal release
checklist is [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

## A closer look

<table>
  <tr>
    <td width="50%"><img src="https://github.com/user-attachments/assets/151270e3-6bd4-441e-9919-fe97277c65d4" alt="AudioPDF import and library view" /></td>
    <td width="50%"><img src="https://github.com/user-attachments/assets/929776ab-7f15-4077-ab95-ec5f42b98495" alt="AudioPDF settings and playback view" /></td>
  </tr>
</table>
