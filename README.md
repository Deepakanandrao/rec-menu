# Rec Menu

A small macOS menu bar app for [rec](https://github.com/recursive-oss/rec),
Recursive's local inference engine for the Flint model.

- Start and stop the rec server
- See and copy the API URL, and copy the API key
- Change the server port
- See where the model is stored, and move it to another folder or drive
- Optionally open at login

Rec Menu is an independent project and is not affiliated with or endorsed by
Recursive. It does not include rec or the model; it controls the `rec` you
install yourself.

## Requirements

- An Apple Silicon Mac that meets rec's requirements (M4 Pro, M5 Pro or M5
  Max with at least 48 GB of memory)
- macOS 14 or later
- [rec](https://github.com/recursive-oss/rec) installed in `~/.local/bin/rec`
  (the default for rec's installer)

## Install

1. Download `RecMenu-<version>.dmg` from the
   [latest release](https://github.com/Deepakanandrao/rec-menu/releases/latest).
2. Open the DMG and drag **Rec Menu** into **Applications**.
3. Open Rec Menu from Applications. A triangle icon appears in the menu bar. It is
   green while the server runs, orange while it starts or stops, and plain
   when it is stopped.

Release builds are not notarized by Apple, so macOS blocks the first launch.
To allow it, open **System Settings → Privacy & Security**, scroll down and
click **Open Anyway** next to the Rec Menu message. Alternatively, run:

```bash
xattr -dr com.apple.quarantine "/Applications/Rec Menu.app"
```

The first time it runs from Applications, Rec Menu adds itself as a login item.
Turn this off with the **Open at login** checkbox in its panel.

## Usage

Click the menu bar icon:

- **Start / Stop** runs the server in the background, the same way
  `rec launch` does, so it keeps running if you quit Rec Menu.
- **API URL** shows the OpenAI-compatible endpoint, for example
  `http://127.0.0.1:11500/v1`. Use model `flint` and the key from
  **Copy API key**.
- **Port** changes the port. If the server is running, it restarts on the new
  port.
- **Model location** shows where rec keeps the model. **Change…** moves it to
  a `rec-models` folder in a location you choose and leaves a symlink at
  `~/.local/share/rec/models`, so the `rec` command keeps working. **Reset**
  moves it back.

If you move the model, `rec uninstall` removes only the symlink; delete the
`rec-models` folder yourself.

## Build from source

Requires the Xcode command line tools.

```bash
git clone https://github.com/Deepakanandrao/rec-menu.git
cd rec-menu
./build.sh            # builds "build/Rec Menu.app"
./build.sh --install  # also copies it to /Applications
./build.sh --dmg      # also packages build/RecMenu-<version>.dmg
```

To sign and notarize a release with an Apple Developer ID, set
`SIGN_IDENTITY` to your "Developer ID Application" identity and
`NOTARY_PROFILE` to a `notarytool` keychain profile before running
`./build.sh --dmg`.

## Releasing

1. Update `VERSION`.
2. Commit, then tag and push: `git tag v1.0.0 && git push origin v1.0.0`.
3. The release workflow builds the DMG and attaches it to a GitHub release.

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE).
