# Build from Source

Run everything from the repository root.

Two audiences use this page:

- **Contributors** building a bundle to run and test: the three commands under
  [Development build](#development-build).
- **Releasers** producing the `.zip` that gets published: one command,
  `scripts/build/release.sh`, under [Release archive](#release-archive).

## Prerequisites

The toolchain, before any of the commands below:

- **Xcode Command Line Tools** — `xcode-select --install`. This provides
  `swift`, `clang`, `codesign`, `iconutil` and the SDK that supplies the C++
  standard headers. Homebrew's packages do not replace it.
- `git` — version stamping and the UxPlay checkout.
- Homebrew — only as the source of the C dependencies; `brew` must be on `PATH`.

Confirm the Command Line Tools are **complete**, not merely present. This
compiles a one-line translation unit that needs `<cstring>` from the SDK:

```bash
printf '#include <cstring>\nint main(void){return 0;}\n' | clang++ -E -x c++ - >/dev/null && echo "CLT ok"
```

A failure of the form `'cstring' file not found` (or any other standard C/C++
header such as `iostream`, `vector`, `cstdint`) means the Command Line Tools
payload is incomplete: the SDK that ships with the tools is missing headers it
is supposed to contain. This page does not claim to know how a machine gets
into that state — a half-finished or interrupted installation or update is one
way, so is a payload damaged some other way. The diagnosis is the symptom
("the tools are installed but the SDK is incomplete"), and the repair below
treats that symptom.

`xcode-select --install` will not repair it: it reports
`Command line tools are already installed`. Remove the install and request it
again:

```bash
sudo rm -rf /Library/Developer/CommandLineTools
xcode-select --install
```

Know what that removal costs before you run it:

- It deletes the **local Command Line Tools install only** — the SDK plus
  `clang`, `swift`, `codesign` and the rest. A full Xcode.app in
  `/Applications` is a separate install and is not touched.
- The path **cannot be restored**; the only way back is the reinstall in the
  second command. Until that finishes, the machine has no C/C++/Swift
  toolchain, so no build of anything works.
- `xcode-select --install` needs **network access** and an admin account (the
  `sudo` above). Offline, the machine stays without a toolchain until it is.
- If the reinstall reports the tools are already installed and still leaves the
  payload broken, drop the stale receipt first and retry:
  `sudo pkgutil --forget com.apple.pkg.CLTools_Executables`.

Then re-run the check above before building. The build itself would fail at
`uxplay.cpp:24: #include <cstring>`, which names the symptom rather than the
cause.

## Development build

```bash
./scripts/setup/deps.sh
./scripts/build/build-core.sh --embedded
./scripts/build/build-app.sh
```

`deps.sh` runs `brew install cmake openssl@3 libplist gstreamer librsvg`
(`librsvg` provides `rsvg-convert`, which the icon renderer needs). The same five
packages can be installed from other sources.

- `build-core.sh --embedded` builds the UxPlay core in embedded mode and writes
  it to `_build/core/uxplay`. The first run fetches the pinned
  upstream tree (see [Notes](#notes)), so it needs network access.
- `build-app.sh` with no flags is the **dev** build: debug configuration, no
  version injection, and the GStreamer closure installed by default so the
  bundle starts on a machine without Homebrew. `--no-closure` skips the closure
  (fast iteration only — the helper will not start without it).
- The bundle lands in `_build/MiragePlay.app`.

Neither command signs the app. `build-app.sh` only ad-hoc signs the closure
dylibs it installs; the app itself is signed by `package-release.sh`, which is
the single signer in the chain.

The semi-automated smoke test starts the built app and then asks you to mirror a
device:

```bash
./scripts/tests/smoke.sh
```

## Release archive

A release archive is one command. It builds, signs and zips in that order and
writes `packaging/dist/mirageplay-<VERSION>.zip`:

```bash
./scripts/build/release.sh
```

Before it runs, four things must be true (each is enforced, not advisory):

| # | Requirement | Enforced by |
|---|---|---|
| 1 | No staged, unstaged or untracked changes among the paths git reports | `build-app.sh` refuses a `--release` build when `git status --porcelain` prints anything |
| 2 | `VERSION` holds the version you are shipping, committed | `release.sh` reads it first and refuses without it |
| 3 | A git tag points at `HEAD` | `release.sh` refuses to archive an untagged `HEAD`; there is no bypass flag |
| 4 | The core is built at `_build/core/uxplay` | step 1 of `release.sh` fails if the build cannot find it |

Requirement 1 covers less than it looks like, and the gap is worth knowing
before you trust a bundle. The check is
`git -C "$REPO_ROOT" status --porcelain` (`build-app.sh:246`), which reports
changes to tracked files and to untracked files that are not ignored; anything
under the ignore rules is outside it. Two of those ignored paths are build
inputs:

- `_build/` (`.gitignore:95`) holds the build cache, the SwiftPM cache and the
  materialized core tree at `_build/uxplay`.
- `/core/uxplay/` (`.gitignore:70`) is a legacy location for the same upstream
  body.

So a release built from a warm cache can carry a core tree that was edited in
place and no gate on the release path looks at it: `build-core.sh:111`
materializes and verifies the tree only when the directory is missing, and a
present directory is compiled as-is. To assert the core yourself, run
`scripts/build/vendor-uxplay.sh --check`: it verifies the tree against
`core/vendor.lock` (commit, tree, file count, per-file SHA-256) without cloning
or writing. On a fresh clone it fails until the tree has been materialized once,
because the check verifies an existing tree rather than fetching one.

A typical release, from a clean checkout:

```bash
./scripts/build/build-core.sh --embedded      # if the core cache is cold
git tag -a v0.1.0 -m "MiragePlay 0.1.0"       # once, on the commit you ship
./scripts/build/release.sh
```

### What the command does

The default mode runs three steps; any failing step exits non-zero and no
archive is written.

| Step | Command it runs | Result |
|---|---|---|
| `[1/3]` build | `build-app.sh --release --out <out> --closure` | `MiragePlay.app` with stripped binaries, version injected, closure installed and ad-hoc signed |
| `[2/3]` sign | `package-release.sh --sign-only --app <app>` | every Mach-O in the bundle signed inner-to-outer, then verified |
| `[3/3]` package | `ditto -c -k --norsrc --keepParent` | the archive, written beside its destination and moved into place |

`build-app.sh` never runs `codesign` on the app, so building first and signing
second is enforced by the chain rather than left to memory.

### What the archive contains

```
mirageplay-<VERSION>/
  MiragePlay.app/
  README.md
```

One versioned folder at the archive root, never a bare `.app`, so two releases
can be unpacked side by side. `README.md` is the repository's own `README.md`
copied verbatim; a missing README is a refusal, not a silently README-less zip.
No `__MACOSX/` sidecar is produced (`--norsrc`), and the layout is asserted
after writing: a stray top-level entry, a missing `Info.plist`, or a README
buried inside the bundle refuses the publish.

### Gates (both modes, fail closed)

`release.sh` re-checks the bundle it is about to archive, whichever way that
bundle was produced:

- **Tag gate** — `git describe --tags --exact-match HEAD` must return a tag. An
  untagged `HEAD` names no immutable point, so the run stops. There is no flag
  to skip this; tag first, then run the script.
- **Provenance gate** — `build-app.sh` stamps `MirageBuildCommit` (the sha it
  built from) into **both** `Info.plist`s in one loop (`build-app.sh:478-486`,
  the key itself at `:485`). The gate reads **only the app's** plist:
  `release.sh:267` sets `PLIST="$APP/Contents/Info.plist"`, `:280` extracts the
  key from that file, and `:288` compares that value with `git rev-parse HEAD`.
  The helper's copy is written by the same loop but is never compared here (the
  version pair is a separate check — see *Version rules*). A missing key or a
  different sha is a refusal, never a warning. This is what a stale bundle from
  another tree — or from before commit stamping existed — trips.
- **Staleness gate** — the main executable must be at least as new as the last
  commit that touched `app`, `VERSION`, `core/vendor.lock` or `scripts/build`.
  `HEAD` is deliberately not the baseline: a docs-only commit moves `HEAD`
  without moving a byte of the build.
- **Signature gate** — `Contents/_CodeSignature/CodeResources` must exist and be
  no older than the main executable. A rebuild without a re-sign pairs a fresh
  binary with the previous signature, which `codesign --verify` rejects while
  the staleness gate happily passes it.
- **Layout gate** — as described above, after the archive is written.

`--allow-stale` archives anyway and prints a WARNING. It covers the staleness
and signature gates only (re-releasing an older bundle on purpose); it cannot
skip a failed build or a failed signing step, and it does not touch the tag or
provenance gates.

### Version rules

- `./VERSION` (first line) is the single source of the version. `release.sh`
  reads it before any expensive work and refuses when it is absent or empty; the
  archive is named `mirageplay-<VERSION>` from that value.
- `-rc.N` suffixes are preserved in the archive name and stripped from
  `CFBundleShortVersionString`, which Apple requires to be three
  period-separated integers (`0.1.0-rc.1` → bundle reports `0.1.0`, zip is
  `mirageplay-0.1.0-rc.1.zip`).
- The tag at `HEAD` is cross-checked, not authoritative: if it disagrees with
  `VERSION`, both `build-app.sh` and `release.sh` warn and continue with
  `VERSION`, because archiving an older bundle on a re-tagged tree is a
  legitimate operation. A tag is still required to archive — see the tag gate.
  `build-app.sh` falls back to the tag only for a checkout that has no `VERSION`
  file at all.
- `CFBundleVersion` is `git rev-list --count HEAD`, the same value in the app
  and the helper plist; `package-release.sh` verifies both.
- The version the app reports and the version the zip is named after come from
  the same file, so a mismatch means the bundle was built from a different
  `VERSION`. `release.sh` warns when they disagree; treat that warning as a
  mistake to fix before publishing.

### Verify what you are about to publish

The bundle names the commit it came from; compare it with `HEAD`:

```bash
plutil -extract MirageBuildCommit raw packaging/dist/MiragePlay.app/Contents/Info.plist
git rev-parse HEAD
```

Both must print the same sha. `build-app.sh` writes that key into the app and
helper plists from `git rev-parse HEAD` at build time (`build-app.sh:478-486`,
once per plist). What that establishes is provenance — which tree the bytes came
from — not that a rebuild of the same tree produces the same bytes. A rerun of
`release.sh` on the same commit does not:

```text
tag v0.1.0 (2301e55), two release.sh runs — original tree, then a clone:
  size     23,956,450 B   (identical)
  entries  86             (identical)
  checks   36 passed, 0 failed  (identical)
  sha256   30d76fa7…0343  vs  a7a3fa31…ec1a
```

85 of the 86 entries were byte-identical; the entry that differed was
`MiragePlay.app/Contents/MacOS/MiragePlay` — same length (547040 B), different
content. The zip sha256 is therefore a property of the archive you wrote on that
machine, not of the commit. Publish the value `release.sh` printed for the file
you are uploading, and expect a rebuild to print a different one.

Then check the version pair the user will see:

```bash
plutil -extract CFBundleShortVersionString raw packaging/dist/MiragePlay.app/Contents/Info.plist
plutil -extract CFBundleVersion raw packaging/dist/MiragePlay.app/Contents/Info.plist
```

After the archive is written, `release.sh` prints its sha256, size and entry
count. The size and entry count re-derive from the zip itself; the sha256 is the
one it printed for that file:

```bash
unzip -Z1 packaging/dist/mirageplay-0.1.0.zip        # one mirageplay-0.1.0/ root
shasum -a 256 packaging/dist/mirageplay-0.1.0.zip
```

And the extracted bundle must still satisfy its signature — nothing inside the
`.app` is rewritten by archiving:

```bash
ditto -x -k packaging/dist/mirageplay-0.1.0.zip /tmp/mp-check
codesign --verify --deep --strict /tmp/mp-check/mirageplay-0.1.0/MiragePlay.app
```

`package-release.sh` also writes a release report (default
`<out>/release-report.md`) listing the dependency closure, the
`install_name_tool` rewrites and every verification check with its result.

### Re-archiving a bundle you already have

```bash
./scripts/build/release.sh --package-only --app packaging/dist/MiragePlay.app
```

`--package-only` skips the build and the signing step and archives the bundle as
it stands. Every gate above stays active, which is what makes the shortcut safe:
an unsigned bundle, a stale binary, or a bundle built from another commit is
refused instead of shipped.

### release.sh flags

| Flag | Meaning |
|---|---|
| `--out DIR` | where the build lands and the zip is written (default `packaging/dist`) |
| `--package-only` | do not build, do not sign; archive the bundle already on disk |
| `--app PATH` | the bundle to archive; only valid with `--package-only` (combining it with a build is refused) |
| `--allow-stale` | archive even when the staleness or signature gate trips (WARNING, both gates) |
| `-h`, `--help` | print the header block of the script |

`packaging/dist/` is a build artifact and is git-ignored; never commit it.

### package-release.sh is a step, not a release

`package-release.sh` is the assembler-finisher: closure copy-in,
`install_name_tool` relocation, ad-hoc signing, verification, release report. It
does **not** write an archive — `package-release.sh --build` leaves you with
`packaging/dist/MiragePlay.app` and no zip, and it stops on an untagged `HEAD`
unless you pass `--allow-untagged`. Use `release.sh` to ship.

Its own flags remain useful around that chain:

| Flag | Meaning |
|---|---|
| `--app PATH` | the `.app` to operate on |
| `--out DIR` | output directory (also where the report goes) |
| `--bundle-only` | assemble only (closure copy-in + relocate), no signing |
| `--sign-only` | sign and verify an existing `.app` (this is what `release.sh` calls) |
| `--verify-only` | run the acceptance checks only; produces no artifacts |
| `--report PATH` | release report path (default `<out>/release-report.md`) |

Two escape hatches exist for development and are refused on the release path
(`--release`, or `MIRAGEPLAY_RELEASE=1`): `--skip-relocate` (skip
`install_name_tool` — the bundle is not shippable) and `--allow-untagged`
(continue without a tag — the report is stamped "no tag, publish forbidden").
Neither belongs in a published build.

## Notes

- `--build-dir <dir>` exists on `build-app.sh` and `build-core.sh` only, same
  meaning on both: the build cache root, core expected at `<dir>/core/uxplay`.
  `package-release.sh` and `release.sh` take `--out` for the bundle destination;
  `release.sh` always builds against the default cache, so a core built with a
  custom `--build-dir` must be rebuilt (or built with the default) before a
  release run.
- Path spelling matters: paths go to `swift build` and `clang`, so they must
  match the disk. `scripts/lib/_canonical-path.sh` explains why `pwd -P` is not enough.
- `vendor-uxplay.sh` (called by `build-core.sh`) clones the UxPlay fork pinned in
  `core/vendor.lock`, so the first core build needs network access. It verifies
  the commit, tree, file count and per-file SHA-256 manifest and fails closed on
  any mismatch.
- The app icon is rendered from `app/Resources/StatusIcon/icon.svg` by
  `scripts/build/make-appicon.sh --out <path>.icns`
  (`--variant light|transparent` selects the design; `light` is the default).

## Upstream licence obligations

The app bundles and links UxPlay, which is GPL-3 itself, so the combined work is
distributed under the same terms (GPL-3.0-only, see `LICENSE`). A published
archive must therefore carry the corresponding source: this repository for the
app, and the UxPlay commit named in `core/vendor.lock` for the core. The full
third-party list, with versions and licences, is `THIRD-PARTY-NOTICES.md`.

## Distribution status

The archive is the only artifact a release publishes: no `.dmg`, and no
Homebrew formula or cask. MiragePlay 0.1.0 is released — `v0.1.0` at
<https://github.com/miles0428/MiragePlay/releases/tag/v0.1.0> carries
`mirageplay-0.1.0.zip`, built from the commit that tag points at.

**On signing, precisely:** the app inside that archive is **ad-hoc signed**,
which is not the same as being signed for distribution. It carries no
Developer ID signature (`codesign -dv` reports `Signature=adhoc` and
`TeamIdentifier=not set`, with no `Authority` line) and it is **not
notarized** by Apple (`xcrun stapler validate` reports no ticket stapled).
Ad-hoc signing keeps the bundle's own integrity intact and lets the closure
dylibs load; it gives Gatekeeper nothing to trust. The consequence for anyone
who downloads the archive: the first launch is blocked, and you get past it by
right-clicking the app → **Open** → **Open**, or by allowing it in System
Settings → Privacy & Security → **Open Anyway**. Expect the same on every new
version.

The same repository is the app's corresponding source, and the app's About
window links to it.

Because the bundle links UxPlay (GPL-3), every release carries corresponding
source: the app from this repository at the release tag, and the receiver core
from the UxPlay fork and commit recorded in `core/vendor.lock`. Both are public,
so anyone holding the archive can rebuild exactly what it contains. See
[Upstream licence obligations](#upstream-licence-obligations).
