# Third-party materials

The root MIT license covers NODELABS-authored work, not all bundled components.
The complete notices are in `ios/SmoothPlayer/Resources/OpenSourceNotices.txt`
and are shown in the Mac app. That shared notice also mentions mobile-only
components; the Mac build removes its iOS TV protocol section.

| Component | Version | License | Source and rebuild |
| --- | --- | --- | --- |
| FFmpeg | 7.1.1 | LGPL-2.1-or-later | Exact tarball in `third_party/src`; `ios/tools/build_ffmpeg_native.py` disables GPL, nonfree and version3 |
| dav1d | 1.5.1 | BSD-2-Clause | Exact tarball in `third_party/src`; FFmpeg build script |
| libsmb2 | 6.2 with bounds backport | LGPL-2.1-or-later | Exact tarball and reviewed patch in `third_party`; `macos/tools/build_nas.py` |
| libass | 0.17.5 | ISC | Exact tarball; `ios/tools/build_subtitles_native.py` |
| FreeType | 2.15.0 | FreeType License (selected) | Pinned wrap and source archive in libass packagecache |
| FriBidi | 1.0.17 | LGPL-2.1-or-later | Pinned wrap and source archive in libass packagecache |
| HarfBuzz | 13.0.1 | MIT | Pinned wrap and source archive in libass packagecache |
| libunibreak | 6.1 | Zlib | Pinned wrap, archive and patch in libass packagecache |
| RIFE/IFNet | Practical-RIFE v4.26 weights | MIT | Full MIT notice and upstream README in `tools/spike/third_party/Practical-RIFE`; model architecture and weights in sibling `rife_v4.26` |
| FSR 1 EASU-derived filter | a21ffb8f6c13233ba336352bdff293894c706575 | MIT | `third_party/fidelityfx-fsr/LICENSE` and README describe the Metal port |

Apple frameworks and SDK libraries are supplied by macOS/Xcode, not relicensed
here. Google sign-in artwork and PayPal names retain their respective owners'
rights. Python package licenses are available in the installed distributions;
versions are pinned in `account-server/requirements.txt` and `requirements.lock`.

The complete application source, exact library sources, modifications and build
commands are provided for rebuilding and relinking the statically linked LGPL
components. You may modify those components and relink your own app build.
