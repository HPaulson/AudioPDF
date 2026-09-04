# Release verification checklist

Run this on both Apple Silicon and Intel when those release architectures are claimed.

- Xcode resolves the pinned SPM dependency on a clean account.
- `Product → Test` passes.
- Release builds with `CODE_SIGNING_ALLOWED=NO` and no development team.
- `codesign --verify --deep --strict AudioPDF.app` accepts the ad-hoc signature.
- Package script produces a zip and the unzipped app launches using Finder’s Open override.
- A normal selectable-text PDF imports with correct reading order and geometry.
- A malformed file renamed `.pdf` reports an invalid-PDF error.
- An image-only/scanned PDF is OCRed locally and generates audio.
- Repeated page headers, footers, page numbers, footnote markers, and split hyphens are cleaned.
- The PDF occupies the reading area without a duplicate processed-text pane.
- Playback highlighting advances through the displayed PDF.
- The current paragraph remains highlighted while paused and while seeking.
- Playback keeps the current paragraph in view without jumping when it is
  already comfortably visible.
- Pausing unlocks manual PDF scrolling; pressing Play returns to and locks the
  current paragraph in view.
- Clicking and right-clicking paragraphs offers working Resume Here and Play
  From Here actions.
- Import does not start OCR or audio generation; Generate Audio begins it manually.
- All playback controls stay disabled until the selected PDF's audio is ready.
- Switching documents immediately clears the previous document's player and duration.
- Seeking before zero and beyond the end clamps safely.
- Highlighting remains aligned at 0.5×, 1×, 1.5×, and 2×.
- Cancelling a long synthesis stops further paragraphs without corrupting completed clips.
- Reopening the same PDF reuses the cache.
- Changing PDF bytes, normalized text, voice, or synthesis settings invalidates the cache.
- Resume position, voice, and speed survive an app restart.
- Missing/incomplete voice folders give a useful local error.
- The final app runs with Python, FFmpeg, Homebrew, and API keys absent.
- With networking disabled, import, extraction, cached playback, fresh synthesis, and persistence work.
- Bundled voice model card/license and every dependency license are present in the release.
