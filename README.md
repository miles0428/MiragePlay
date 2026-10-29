# MiragePlay

A macOS menu bar app that receives AirPlay mirroring from an iPhone or iPad.

English | [繁體中文](docs/README.zh-TW.md)

## What It Is

MiragePlay turns your Mac into an AirPlay mirroring receiver — pick this Mac on your
iPhone or iPad and the device screen appears on the Mac. It lives in the menu bar:
no Dock icon, no main window. It receives directly over the local network — no
accounts, no cloud relay, no content uploaded. The receiving core is UxPlay,
embedded in the app; the app itself is the UI, lifecycle and packaging layer
around it.

![The menu bar panel before starting — the receiver is stopped.](docs/images/panel-stopped.png)

The menu bar panel before starting — the receiver is stopped.

![After starting: the panel shows the connected device.](docs/images/panel-connected.png)

After starting: the panel shows the connected device.

## Requirements

| Item | Requirement |
|---|---|
| macOS | 15.0 or later (`app/Package.swift`: `platforms: [.macOS("15.0")]`) |
| CPU | Apple silicon (arm64). Intel Macs are not supported. |

The toolchain needed to build from source is listed under [Build from Source](#build-from-source).

## Install

The release archive is the release: the `.zip` you download contains the signed
`MiragePlay.app` together with this README, the documentation under `docs/`, the
licence texts and the third-party notices. Nothing has to be built.

1. Download the release archive (`.zip`) for your version and extract it — you get a folder named `mirageplay-<version>` that contains `MiragePlay.app`, this README, `docs/`, `LICENSE`, `THIRD-PARTY-NOTICES.md` and `CONTRIBUTING.md`.
2. Drag `MiragePlay.app` into `/Applications`.
3. Launch it once. The bundle is ad-hoc signed and not notarized, so Gatekeeper
   blocks the first launch: right-click the app → **Open** → **Open**, or allow
   it in System Settings → Privacy & Security → **Open Anyway**.

    *Advanced option:* if Gatekeeper still blocks the launch, you can clear the
    quarantine attribute from Terminal instead — `xattr -cr /Applications/MiragePlay.app`
    — and then open the app again.
4. The menu bar icon appears — see [Usage](#usage).

Would rather build it yourself? See [Build from Source](#build-from-source).

## Usage

1. Click the menu bar icon — a panel opens with **Start** / **Stop**.
2. Click **Start**. The icon turns orange while the receiver waits.
3. On the iPhone/iPad: Control Center → Screen Mirroring → pick this Mac.
4. The icon turns green while mirroring; the panel shows the device name.
5. **Stop** ends the session. **Quit** exits the app.

See [the status colours](docs/usage.md#status-colours) for what each menu bar colour means.

## Build from Source

The build toolchain:

- Xcode Command Line Tools (`xcode-select --install`): `swift`, `clang`, `codesign`, `iconutil`
- `git` — used for version stamping and the UxPlay checkout
- Homebrew — only as the source of the C dependencies; `brew` must be on `PATH`

```bash
brew install cmake openssl@3 libplist gstreamer librsvg
./scripts/build/build-core.sh --embedded
./scripts/build/build-app.sh
```

`scripts/setup/deps.sh` installs `cmake`, `openssl@3`, `libplist`, `gstreamer` and `librsvg` (for `rsvg-convert`).

These dependencies can also be installed from other sources.

For the release build, the smoke test and the build caveats, see [docs/build.md](docs/build.md).

## Source Code

The source of this project is at <https://github.com/miles0428/MiragePlay> — the
same address the app's About window links to. Clone it and follow
[docs/build.md](docs/build.md); issues and pull requests belong there.

MiragePlay is licensed GPL-3.0-only (see [LICENSE](LICENSE)). The third-party
components it embeds, with their versions and licences, are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## License

GPL-3.0-only. See [LICENSE](LICENSE).

The receiver core is not part of this repository's source; it is a fork of
UxPlay, vendored at build time. `core/vendor.lock` records the exact upstream:

| Field | Value |
|---|---|
| Repository | `https://github.com/miles0428/UxPlay.git` |
| Branch | `mirageplay` |
| Commit | `4f5ad4bdeb345448871e2ab39f9793f35f499664` |

`scripts/build/vendor-uxplay.sh` fetches that pinned commit (triggered
automatically by `build-core.sh`), verifies the commit, tree, file count and the
per-file SHA-256 manifest, and fails closed on any mismatch. The commit named in
`core/vendor.lock` is the corresponding source for the core shipped in a
MiragePlay release.

## Security

Please do not open a public issue for a security problem; report it privately to
the maintainer. Key material never enters version control.

## Acknowledgements

- UxPlay
- GStreamer

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

### Documentation

- [Build from source](docs/build.md)
- [Usage](docs/usage.md)
- [Language](docs/language.md)
- [Configuration](docs/configuration.md)
