# AudioPDF: User Guide

This guide is for people who downloaded the app and want to listen to a PDF.

## First launch

Download **Audio-PDF-macOS-ad-hoc.zip** from the
[latest GitHub release](../../../releases/latest), then double-click the ZIP.
Control-click **AudioPDF.app**, choose **Open**, and confirm **Open**
again. macOS may require this because the free release is ad-hoc signed and
not notarized through Apple's paid developer program.

## Listen to a PDF

1. Open AudioPDF.
2. Click **Import** in the Library sidebar, or press **Command–O**.
3. Choose a PDF, then choose a destination folder or **Unfiled**.
4. The PDF opens immediately. Press **Generate Audio** when you want local OCR
   and speech generation to begin. The PDF is available to read while it is
   being prepared, but Play and the other playback controls stay disabled
   until its audio is complete.
5. Press **Play** when **Audio ready** appears.

Audio does not start automatically. You can read or scroll through the PDF
while speech is being prepared.

## Playback

- **Play/Pause** starts or pauses the current PDF.
- **Back** and **Forward** skip 10 seconds.
- **Previous paragraph** and **Next paragraph** move between paragraph starts.
- The slider moves to any ready position.
- The speed menu supports 0.5× through 2×.
- Keyboard shortcuts work throughout the app while a PDF is open:
  - **Space** toggles Play/Pause.
  - **Left/Right Arrow** skips 10 seconds backward/forward.
  - **Command+Left/Right Arrow** moves to the previous/next paragraph.
  - **Up/Down Arrow** increases/decreases playback speed by one preset.
- Playback shortcuts yield to text fields while you are typing.
- Playback highlighting follows the paragraph currently being read in the PDF.
- The current paragraph stays highlighted while playback is paused.

If you select another PDF, the old audio is cleared immediately. The controls
always belong to the PDF currently displayed.

## Follow the text and resume from a paragraph

During playback, the current paragraph remains visible and manual PDF scrolling
is locked so the narration and page cannot drift apart. Pause playback to
scroll freely. The yellow highlight continues to mark the audio position even
when you browse another page. Press Play or choose **Show current paragraph**
to return to it.

Click any paragraph to select it. The selected paragraph is shown in blue and
offers **Play From Here**, which moves the audio position to that paragraph and
immediately starts playback. The same action is available by Control-clicking
or right-clicking a paragraph. Dragging the playback slider updates the yellow highlight while
temporarily suspending automatic page movement, then returns to following when
the drag ends.

## Voices

Choose voice quality in **AudioPDF → Settings**. The setting applies to every PDF:

- **Low quality** — fastest generation; intended for near-immediate results
- **Medium quality** — balanced default
- **High quality** — more natural speech, slower generation
- **Very high quality** — best available quality, slowest generation

Changing quality does not start generation. Press **Generate Audio** to prepare
audio with the new voice. Playback is disabled until that audio is ready. The
app selects the installed model that matches the selected tier.

## Library and original files

The Library remembers PDFs using macOS file access permission. It does not
copy, move, or delete your original PDF. Create folders with the folder-plus
button in the sidebar, nest folders from a folder's Control-click menu, and
drag PDFs between folders. To remove a PDF entry, Control-click its title and
choose **Delete**.

Deleting a folder warns first, then removes that folder, its nested folders,
and their PDF entries from the app's library. It never deletes the original
PDF files.

If a PDF was moved or renamed, remove its old Library entry and import it
again.

## Troubleshooting

### macOS says the app cannot be opened

Control-click the app in Finder and choose **Open**. If it remains blocked,
open **System Settings → Privacy & Security**, scroll down, and choose
**Open Anyway** for AudioPDF.

### The PDF is scanned

Scanned and image-only PDFs are recognized locally when you press **Start
Audio**. Importing and opening a PDF never starts OCR or audio generation.

### Audio generation takes a long time

Speech is generated locally. Long PDFs can take several minutes, especially
the first time. Keep the app open while **Generating audio…** is displayed.
There is intentionally no estimated counter because extracted paragraph sizes
do not predict the remaining time reliably.

For long PDFs, Low and Medium quality are faster and use less CPU than the
higher-quality tiers. In Settings, **Higher performance / more heat** can use
more CPU threads to finish sooner; leave it off when keeping the Mac quiet is
more important.

If generation reports an error, choose **Retry Audio**. If it keeps failing,
try a shorter PDF or re-save the PDF so its text is selectable and clean.

### Play is gray

The selected PDF is still loading or generating audio. Play becomes available
only after **Audio ready** appears.

### Where is my data?

The Library database, generated audio, and settings are stored locally at:

```text
~/Library/Application Support/AudioPDF/
```

The app does not upload PDFs, extracted text, or audio.

## Privacy

AudioPDF has no account, advertising, analytics, telemetry, updater,
web view, or runtime network connection. PDF reading and speech generation
stay on your Mac.
