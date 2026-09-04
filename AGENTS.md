# Agent build handoff

After every app change, build the macOS app before reporting completion:

```bash
./scripts/build_app.sh
```

The distributable artifact is:

```text
dist/AudioPDF.app
```

The build also installs/replaces the runnable app at:

```text
/Applications/AudioPDF.app
```

Open it for manual testing with:

```bash
open "/Applications/AudioPDF.app"
```

Use the Applications copy for manual testing after every successful build;
`dist` is the packaging output, not the installed app.

`build_app.sh` selects the full Xcode installation for the build through
`DEVELOPER_DIR`; it does not depend on the machine's global `xcode-select`
setting. If it reports that the Xcode license has not been accepted, run this
one-time setup, then rerun the build:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

Do not report that build verification is unavailable without first running
`./scripts/build_app.sh` and including its actual error output.
