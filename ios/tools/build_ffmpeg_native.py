#!/usr/bin/env python3
"""Reproducible LGPL-only FFmpeg/dav1d Apple arm64 builds, isolated from Android sources."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "ios/Native/ffmpeg"
ARCHIVE_DIR = ROOT / "third_party/src"
MESON = ROOT / "tools/spike/.venv/bin/meson"
NINJA = ROOT / "tools/spike/.venv/bin/ninja"
PKG_CONFIG = "/opt/homebrew/bin/pkg-config"
VENDOR_ONLY = False
ARCHIVES = {
    "ffmpeg-7.1.1": ("ffmpeg-7.1.1.tar.xz", "733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"),
    "dav1d-1.5.1": ("dav1d-1.5.1.tar.gz", "fa635e2bdb25147b1384007c83e15de44c589582bb3b9a53fc1579cb9d74b695"),
}


def run(command, cwd, log, env=None):
    with log.open("w") as output:
        subprocess.run([str(x) for x in command], cwd=cwd, env=env, stdout=output,
                       stderr=subprocess.STDOUT, check=True)


def source_trees():
    folder = NATIVE / "build/sources"
    folder.mkdir(parents=True, exist_ok=True)
    for name, (filename, digest) in ARCHIVES.items():
        archive = ARCHIVE_DIR / filename
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"Unexpected source archive hash: {filename}")
        if not (folder / name).exists():
            with tarfile.open(archive) as bundle:
                bundle.extractall(folder, filter="data")
    return folder


def build(platform, sources, jobs):
    target = {"iphoneos": "arm64-apple-ios17.0", "iphonesimulator": "arm64-apple-ios17.0-simulator",
              "macosx": "arm64-apple-macos14.0"}[platform]
    sdk = subprocess.check_output(["xcrun", "--sdk", platform, "--show-sdk-path"], text=True).strip()
    work = NATIVE / "build" / platform
    prefix = NATIVE / "lib" / platform
    work.mkdir(parents=True, exist_ok=True)
    prefix.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = str(Path(MESON).parent) + os.pathsep + env["PATH"]
    env["PKG_CONFIG_LIBDIR"] = str(prefix / "lib/pkgconfig")
    env["PKG_CONFIG_PATH"] = env["PKG_CONFIG_LIBDIR"]
    flags = ["-target", target, "-isysroot", sdk, "-fPIC", "-O2",
             f"-ffile-prefix-map={ROOT}=/smoothplayer-source", f"-fdebug-prefix-map={ROOT}=/smoothplayer-source"]
    cross = work / "dav1d.cross"
    cross.write_text("[binaries]\nc = 'clang'\ncpp = 'clang++'\nar = 'ar'\nstrip = 'strip'\n"
                     "[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'arm64'\nendian = 'little'\n"
                     "[properties]\nneeds_exe_wrapper = true\n[built-in options]\ndefault_library = 'static'\n"
                     f"c_args = {flags!r}\nc_link_args = {flags!r}\n")
    davbuild = work / "dav1d"
    setup = [MESON, "setup", davbuild, sources / "dav1d-1.5.1", "--cross-file", cross,
             "--prefix", prefix, "--libdir=lib", "--buildtype=release", "-Denable_tools=false",
             "-Denable_tests=false", "-Denable_examples=false", "-Denable_docs=false", "-Dbitdepths=8,16"]
    if (davbuild / "meson-private/coredata.dat").exists():
        setup.append("--reconfigure")
    print(f"{platform}: configuring/building dav1d", flush=True)
    run(setup, work, work / "dav1d-configure.log", env)
    run([NINJA, "-C", davbuild, "-j", jobs], work, work / "dav1d-build.log", env)
    run([NINJA, "-C", davbuild, "install"], work, work / "dav1d-install.log", env)
    ffbuild = work / "ffmpeg"
    ffbuild.mkdir(exist_ok=True)
    env["CFLAGS"] = " ".join(flags)
    env["LDFLAGS"] = " ".join(flags[:4])
    configure = [sources / "ffmpeg-7.1.1/configure", "--prefix=/", "--target-os=darwin", "--arch=aarch64",
                 "--cpu=armv8-a", "--enable-cross-compile", "--cc=clang", "--cxx=clang++", "--ar=ar",
                 "--nm=nm", "--ranlib=ranlib", "--strip=strip", "--sysroot=" + sdk,
                 "--pkg-config=" + str(PKG_CONFIG), "--pkg-config-flags=--static",
                 "--disable-autodetect", "--disable-gpl", "--disable-nonfree", "--disable-version3",
                 "--enable-static", "--disable-shared", "--enable-pic", "--disable-programs", "--disable-doc",
                 "--disable-debug", "--disable-encoders", "--disable-muxers", "--disable-devices",
                 "--disable-avdevice", "--disable-postproc", "--disable-avfilter", "--disable-filters",
                 "--disable-protocols", "--enable-protocol=file,pipe", "--enable-libdav1d",
                 "--enable-videotoolbox", "--disable-audiotoolbox", "--enable-zlib", "--disable-network",
                 "--extra-cflags=-target " + target, "--extra-ldflags=-target " + target]
    print(f"{platform}: configuring/building FFmpeg (all LGPL-enabled built-in decoders/demuxers)", flush=True)
    run(configure, ffbuild, work / "ffmpeg-configure.log", env)
    config = (ffbuild / "config.h").read_text()
    for option in ["GPL", "NONFREE", "VERSION3"]:
        if f"#define CONFIG_{option} 0" not in config:
            raise RuntimeError(f"Disallowed license configuration {option}")
    components = (ffbuild / "config_components.h").read_text()
    required = ["H264_DECODER", "HEVC_DECODER", "AAC_DECODER", "AC3_DECODER", "EAC3_DECODER",
                "DCA_DECODER", "VP8_DECODER", "VP9_DECODER", "LIBDAV1D_DECODER", "MPEG4_DECODER",
                "MATROSKA_DEMUXER", "AVI_DEMUXER", "MOV_DEMUXER", "MPEGTS_DEMUXER",
                "FLAC_DECODER", "TRUEHD_DECODER"]
    for component in required:
        if f"#define CONFIG_{component} 1" not in components:
            raise RuntimeError(f"Required playback component missing: {component}")
    run(["make", "-j", jobs], ffbuild, work / "ffmpeg-build.log", env)
    run(["make", "install", f"DESTDIR={prefix}"], ffbuild, work / "ffmpeg-install.log", env)
    libraries = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((prefix / "lib").glob("*.a"))}
    evidence = {"platform": platform, "target": target, "source_archives": ARCHIVES,
                "ffmpeg_configure_argv": [str(x).replace(str(ROOT), "$PROJECT_ROOT") for x in configure],
                "cflags": [x.replace(str(ROOT), "$PROJECT_ROOT") for x in flags],
                "license": "FFmpeg LGPL-2.1-or-later; dav1d BSD-2-Clause; GPL/nonfree/version3 disabled",
                "required_components_verified": required,
                "libraries": libraries}
    (work / "build-manifest.json").write_text(json.dumps(evidence, indent=2) + "\n")
    shutil.copyfile(ffbuild / "config.h", work / "ffmpeg-config.h")
    shutil.copyfile(ffbuild / "config_components.h", work / "ffmpeg-config-components.h")
    print(f"{platform}: built {len(libraries)} static libraries", flush=True)
    if not VENDOR_ONLY:
        build_bridge(platform)


def build_bridge(platform):
    target = {"iphoneos": "arm64-apple-ios17.0", "iphonesimulator": "arm64-apple-ios17.0-simulator",
              "macosx": "arm64-apple-macos14.0"}[platform]
    sdk = subprocess.check_output(["xcrun", "--sdk", platform, "--show-sdk-path"], text=True).strip()
    work, prefix = NATIVE / "build" / platform, NATIVE / "lib" / platform
    command = ["xcrun", "--sdk", platform, "clang", "-target", target, "-isysroot", sdk, "-std=c11",
               "-O2", "-Wall", "-Wextra", "-Werror", "-fPIC", f"-ffile-prefix-map={ROOT}=/smoothplayer-source",
               "-I" + str(NATIVE / "include"), "-I" + str(prefix / "include"), "-c",
               NATIVE / "src/SmoothPlayerFFmpeg.c", "-o", work / "SmoothPlayerFFmpeg.o"]
    run(command, work, work / "bridge-build.log")
    libraries = sorted((prefix / "lib").glob("*.a"))
    run(["xcrun", "--sdk", platform, "libtool", "-static", "-o", prefix / "libSmoothPlayerFFmpeg.a",
         work / "SmoothPlayerFFmpeg.o", *libraries], work, work / "bridge-archive.log")
    evidence_path = work / "build-manifest.json"
    evidence = json.loads(evidence_path.read_text())
    evidence["bridge_source_sha256"] = hashlib.sha256((NATIVE / "src/SmoothPlayerFFmpeg.c").read_bytes()).hexdigest()
    evidence["combined_archive_sha256"] = hashlib.sha256((prefix / "libSmoothPlayerFFmpeg.a").read_bytes()).hexdigest()
    evidence["link_requirements"] = ["-lz", "-framework VideoToolbox", "-framework CoreMedia", "-framework CoreVideo",
                                     "-framework CoreFoundation", "-framework QuartzCore"]
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"{platform}: decoder bridge and combined archive built", flush=True)


def main():
    global ROOT, NATIVE, ARCHIVE_DIR, MESON, NINJA, PKG_CONFIG, VENDOR_ONLY
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", action="append", choices=["iphoneos", "iphonesimulator", "macosx"])
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--bridge-only", action="store_true")
    parser.add_argument("--vendor-only", action="store_true", help="Build only LGPL/BSD libraries; no proprietary bridge source is needed.")
    parser.add_argument("--project-root", type=Path)
    parser.add_argument("--native-dir", type=Path)
    parser.add_argument("--source-archive-dir", type=Path)
    parser.add_argument("--meson")
    parser.add_argument("--ninja")
    parser.add_argument("--pkg-config")
    args = parser.parse_args()
    if args.project_root: ROOT = args.project_root.resolve()
    if args.native_dir: NATIVE = args.native_dir.resolve()
    if args.source_archive_dir: ARCHIVE_DIR = args.source_archive_dir.resolve()
    if args.meson: MESON = args.meson
    if args.ninja: NINJA = args.ninja
    if args.pkg_config: PKG_CONFIG = args.pkg_config
    VENDOR_ONLY = args.vendor_only
    if args.bridge_only and args.vendor_only:
        parser.error("--bridge-only and --vendor-only are mutually exclusive")
    sources = source_trees()
    platforms = args.platform or ["iphoneos", "iphonesimulator"]
    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda p: build_bridge(p) if args.bridge_only else build(p, sources, str(max(1, min(args.jobs, 8)))), platforms))


if __name__ == "__main__":
    main()
