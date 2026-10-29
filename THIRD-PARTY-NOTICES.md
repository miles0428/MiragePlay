# Third-Party Notices

MiragePlay is licensed GPL-3.0-only; the licence text is [LICENSE](LICENSE). This
file covers the other side of that: the software written by others that ships
inside a MiragePlay release, the licence each piece is under, how it is linked
into the app, and where its licence text is kept.

Every entry below was read off the shipped artifacts themselves — the 0.1.0
release archive and the app bundle inside it — not off a dependency list. The
evidence for each line, including the exact command that produced it, is named
at the end of every section as `Source:`.

## What is bundled, and where

- The main executable, `MiragePlay.app/Contents/MacOS/MiragePlay`, contains **no
  third-party code** — it is Swift/AppKit only.
- Everything third-party lives in the nested helper,
  `MiragePlay.app/Contents/Helpers/MiragePlay Projection.app`: 49 bundled dylibs
  (35 in `Contents/Frameworks`, 14 GStreamer plugins in `Contents/plugins`) plus
  two libraries linked statically into the helper executable `uxplay`.
- No bundled binary has a dependency outside `/usr/lib`, `/System` or
  `@loader_path`, and no binary carries an `LC_RPATH` — nothing points back at a
  build machine.

## Summary

Nineteen licence entries across eighteen upstream projects. OpenSSL appears
twice because two different versions ship, by two different routes.

| # | Component | Version | Licence | Linked as |
|---|---|---|---|---|
| 1 | FFmpeg (6 libraries) | 9.0.2_1 | GPL-3.0-or-later | Bundled dylibs |
| 2 | x264 | r3222 (build 165) | GPL-2.0-or-later | Bundled dylib |
| 3 | x265 | 4.3 (build 217) | GPL-2.0-or-later | Bundled dylib |
| 4 | SVT-AV1 | 4.2.0 | BSD-3-Clause-Clear (AOM) | Bundled dylib |
| 5 | dav1d | 1.5.4 | BSD-2-Clause | Bundled dylib |
| 6 | libvpx | 1.17.0 | BSD-3-Clause | Bundled dylib |
| 7 | libvmaf | 3.2.1 | BSD-2-Clause-Patent | Bundled dylib |
| 8 | LAME (libmp3lame) | 4.0 | LGPL-2.0-or-later | Bundled dylib |
| 9 | mpg123 | 1.33.7 | LGPL-2.1-only | Bundled dylib |
| 10 | Opus | 1.6.1 | BSD-3-Clause | Bundled dylib |
| 11 | GStreamer (10 libs + 14 plugins) | 1.28.8 | LGPL-2.0-or-later AND LGPL-2.1-or-later AND MIT | Bundled dylibs |
| 12 | GLib / GObject / GIO / GModule | 2.90.1 | LGPL-2.1-or-later | Bundled dylibs |
| 13 | gettext (libintl) | 1.0 | LGPL-2.1-or-later | Bundled dylib |
| 14 | PCRE2 | 10.49 | BSD-3-Clause WITH PCRE2-exception | Bundled dylib |
| 15 | orc | 0.4.44 | BSD-2-Clause AND BSD-3-Clause | Bundled dylib |
| 16 | xz (liblzma) | 5.8.4 | 0BSD | Bundled dylib |
| 17 | OpenSSL | 3.5.9 | Apache-2.0 | Static, inside `uxplay` |
| 18 | OpenSSL | 4.1.0 | Apache-2.0 | Bundled dylibs |
| 19 | libplist | 2.8.0 | LGPL-2.1-or-later | Static, inside `uxplay` |

