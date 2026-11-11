#!/usr/bin/env python3
"""Build exact-source libass/CoreText + static dependencies for Apple arm64, without changing Android or FFmpeg."""
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "ios/Native/subtitles"
ARCHIVES = ROOT / "third_party/src"
LIBASS = "libass-0.17.5"
LIBASS_SHA = "2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"
DEPS = ["freetype2", "fribidi", "harfbuzz", "libunibreak"]
MESON = ROOT / "tools/spike/.venv/bin/meson"
NINJA = ROOT / "tools/spike/.venv/bin/ninja"
WRAPS = ROOT / "third_party/wraps/libass"
PKG_CONFIG = "/opt/homebrew/bin/pkg-config"
TARGETS = {"iphoneos": "arm64-apple-ios17.0", "iphonesimulator": "arm64-apple-ios17.0-simulator", "macosx": "arm64-apple-macos14.0"}

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def run(argv, cwd, log, env=None):
    with log.open("w") as output:
        subprocess.run([str(x) for x in argv], cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)

def sources():
    archive = ARCHIVES / (LIBASS + ".tar.xz")
    if digest(archive) != LIBASS_SHA: raise RuntimeError("libass source archive hash mismatch")
    destination = NATIVE / "build/sources"
    destination.mkdir(parents=True, exist_ok=True)
    source = destination / LIBASS
    if not source.exists():
        with tarfile.open(archive) as bundle: bundle.extractall(destination, filter="data")
    upstream = WRAPS
    subprojects = source / "subprojects"
    cache = subprojects / "packagecache"
    cache.mkdir(parents=True, exist_ok=True)
    manifest = [{"file": archive.name, "sha256": LIBASS_SHA, "license": "ISC"}]
    for dependency in DEPS:
        wrap = upstream / (dependency + ".wrap")
        config = configparser.ConfigParser(); config.read(wrap)
        record = config["wrap-file"]
        target_wrap = subprojects / wrap.name
        if target_wrap.exists() and digest(target_wrap) != digest(wrap):
            raise RuntimeError(f"Refusing to overwrite locally modified {target_wrap}")
        shutil.copyfile(wrap, subprojects / wrap.name)
        for kind in ["source", "patch"]:
            if kind + "_filename" not in record: continue
            filename, expected = record[kind + "_filename"], record[kind + "_hash"]
            # Standalone relink packages supply their own wrap/cache directory.
            cache_root = (ARCHIVES / LIBASS / "subprojects/packagecache"
                          if WRAPS == ROOT / "third_party/wraps/libass" else upstream / "packagecache")
            item = cache_root / filename
            if not item.exists():
                cache_root.mkdir(parents=True, exist_ok=True)
                temporary = item.with_suffix(item.suffix + ".download")
                try:
                    urllib.request.urlretrieve(record[kind + "_url"], temporary)
                    if digest(temporary) != expected: raise RuntimeError(f"Unexpected archive hash: {filename}")
                    temporary.replace(item)
                finally:
                    temporary.unlink(missing_ok=True)
            if digest(item) != expected: raise RuntimeError(f"Unexpected archive hash: {filename}")
            shutil.copyfile(item, cache / filename)
            manifest.append({"file": filename, "sha256": expected, "upstream_url": record[kind + "_url"]})
    return source, manifest

