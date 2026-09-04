# Bundled voice notices

## Piper US-English voices

The bundled voices are sherpa-onnx conversions of these
`rhasspy/piper-voices` models:

- Kristin medium:
  https://huggingface.co/rhasspy/piper-voices/tree/main/en/en_US/kristin/medium
- LJSpeech high:
  https://huggingface.co/rhasspy/piper-voices/tree/main/en/en_US/ljspeech/high
- Norman medium:
  https://huggingface.co/rhasspy/piper-voices/tree/main/en/en_US/norman/medium

The repository declares the model MIT licensed. The complete MIT terms are:

Copyright (c) the Piper voices contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Each model's `MODEL_CARD` is included inside its bundled voice directory. The
cards identify the underlying Kristin and Norman LibriVox recordings and the
LJ Speech dataset as public domain. All three models were trained from scratch;
no Lessac/Blizzard-derived or non-commercial voice is included.

## eSpeak NG data

The voice directory includes eSpeak NG language data used for local
phonemization. eSpeak NG is licensed under GNU GPL version 3 or later:

https://github.com/espeak-ng/espeak-ng/blob/main/COPYING

Corresponding source:

https://github.com/espeak-ng/espeak-ng