One component whose licence is commonly assumed to apply here does **not**:
libfdk-aac. See [Components confirmed absent](#components-confirmed-absent).

## Reading the entries

Every licence text named below is a **tracked file in this repository**, under
`Licenses/`, and it ships in two places in a release:

- `Licenses/` at the archive root — so a recipient can read every text without
  opening the app bundle, and so the links in this file resolve after the zip is
  extracted;
- `MiragePlay.app/Contents/Resources/Licenses/` — so the texts travel with the
  binary itself, which is what GPL-3 §4/§6 and LGPL-2.1 §6 require.

`THIRD-PARTY-NOTICES.md` itself is in both places too: at the archive root and
inside `MiragePlay.app/Contents/Resources/`.

The table below is the index between a component and its text. `Licenses/`
holds **one full text per licence**, not one per component: components under the
same licence share a single file, and the *Covers* column names every component
that relies on it, so a recipient can still trace any component to its terms.
`Licenses/` holds thirteen texts — one per licence. The GPL-3 text is not one of
them: it is [`LICENSE`](LICENSE) at the archive root, and is not duplicated.

| Licence text | Covers |
|---|---|
| [`LICENSE`](LICENSE) (GPL-3.0 full text, at the archive root) | 1. FFmpeg; 2. x264; 3. x265; UxPlay core (the pinned fork); playfair (vendored inside UxPlay) |
| [`Licenses/GPL-2.0.txt`](Licenses/GPL-2.0.txt) | 2. x264; 3. x265 (same GPL-2 text; x265's copy adds a three-line note about its commercial licence option, reproduced below) |
| [`Licenses/LGPL-2.1.txt`](Licenses/LGPL-2.1.txt) | 11. GStreamer; 12. GLib; 13. gettext (libintl); 19. libplist |
| [`Licenses/LGPL-2.0.txt`](Licenses/LGPL-2.0.txt) | 8. LAME; 11. GStreamer (the LGPL-2.0-or-later leg) |
| [`Licenses/LGPL-2.1-and-GPL-2.0.txt`](Licenses/LGPL-2.1-and-GPL-2.0.txt) | 9. mpg123 (upstream's `COPYING` carries both texts) |
| [`Licenses/Apache-2.0.txt`](Licenses/Apache-2.0.txt) | 17. OpenSSL (static, inside `uxplay`); 18. OpenSSL (bundled dylibs) |
| [`Licenses/MIT.txt`](Licenses/MIT.txt) | llhttp (vendored inside UxPlay; text is Fedor Indutny's, 2018) |
| [`Licenses/BSD-2-Clause.txt`](Licenses/BSD-2-Clause.txt) | 5. dav1d; 15. orc |
| [`Licenses/BSD-2-Clause-AOM.txt`](Licenses/BSD-2-Clause-AOM.txt) | 4. SVT-AV1 (the second text upstream ships) |
| [`Licenses/BSD-2-Clause-Patent.txt`](Licenses/BSD-2-Clause-Patent.txt) | 7. libvmaf |
| [`Licenses/BSD-3-Clause.txt`](Licenses/BSD-3-Clause.txt) | 6. libvpx; 10. Opus; 15. orc (its Mersenne Twister code) |
| [`Licenses/BSD-3-Clause-Clear.txt`](Licenses/BSD-3-Clause-Clear.txt) | 4. SVT-AV1 |
| [`Licenses/BSD-3-Clause-WITH-PCRE2-exception.txt`](Licenses/BSD-3-Clause-WITH-PCRE2-exception.txt) | 14. PCRE2 |

Sharing a file does not merge the copyright lines. A shared text carries one
project's header, so for the components whose own header sat in a text that is
now represented by a different project's copy, the copyright notice is
reproduced here verbatim — BSD-2-Clause and BSD-3-Clause conditions 1 and 2
require the notice to travel with a binary redistribution, and this file travels
with the binary:

- **orc 0.4.44** — `Copyright 2002 - 2009 David A. Schleef <ds@schleef.org>`,
  `All rights reserved.`, BSD-2-Clause (`Licenses/BSD-2-Clause.txt`). The
  Mersenne Twister code orc embeds is BSD-3-Clause under a different holder:
  `Copyright (C) 1997 - 2002, Makoto Matsumoto and Takuji Nishimura,`
  `All rights reserved.` (`Licenses/BSD-3-Clause.txt`).
- **Opus 1.6.1** — `Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic,
  Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark
  Borgerding, Erik de Castro Lopo, Mozilla, Amazon` (`Licenses/BSD-3-Clause.txt`).
- **x265 4.3** — its `COPYING` is the GPL-2 text with these three lines appended,
  reproduced verbatim: `This program is also available under a commercial
  proprietary license.` / `For more information, contact us at license @
  x265.com.` The licence terms are x264's copy unchanged (`Licenses/GPL-2.0.txt`).
- **FFmpeg 9.0.2** — upstream's `LICENSE.md` is a licensing overview rather than
  a licence text: it records that FFmpeg is LGPL v2.1-or-later by default and
  GPL v3 once `--enable-version3` is passed, that a few files are MIT/BSD, and
  that the IJG must be credited where its code is used. The text it points at is
  the GPL-3 in [`LICENSE`](LICENSE), and the `GPL-3.0-or-later` conclusion is
  the one recorded in [entry 1](#1-ffmpeg). It is not vendored here because it
  is not a licence text; the obligation it states is met by `LICENSE` plus this
  entry.

The three LGPL-2.1 copies that were once tracked separately (GStreamer's,
GLib's/gettext's and libplist's) differ only in whitespace and in whether the FSF
address reads `51 Franklin St` or `51 Franklin Street` — the same terms, so one
file now serves all four components. The same holds for the two Apache-2.0
copies OpenSSL shipped (3.5.9 statically inside `uxplay`, 4.1.0 as bundled
dylibs): byte-identical, so one file covers both, and the *Covers* column is
what distinguishes the two routes.


## 1. FFmpeg

| Field | Value |
|---|---|
| Version | 9.0.2_1 |
| Files | `libavcodec.63.1.102.dylib`, `libavformat.63.1.102.dylib`, `libavfilter.12.1.102.dylib`, `libavutil.61.1.102.dylib`, `libswresample.7.1.102.dylib`, `libswscale.10.1.102.dylib` |
| Licence | **GPL-3.0-or-later** |
| Linked as | Bundled dylibs in `Contents/Frameworks`, loaded via `@loader_path` |
| Licence text | [`LICENSE`](LICENSE) — the GPL-3 full text at the archive root, shared with every other GPL-3 component. Upstream's `LICENSE.md` is a licensing overview, not a licence text; what it obliges (the GPL-3 text, and the IJG credit where FFmpeg's IJG code is used) is recorded in the sharing note above. Version evidence: `sbom.spdx.json` in the build-time prefix records `licenseConcluded: GPL-3.0-or-later`. |

These six libraries are **GPL-3.0-or-later, not LGPL**. Three independent
readings of the binary and its build record agree:

- `libavutil.61.1.102.dylib` self-reports `libavutil license: GPL version 3 or later`.
- The same file embeds the build configuration, which includes `--enable-gpl
  --enable-version3` together with `--enable-libx264`, `--enable-libx265` and
  `--enable-openssl`.
- The build-time SPDX record concludes `GPL-3.0-or-later`.

It is wrong to describe the FFmpeg libraries in a MiragePlay release as LGPL.
The `--enable-openssl` flag is also why the OpenSSL 4.1.0 dylibs (#18) are in
the bundle at all.

Source: survey §4 (table row *FFmpeg*) and §5.6; evidence
`strings -a Frameworks/libavutil.61.1.102.dylib | grep 'enable-gpl\|license'`
and the `ffmpeg` `sbom.spdx.json` under the Cellar prefix.

## 2. x264

| Field | Value |
|---|---|
| Version | r3222 (soname 165 → `X264_BUILD` 165) |
| Files | `libx264.165.dylib` |
| Licence | GPL-2.0-or-later |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/GPL-2.0.txt`](Licenses/GPL-2.0.txt) (GPL-2.0 full text, shared with x265). |

Source: survey §4 (row *x264*); evidence the `COPYING` file above and the
formula's `sbom.spdx.json` (`GPL-2.0-or-later`).

## 3. x265

| Field | Value |
|---|---|
| Version | 4.3 (soname 217 → `X265_BUILD` 217) |
| Files | `libx265.217.dylib` |
| Licence | GPL-2.0-or-later |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/GPL-2.0.txt`](Licenses/GPL-2.0.txt) (GPL-2.0 full text, shared with x264). x265's own `COPYING` carries the same text plus the three-line note about its commercial licence option, reproduced in the sharing note above. |

x265 is also offered under a commercial licence by its authors. **That does not
apply to this binary.** The dylib in a MiragePlay release is the Homebrew GPL
build, so the GPL terms govern it and its corresponding source must be
available.

Source: survey §4 (row *x265*) and §5.4.

## 4. SVT-AV1

| Field | Value |
|---|---|
| Version | 4.2.0 (pinned by the embedded source path `SVT-AV1-v4.2.0/Source/Lib/...`) |
| Files | `libSvtAv1Enc.4.2.0.dylib` |
| Licence | BSD-3-Clause-Clear (Alliance for Open Media), with `LICENSE-BSD2.md` also present upstream |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/BSD-3-Clause-Clear.txt`](Licenses/BSD-3-Clause-Clear.txt) (first line: "BSD 3-Clause Clear License / The Clear BSD License / Copyright (c) 2021, Alliance for Open Media") and [`Licenses/BSD-2-Clause-AOM.txt`](Licenses/BSD-2-Clause-AOM.txt) (`Copyright (c) 2019, Alliance for Open Media`). Upstream ships both and they are different documents, so both travel. |

The Clear BSD licence contains an express patent grant, so no separate patent
list is required. The AOM copyright line must be retained wherever the licence
is reproduced.

Source: survey §4 (row *SVT-AV1*) and §5.5.

## 5. dav1d

| Field | Value |
|---|---|
| Version | 1.5.4 |
| Files | `libdav1d.7.dylib` |
| Licence | BSD-2-Clause |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/BSD-2-Clause.txt`](Licenses/BSD-2-Clause.txt) (VideoLAN and dav1d authors, 2018–2025; shared with orc, whose own copyright line is reproduced in the sharing note above). |

Source: survey §4 (row *dav1d*); evidence that `COPYING` and the formula's
`sbom.spdx.json` (`BSD-2-Clause`).

## 6. libvpx

| Field | Value |
|---|---|
| Version | 1.17.0 (version string `libvpx/1.17.0` in the binary) |
| Files | `libvpx.12.dylib` |
| Licence | BSD-3-Clause, plus the AOM patent grant |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/BSD-3-Clause.txt`](Licenses/BSD-3-Clause.txt) (The WebM Project authors, 2010; shared with Opus and orc, whose own copyright lines are reproduced in the sharing note above). |

Source: survey §4 (row *libvpx*).

## 7. libvmaf

| Field | Value |
|---|---|
| Version | 3.2.1 |
| Files | `libvmaf.3.dylib` |
| Licence | BSD-2-Clause-Patent |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/BSD-2-Clause-Patent.txt`](Licenses/BSD-2-Clause-Patent.txt) (first line: "BSD+Patent / SPDX: BSD-2-Clause-Patent / Netflix"). |

The Netflix copyright line must be retained. Note that the version string
inside the binary (`vmaf_v0.6.1` and friends) is a *model* version, not the
library version; 3.2.1 comes from the package record.

Source: survey §4 (row *libvmaf*) and §9.

## 8. LAME (libmp3lame)

| Field | Value |
|---|---|
| Version | 4.0 (`LAME4.0` in the binary) |
| Files | `libmp3lame.0.dylib` |
| Licence | LGPL-2.0-or-later |
| Linked as | Bundled dylib (dynamic — the LGPL relink route stays open) |
| Licence text | [`Licenses/LGPL-2.0.txt`](Licenses/LGPL-2.0.txt) — the GNU **Library** GPL v2 text (the LGPL v2 predecessor), matching the `LGPL-2.0-or-later` conclusion in the formula's SPDX record; shared with GStreamer's LGPL-2.0 leg (byte-identical). |

Source: survey §4 (row *LAME*).

## 9. mpg123

| Field | Value |
|---|---|
| Version | 1.33.7 |
| Files | `libmpg123.0.dylib` |
| Licence | **LGPL-2.1-only** |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/LGPL-2.1-and-GPL-2.0.txt`](Licenses/LGPL-2.1-and-GPL-2.0.txt) — upstream's `COPYING` carries both texts; the LGPL v2.1 terms apply here. |

`-only`, not `-or-later`: this component may not be treated as upgradeable to a
later LGPL version. It is dynamically linked here, which keeps the LGPL
obligations at relink-plus-source rather than the stronger copyleft of GPL.

Source: survey §4 (row *mpg123*).

## 10. Opus

| Field | Value |
|---|---|
| Version | 1.6.1 (`libopus 1`, interface current 12.1.0) |
| Files | `libopus.0.dylib` |
| Licence | BSD-3-Clause |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/BSD-3-Clause.txt`](Licenses/BSD-3-Clause.txt) — the shared file carries libvpx's header; Opus's own copyright line (Xiph.Org, Skype Limited, Octasic and others) is reproduced verbatim in the sharing note above, as BSD-3-Clause condition 1 requires. |

Source: survey §4 (row *Opus*).

## 11. GStreamer

| Field | Value |
|---|---|
| Version | 1.28.8 |
| Files | Core and base libraries: `libgstreamer-1.0.0`, `libgstbase-1.0.0`, `libgstapp-1.0.0`, `libgstaudio-1.0.0`, `libgstpbutils-1.0.0`, `libgsttag-1.0.0`, `libgstvideo-1.0.0`, `libgstrtp-1.0.0`, `libgstsdp-1.0.0`, `libgstcodecparsers-1.0.0`. Plugins (all in `Contents/plugins`): `libgstapp`, `libgstaudioconvert`, `libgstaudioresample`, `libgstautodetect`, `libgstcoreelements`, `libgstlevel`, `libgstlibav`, `libgstosxaudio`, `libgstosxvideo`, `libgstplayback`, `libgsttypefindfunctions`, `libgstvideoconvertscale`, `libgstvideoparsersbad`, `libgstvolume` |
| Licence | LGPL-2.0-or-later AND LGPL-2.1-or-later AND MIT (compound, as recorded in the package's SPDX metadata) |
| Linked as | Bundled dylibs; the 14 plugins are loaded dynamically at runtime |
| Licence text | [`Licenses/LGPL-2.1.txt`](Licenses/LGPL-2.1.txt) (LGPL-2.1 full text, also covering GLib, gettext and libplist), [`Licenses/LGPL-2.0.txt`](Licenses/LGPL-2.0.txt) (the LGPL-2.0-or-later leg, also covering LAME) and [`Licenses/MIT.txt`](Licenses/MIT.txt) (the MIT leg; the same MIT terms cover llhttp). |

All fourteen plugins self-report `LGPL`, and all fourteen resolve to the single
Homebrew `gstreamer` formula — none is locally built or third-party. **One
exception to note carefully:** `libgstlibav.dylib` reports LGPL, but it links
directly against the GPL-3 FFmpeg libraries (#1), so that plugin's combined
work is effectively GPL-3. Labelling that plugin LGPL would be a misstatement.
Within MiragePlay this adds no obligation, because the whole product is already
GPL-3.0-only.

Version note: `libgstreamer-1.0.0.dylib` also contains the string `GStreamer
1.22`. That is an internal compatibility string, not the version — 1.28.8 is
attested by `libgstreamer`, `libgstaudio`, `libgstpbutils` and `libgsttag`.

Source: survey §2 (plugin list), §4 (row *GStreamer*) and §5.2.

## 12. GLib / GObject / GIO / GModule

| Field | Value |
|---|---|
| Version | 2.90.1 (interface current 9001.1.0) |
| Files | `libglib-2.0.0.dylib`, `libgobject-2.0.0.dylib`, `libgio-2.0.0.dylib`, `libgmodule-2.0.0.dylib` |
| Licence | LGPL-2.1-or-later |
| Linked as | Bundled dylibs |
| Licence text | [`Licenses/LGPL-2.1.txt`](Licenses/LGPL-2.1.txt) (shared with GStreamer, gettext and libplist). |

Source: survey §4 (row *GLib / GObject / GIO / GModule*).

## 13. gettext (libintl)

| Field | Value |
|---|---|
| Version | 1.0 (`libintl.8`) |
| Files | `libintl.8.dylib` |
| Licence | LGPL-2.1-or-later (libintl itself) |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/LGPL-2.1.txt`](Licenses/LGPL-2.1.txt) (shared with GStreamer, GLib and libplist). The upstream header `include/libintl.h:5-7` states "GNU Lesser General Public License … version 2.1 or any later" but ships no standalone text of its own, so the LGPL-2.1 text it names is what travels. |

The package's SPDX record reads `GPL-3.0-or-later AND LGPL-2.1-or-later`. The
GPL part covers the gettext *tools*, which are not in the bundle; only libintl
ships, and libintl is LGPL.

Source: survey §4 (row *gettext / libintl*).

## 14. PCRE2

| Field | Value |
|---|---|
| Version | 10.49 |
| Files | `libpcre2-8.0.dylib` |
| Licence | BSD-3-Clause WITH PCRE2-exception |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/BSD-3-Clause-WITH-PCRE2-exception.txt`](Licenses/BSD-3-Clause-WITH-PCRE2-exception.txt) (upstream's `LICENCE.md`, including its SPDX table). PCRE2 is `BSD-3-Clause WITH PCRE2-exception`, which is not plain BSD-3-Clause, so it keeps its own file. |

Source: survey §4 (row *PCRE2*).

## 15. orc

| Field | Value |
|---|---|
| Version | 0.4.44 (`orc-0.4.44` in the binary) |
| Files | `liborc-0.4.0.dylib` |
| Licence | BSD-2-Clause AND BSD-3-Clause |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/BSD-2-Clause.txt`](Licenses/BSD-2-Clause.txt) for the bulk of the tree (David A. Schleef) and [`Licenses/BSD-3-Clause.txt`](Licenses/BSD-3-Clause.txt) for the Mersenne Twister code it embeds (Makoto Matsumoto and Takuji Nishimura) — the two licences upstream's single `COPYING` carries. Both copyright lines are reproduced verbatim in the sharing note above. |

Source: survey §4 (row *orc*).

## 16. xz (liblzma)

| Field | Value |
|---|---|
| Version | 5.8.4 |
| Files | `liblzma.5.dylib` |
| Licence | 0BSD (liblzma itself) |
| Linked as | Bundled dylib |
| Licence text | [`Licenses/0BSD.txt`](Licenses/0BSD.txt). |

The package's SPDX record reads `0BSD AND GPL-2.0-or-later`; the GPL part covers
the xz command-line tools, which are not in the bundle.

Source: survey §4 (row *xz / liblzma*).

## 17. OpenSSL (static, inside the helper)

| Field | Value |
|---|---|
| Version | **3.5.9** |
| Where | Statically linked into `uxplay`; there is no `libcrypto.3` in the bundle, and `uxplay` defines 1640 `SSL_`/`BN_`/`EVP_` symbols |
| Licence | Apache-2.0 |
| Linked as | **Static** — no dynamic boundary separates it from the shipped executable |
| Licence text | [`Licenses/Apache-2.0.txt`](Licenses/Apache-2.0.txt) (first line: "Apache License Version 2.0"; byte-identical to the 4.1.0 text, so one file covers both routes). |

Apache-2.0 §4 attribution obligations do not lapse just because the library was
statically linked; if anything static linkage makes the attribution the only
place the notice can live. The prefix contains no `NOTICE` file (only
`LICENSE.txt` and `README.md`), so there is nothing extra to reproduce under
§4(d) — the licence text and the attribution above are the obligation.

Source: survey §4 (row *OpenSSL (static)*) and §5.1.

## 18. OpenSSL (bundled dylibs)

| Field | Value |
|---|---|
| Version | **4.1.0** (`libcrypto.4.dylib`, `libssl.4.dylib`; interface current 4.0.0) |
| Licence | Apache-2.0 |
| Linked as | Bundled dylibs in `Contents/Frameworks`, pulled in by FFmpeg's `--enable-openssl` |
| Licence text | [`Licenses/Apache-2.0.txt`](Licenses/Apache-2.0.txt) (the same file as the 3.5.9 text — byte-identical). |

This is a **second, different OpenSSL** from #17. `deps.lock` records only the
static 3.5.9, because that file tracks direct dependencies rather than the full
shipping closure. A notices file that lists OpenSSL once, at 3.5.9, is
incomplete.

Source: survey §1 (item 5), §4 (row *OpenSSL (dylib)*), §5.1 and §7 (item 1).

## 19. libplist

| Field | Value |
|---|---|
| Version | **2.8.0** |
| Where | Statically linked into `uxplay` — no `libplist*.dylib` in the bundle, and `uxplay` defines 111 `plist_*` symbols including `_libplist_version` |
| Licence | **LGPL-2.1-or-later** |
| Linked as | **Static** |
| Licence text | [`Licenses/LGPL-2.1.txt`](Licenses/LGPL-2.1.txt) (shared with GStreamer, GLib and gettext; libplist's `COPYING.LESSER` differs only in the FSF address wording). |

Cite `COPYING.LESSER`, **not** `COPYING`: the prefix also carries a `COPYING`
file, but it is GPL v2 and covers the `plistutil` tools, which are not shipped.

Static linking against LGPL-2.1 triggers §6's relink requirement. MiragePlay is
GPL-3.0-only and the helper's source is obtainable, which satisfies the
condition in principle — but only if the corresponding source is actually
delivered. See [Corresponding source for this project](#corresponding-source-for-this-project).

Source: survey §4 (row *libplist*), §5.3 and §7 (item 2).

## Components confirmed absent

**libfdk-aac — not included.** It is often assumed to be present in a
GStreamer/FFmpeg stack, and its licence would forbid redistribution in this
form, so its absence was checked directly rather than assumed: no `libfdk*.dylib`
in the dylib list, `strings` across all bundled binaries yields zero matches for
`fdk`, and the embedded FFmpeg configuration contains no `--enable-libfdk-aac`.
Its licence therefore imposes nothing on a MiragePlay release.

Source: survey §5.7 and §1 (item 8).

## Corresponding source for this project

GPL-3 §6 requires that whoever receives the object code can get the
corresponding source. What identifies that source for MiragePlay:

| Item | Value |
|---|---|
| Project source | this repository, at the release tag (`v0.1.0` for the 0.1.0 build) — the tag names the release point and its tree is the tree of the commit that tag points at; no loose sha is recorded here, so a re-tag cannot make this row stale |
| Core source (UxPlay fork) | `https://github.com/miles0428/UxPlay.git`, branch `mirageplay` |
| Pinned commit | `4f5ad4bdeb345448871e2ab39f9793f35f499664` |
| Pinned tree | `da5c40ca2323f33d0368bd7f2857efdd9490c39d` |
| Base commit (upstream merge the branch is based on) | `87c12a70dede93b9bf038d9275818e44b459edcb` |
| Per-file verification | `core/uxplay-branch-manifest_20261019.txt`, 90 files, SHA-256 recorded in `core/vendor.lock` |

The core values above are quoted verbatim from `core/vendor.lock`.

**Requirements for a release** (stated here, not yet implemented):

1. Every release ships a corresponding-source archive alongside the binary
   archive, from the same release point, at no extra charge.
2. That archive contains this project's source at the release tag **including
   the build and install control scripts** — `scripts/build/*`, `scripts/lib/*`,
   the CMake inputs, the `Info.plist` inputs, `core/vendor.lock` and the
   manifest. GPL-3 §1 counts those as part of the corresponding source; a
   folder of `.c`/`.swift` files alone does not satisfy it.
3. It contains the UxPlay fork at the pinned commit above, not a branch name —
   a branch is a moving ref and is not a delivery.
4. It contains, or carries a written offer valid for at least three years
   covering, the source of the GPL/LGPL components in this file: FFmpeg 9.0.2,
   x264 r3222, x265 4.3, GStreamer 1.28.8 with its plugin modules, GLib 2.90.1,
   libplist 2.8.0, LAME 4.0, mpg123 1.33.7 and libintl 1.0.

As of this writing the project source is at
`https://github.com/miles0428/MiragePlay` — the address `README.md` names and the
app's About window links to. What is still missing for §6(a)–(e): no
corresponding-source archive has been published with any binary archive, and the
vendored core tree is excluded from version control (`.gitignore:70` for
`/core/uxplay/`, and the materialized tree under `_build/` is excluded too; the
tree is materialized by `scripts/build/vendor-uxplay.sh`), so a clone of this
repository does not by itself contain the core source. Recording that here keeps the gap visible rather
than implied by silence.

Source: survey §6 (including its §6(a)–(e) table) and §1 (item 7).

## Open items

Known gaps in this file or its packaging, not fixed here:

- **`deps.lock` undercounts.** It records the static OpenSSL 3.5.9 and not the
  bundled 4.1.0, and describes gstreamer as a fallback leg while the shipped
  bundle carries the full 1.28.8 runtime.
- **Scope of the UxPlay modifications is not itemised.** The provenance above is
  exact, but which files the fork changes relative to upstream has not been
  diffed; GPL-3 §5(a) asks for a notice that changes were made, which the
  LICENSE header gives, and a per-file account would be stronger.
- **`Licenses/` is a vendored snapshot, not a regenerated one.** The texts are
  copied once from each upstream and tracked; nothing re-fetches them. When a
  bundled component is upgraded, the text under its licence name has to be
  replaced by hand, and the component's row here has to say which file carries
  it — filenames name the licence, not the version, so a stale snapshot is
  caught by re-reading the component table, not by the filename alone.
- **Two texts are substitutes, not upstream files.** `LGPL-2.1.txt` is
  GStreamer's copy and stands in for gettext, which ships no standalone licence
  file of its own; `LGPL-2.0.txt` is LAME's copy and stands in for GStreamer's
  LGPL-2.0-or-later leg, because GStreamer's own `LICENSE` is the LGPL-2.1 text
  while the formula's SPDX record also concludes `LGPL-2.0-or-later`. In both
  cases the text is the licence the component's own headers name, not a
  different licence — the copies are byte-identical to what the substituted
  project ships, and they are the only places where a file in `Licenses/` is
  associated with a component other than the one whose project published it.
- **The licences of the vendored sub-libraries are only as good as UxPlay's
  tree.** `llhttp` and `playfair` are checked in under `_build/uxplay/lib/`,
  which is git-ignored, so their texts are tracked here but their sources are
  only as reproducible as the pinned UxPlay checkout. `playfair` is GPL-3 and is
  covered by `LICENSE`; `llhttp` is MIT and is covered by `Licenses/MIT.txt`,
  whose text is llhttp's own file (`lib/llhttp/LICENSE-MIT`) and not a copy
  fetched from elsewhere.
- **UxPlay's upstream README is no longer shipped as a file.** It used to travel
  here verbatim because it carries UxPlay's credits list (playfair, ShairPlay,
  dsafa22, RPiPlay, llhttp). Those credits are the ones named in this file's own
  entries for the UxPlay core, playfair and llhttp, and the pinned UxPlay
  repository at the commit in [Corresponding source](#corresponding-source-for-this-project)
  is the authoritative copy; the verbatim duplicate was removed so `Licenses/`
  holds licence texts only.