def bridge(platform):
    work, prefix = NATIVE / "build" / platform, NATIVE / "lib" / platform
    sdk = subprocess.check_output(["xcrun", "--sdk", platform, "--show-sdk-path"], text=True).strip()
    command = ["xcrun", "--sdk", platform, "clang", "-target", TARGETS[platform], "-isysroot", sdk,
               "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-fPIC", f"-ffile-prefix-map={ROOT}=/smoothplayer-source",
               "-I" + str(NATIVE / "include"), "-I" + str(prefix / "include"),
               "-I" + str(ROOT / "ios/Native/ffmpeg/lib" / platform / "include"), "-c",
               NATIVE / "src/SmoothPlayerSubtitles.c", "-o", work / "SmoothPlayerSubtitles.o"]
    run(command, work, work / "bridge-build.log")
    libraries = sorted((prefix / "lib").glob("*.a"))
    run(["xcrun", "--sdk", platform, "libtool", "-static", "-o", prefix / "libSmoothPlayerSubtitles.a",
         work / "SmoothPlayerSubtitles.o", *libraries], work, work / "bridge-archive.log")
    path = work / "build-manifest.json"
    record = json.loads(path.read_text())
    record["bridge_source_sha256"] = digest(NATIVE / "src/SmoothPlayerSubtitles.c")
    record["bridge_object_sha256"] = digest(work / "SmoothPlayerSubtitles.o")
    record["combined_archive_sha256"] = digest(prefix / "libSmoothPlayerSubtitles.a")
    path.write_text(json.dumps(record, indent=2) + "\n")
    print(f"{platform}: bridge + {len(libraries)} static libraries complete", flush=True)

def build(platform, source, archives, jobs, vendor_only):
    work, prefix = NATIVE / "build" / platform, NATIVE / "lib" / platform
    work.mkdir(parents=True, exist_ok=True); prefix.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", platform, "--show-sdk-path"], text=True).strip()
    flags = ["-target", TARGETS[platform], "-isysroot", sdk, "-fPIC", "-O2", "-g0",
             f"-ffile-prefix-map={ROOT}=/smoothplayer-source", f"-fdebug-prefix-map={ROOT}=/smoothplayer-source"]
    cross = work / "apple.cross"
    cross.write_text("[binaries]\nc = 'clang'\ncpp = 'clang++'\nar = 'ar'\nstrip = 'strip'\n" + f"pkg-config = {PKG_CONFIG!r}\n" +
                     "[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'arm64'\nendian = 'little'\n"
                     "[properties]\nneeds_exe_wrapper = true\n[built-in options]\ndefault_library = 'static'\n"
                     f"c_args = {flags!r}\ncpp_args = {flags + ['-DHB_NO_OPEN']!r}\nc_link_args = {flags!r}\ncpp_link_args = {flags!r}\n")
    env = os.environ.copy(); env["PATH"] = str(MESON.parent) + os.pathsep + env["PATH"]
    # These are release tarballs, not a checkout of the surrounding proprietary app repository.
    env["GIT_CEILING_DIRECTORIES"] = str(source.parent)
    env["PKG_CONFIG_LIBDIR"] = str(prefix / "lib/pkgconfig"); env["PKG_CONFIG_PATH"] = env["PKG_CONFIG_LIBDIR"]
    options = ["-Dfontconfig=disabled", "-Dcoretext=enabled", "-Ddirectwrite=disabled", "-Drequire-system-font-provider=true",
               "-Dlibunibreak=enabled", "-Dasm=disabled", "-Dtest=disabled", "-Dcompare=disabled", "-Dprofile=disabled",
               "-Dfuzz=disabled", "-Dcheckasm=disabled", "-Dfreetype2:brotli=disabled", "-Dfreetype2:bzip2=disabled",
               "-Dfreetype2:harfbuzz=disabled", "-Dfreetype2:png=disabled", "-Dfreetype2:zlib=system",
               "-Dfreetype2:hvf=disabled", "-Dfreetype2:mmap=disabled",
               "-Dharfbuzz:glib=disabled", "-Dharfbuzz:gobject=disabled", "-Dharfbuzz:cairo=disabled", "-Dharfbuzz:icu=disabled",
               "-Dharfbuzz:freetype=enabled", "-Dharfbuzz:subset=disabled", "-Dharfbuzz:raster=disabled", "-Dharfbuzz:vector=disabled",
               "-Dharfbuzz:chafa=disabled", "-Dharfbuzz:tests=disabled", "-Dharfbuzz:docs=disabled", "-Dharfbuzz:utilities=disabled",
               "-Dfribidi:docs=false", "-Dfribidi:tests=false", "-Dfribidi:bin=false"]
    builddir = work / LIBASS
    command = [MESON, "setup", builddir, source, "--cross-file", cross, "--prefix", prefix, "--libdir=lib", "--buildtype=release",
               "--wrap-mode=nodownload", "--force-fallback-for=freetype2,fribidi,harfbuzz,libunibreak",
               "-Dc_args=" + json.dumps(flags), "-Dcpp_args=" + json.dumps(flags + ["-DHB_NO_OPEN"]),
               "-Ddefault_library=static", "-Db_lto=false", *options]
    if (builddir / "meson-private/coredata.dat").exists(): command.append("--reconfigure")
    print(f"{platform}: libass/CoreText and four static dependencies", flush=True)
    run(command, work, work / "configure.log", env)
    run([NINJA, "-C", builddir, "-j", str(jobs)], work, work / "build.log", env)
    run([NINJA, "-C", builddir, "install"], work, work / "install.log", env)
    for archive in (builddir / "subprojects").rglob("*.a"):
        shutil.copyfile(archive, prefix / "lib" / archive.name)
    libraries = {p.name: digest(p) for p in sorted((prefix / "lib").glob("*.a"))}
    required = {"libass.a", "libfreetype.a", "libfribidi.a", "libharfbuzz.a", "libunibreak.a"}
    if not required.issubset(libraries): raise RuntimeError(f"Missing vendor libraries: {required - libraries.keys()}")
    record = {"platform": platform, "target": TARGETS[platform], "source_archives": archives,
              "libass_options": options, "libraries": libraries,
              "licenses": {"libass": "ISC", "freetype": "FTL", "harfbuzz": "MIT", "fribidi": "LGPL-2.1-or-later", "libunibreak": "Zlib"},
              "harfbuzz_cpp_defines": ["HB_NO_OPEN"],
              "link_requirements": ["libSmoothPlayerFFmpeg.a (existing FFmpeg symbols)", "-lc++", "-lz", "-liconv", "-framework CoreText", "-framework CoreGraphics", "-framework CoreFoundation"]}
    (work / "build-manifest.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"{platform}: vendor libraries complete", flush=True)
    if not vendor_only: bridge(platform)

def main():
    global ROOT, NATIVE, ARCHIVES, WRAPS, MESON, NINJA, PKG_CONFIG
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", action="append", choices=TARGETS)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--vendor-only", action="store_true")
    parser.add_argument("--bridge-only", action="store_true")
    parser.add_argument("--project-root", type=Path)
    parser.add_argument("--native-dir", type=Path)
    parser.add_argument("--source-archive-dir", type=Path)
    parser.add_argument("--wrap-dir", type=Path)
    parser.add_argument("--meson")
    parser.add_argument("--ninja")
    parser.add_argument("--pkg-config")
    args = parser.parse_args()
    if args.project_root: ROOT = args.project_root.resolve()
    if args.native_dir: NATIVE = args.native_dir.resolve()
    if args.source_archive_dir: ARCHIVES = args.source_archive_dir.resolve()
    if args.wrap_dir: WRAPS = args.wrap_dir.resolve()
    if args.meson: MESON = Path(args.meson)
    if args.ninja: NINJA = Path(args.ninja)
    if args.pkg_config: PKG_CONFIG = args.pkg_config
    if args.vendor_only and args.bridge_only: parser.error("Choose one build mode")
    source, archives = (None, None) if args.bridge_only else sources()
    for platform in args.platform or ["macosx", "iphoneos", "iphonesimulator"]:
        if args.bridge_only: bridge(platform)
        else: build(platform, source, archives, max(1, min(8, args.jobs)), args.vendor_only)

if __name__ == "__main__": main()
