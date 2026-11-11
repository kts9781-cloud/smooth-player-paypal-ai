#!/usr/bin/env python3
"""Build the native arm64 Mac app from shared sources; no downloads or publishing."""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
SHARED = ROOT / "ios/SmoothPlayer"
DEFAULT_SIGN_IDENTITY = "Developer ID Application: NODELABS.Co.,Ltd. (JJU7BR79PJ)"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True)


def account_configuration(path, allow_test, environ):
    """Load public build settings; never infer a production/test environment."""
    if path:
        if environ.get("SMOOTHPLAYER_ACCOUNT_URL") or environ.get("SMOOTHPLAYER_ACCOUNT_PUBLIC_KEY"):
            raise ValueError("Choose an account config file or environment settings, not both")
        settings = json.loads(Path(path).read_text())
        if set(settings) != {"origin", "publicKey", "environment"}:
            raise ValueError("Account config must contain only origin, publicKey and environment")
        if settings["environment"] != ("test" if allow_test else "production"):
            raise ValueError("Account config environment must match the explicit --account-test choice")
    else:
        settings = {"origin": environ.get("SMOOTHPLAYER_ACCOUNT_URL", ""),
                    "publicKey": environ.get("SMOOTHPLAYER_ACCOUNT_PUBLIC_KEY", ""),
                    "environment": "test" if allow_test else "production"}
        if not settings["origin"] and not settings["publicKey"]:
            return None
    if not all(isinstance(v, str) and v for v in settings.values()):
        raise ValueError("Account URL, environment and pinned public key must all be configured")
    settings["origin"] = settings["origin"].rstrip("/")
    parsed = urlsplit(settings["origin"])
    if not parsed.hostname or parsed.path or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Account URL must be an origin without credentials or a path")
    if parsed.scheme != "https" and not (allow_test and parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")):
        raise ValueError("Account service requires HTTPS; HTTP is limited to explicit loopback tests")
    return settings


def source_files():
    files = sorted((SHARED / "Domain").glob("*.swift"))
    files += sorted((SHARED / "Interpolation").glob("*.swift"))
    files += [SHARED / name for name in [
        "Playback/FFmpegDecoder.swift", "Playback/FFmpegPlayback.swift",
        "Services/AccountStore.swift", "Services/TrialStore.swift", "Views/AccountView.swift", "Views/AdminOverviewView.swift", "Views/SoundControls.swift", "Views/AppPromotionActions.swift",
        "Services/NASAccountSync.swift", "Services/NASCloudAdapter.swift",
        "Services/NASRecentStore.swift", "Services/FolderPrivacyStore.swift",
        "Network/MediaByteStream.swift", "Network/HTTPSRangeStream.swift", "Network/MediaReadAhead.swift",
        "Network/NASClient.swift", "Network/NASConnection.swift", "Network/NASCredentialStore.swift",
        "Network/NASVideoThumbnails.swift", "Network/NASPreviewIdentity.swift", "Network/VideoPreviewDiskCache.swift",
        "Subtitles/NativeSubtitleTypes.swift", "Subtitles/NativeSubtitleController.swift"]]
    files += sorted((ROOT / "macos/SmoothPlayerMac").glob("*.swift"))
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/macos-2026-10-28")
    parser.add_argument("--sign", default=DEFAULT_SIGN_IDENTITY,
                        help="Developer ID Application identity (defaults to the existing NODELABS publisher)")
    parser.add_argument("--skip-resources", action="store_true", help="Reuse already compiled resources for incremental local builds")
    parser.add_argument("--account-test", action="store_true", help="Explicitly allow test account service; never for public distribution")
    parser.add_argument("--hackathon-demo", action="store_true", help="Separate Sandbox bundle, storage and keychain; requires --account-test")
    parser.add_argument("--account-config", type=Path, help="Public origin/key/environment JSON; defaults to Config/Account.production.json for production builds")
    args = parser.parse_args()
    if args.hackathon_demo and not (args.account_test and args.account_config):
        parser.error("The isolated demo requires --account-test and an explicit --account-config")
    if not args.account_config and not args.account_test and not any(
            os.environ.get(key) for key in ("SMOOTHPLAYER_ACCOUNT_URL", "SMOOTHPLAYER_ACCOUNT_PUBLIC_KEY")):
        args.account_config = ROOT / "macos/Config/Account.production.json"
    account = account_configuration(args.account_config, args.account_test, os.environ)
    # Keep the installed app's publisher requirement stable. An ad-hoc build with
    # the same bundle identifier triggers macOS's changed-developer/data-access warning.
    ad_hoc_demo = args.hackathon_demo and args.sign == "-"
    if not ad_hoc_demo and not args.sign.startswith("Developer ID Application:"):
        parser.error("Use an existing Developer ID Application identity; ad-hoc signing this app is not supported")
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    if not ad_hoc_demo and '"' + args.sign + '"' not in identities:
        parser.error("The selected Developer ID Application identity is unavailable in the keychain")
    out = args.output.resolve()
    if not out.is_relative_to(ROOT / "build"):
        raise ValueError("Build output must be inside this project's build directory")
    out.mkdir(parents=True, exist_ok=True)
    app = out / ("Smooth Player Demo.app" if args.hackathon_demo else "Smooth Player.app")
    contents = app / "Contents"
    resources = contents / "Resources"
    objects = out / "objects"
    for path in [resources, contents / "MacOS", objects]:
        path.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = "arm64-apple-macos15.0"
    sources = source_files()
    if not any(p.name == "MacApp.swift" for p in sources):
        raise ValueError("Mac app source is not ready")
    native = ROOT / "ios/Native"
    includes = [native / "include", native / "ffmpeg/include", native / "subtitles/include"]
    libraries = {"ffmpeg": native / "ffmpeg/lib/macosx/libSmoothPlayerFFmpeg.a",
                 "subtitles": native / "subtitles/lib/macosx/libSmoothPlayerSubtitles.a",
                 "nas": native / "lib/macosx/libSmoothPlayerNAS.a"}
    watched = sources + list(libraries.values())
    watched += [SHARED / "Interpolation" / name for name in ["VideoEnhance.metal", "FlowWarp.metal"]]
    watched += [ROOT / "macos/Config/Info.plist", ROOT / "macos/Config/SmoothPlayerMac.entitlements", Path(__file__).resolve()]
    watched += [SHARED / "Resources/OpenSourceNotices.txt", SHARED / "Resources/smooth-preview.mp4",
                SHARED / "Assets.xcassets/AppIcon.appiconset/icon-1024.png"]
    watched += sorted((SHARED / "Assets.xcassets/GoogleLogin.imageset").glob("*"))
    watched += sorted((SHARED / "Domain/AppLocalization").glob("*.json"))
    watched += sorted((ROOT / "macos/Resources").glob("*.lproj/InfoPlist.strings"))
    if args.account_config:
        watched.append(args.account_config.resolve())
    for folder in ["ffmpeg", "subtitles"]:
        watched += sorted((native / folder / "src").glob("*.c"))
        watched += sorted((native / folder / "include").glob("*.h"))
    watched += [path / "module.modulemap" for path in includes]
    watched += [native / "src/SmoothPlayerNAS.c", native / "include/SmoothPlayerNAS.h"]
    watched += [p for p in (ROOT / "ios/Models/IFNet3Block.mlpackage").rglob("*") if p.is_file()]
    inputs = {str(p.relative_to(ROOT)): sha(p) for p in watched}
    if not args.skip_resources:
        compiler_candidates = sorted(Path("/var/run/com.apple.security.cryptexd/mnt").glob(
            "com.apple.MobileAsset.MetalToolchain-*/Metal.xctoolchain/usr/bin/metal"))
        compiler = compiler_candidates[-1] if compiler_candidates else "metal"
        for name in ["VideoEnhance", "FlowWarp"]:
            source = SHARED / "Interpolation" / (name + ".metal")
            run([compiler, "-fmodules-cache-path=" + str(out / "metal-cache"), "-c", "-target",
                 "air64-apple-macos15.0", "-isysroot", sdk, source, "-o", out / (name + ".air")])
        run([compiler, "-target", "air64-apple-macos15.0", "-isysroot", sdk,
             out / "VideoEnhance.air", out / "FlowWarp.air", "-framework", "CoreImage",
             "-o", resources / "default.metallib"])
        run(["xcrun", "coremlcompiler", "compile", ROOT / "ios/Models/IFNet3Block.mlpackage", resources])
        icons = out / "AppIcon.iconset"
        icons.mkdir(exist_ok=True)
        original = SHARED / "Assets.xcassets/AppIcon.appiconset/icon-1024.png"
        for size in [16, 32, 128, 256, 512]:
            for retina in [False, True]:
                pixels = size * (2 if retina else 1)
                name = f"icon_{size}x{size}" + ("@2x" if retina else "") + ".png"
                run(["sips", "-z", pixels, pixels, original, "--out", icons / name])
        run(["iconutil", "-c", "icns", icons, "-o", resources / "AppIcon.icns"])
    notices = (SHARED / "Resources/OpenSourceNotices.txt").read_text()
    marker = "===== iOS TV output — pinned Go protocol implementation and runtime ====="
    if marker not in notices:
        raise ValueError("Review upstream notice sections before generating Mac notices")
    notices = notices.split(marker, 1)[0].replace("Smooth Player for iOS", "Smooth Player for macOS")
    notices = notices.replace("Release-specific source, application objects and relinking instructions are available at: https://smooth-player-support.vercel.app/open-source/",
        "The exact corresponding library sources, application objects and relinking instructions are supplied in the Mac distribution's Open Source archive. The PKG installer also places these materials in /Library/Application Support/Smooth Player/Open Source/.")
    notices = notices.replace("Project information: https://smooth-player-support.vercel.app/ios/support.html\n", "")
    (resources / "OpenSourceNotices.txt").write_text(notices)
    shutil.copy2(SHARED / "Resources/smooth-preview.mp4", resources / "smooth-preview.mp4")
    shutil.copytree(SHARED / "Domain/AppLocalization", resources / "AppLocalization", dirs_exist_ok=True)
    for folder in (ROOT / "macos/Resources").glob("*.lproj"):
        shutil.copytree(folder, resources / folder.name, dirs_exist_ok=True)
    shutil.copy2(SHARED / "Assets.xcassets/GoogleLogin.imageset/google-login.png", resources / "GoogleLogin.png")
    login_assets = out / "LoginAssets.xcassets"
    login_assets.mkdir(exist_ok=True)
    (login_assets / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
    shutil.copytree(SHARED / "Assets.xcassets/GoogleLogin.imageset", login_assets / "GoogleLogin.imageset", dirs_exist_ok=True)
    run(["xcrun", "actool", "--compile", resources, "--platform", "macosx", "--minimum-deployment-target", "15.0", login_assets])
    shutil.copy2(ROOT / "macos/Config/Info.plist", contents / "Info.plist")
    if args.hackathon_demo:
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        info.update(CFBundleIdentifier="com.nodelabs.smoothplayer.mac.paypal-demo", CFBundleName="Smooth Player Demo",
                    CFBundleDisplayName="Smooth Player Demo")
        # No production URL callback registration in the isolated demo.
        info.pop("CFBundleURLTypes", None)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    if account:
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        info.update(SmoothAccountURL=account["origin"], SmoothAccountPublicKey=account["publicKey"],
                    SmoothAccountEnvironment=account["environment"])
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    (contents / "PkgInfo").write_bytes(b"APPL????")
    common = ["xcrun", "swiftc", "-swift-version", "5", "-target", target, "-sdk", sdk,
              "-module-cache-path", str(out / "swift-cache"), "-module-name", "SmoothPlayerMac"]
    if args.account_test:
        common += ["-D", "SMOOTH_ACCOUNT_TEST"]
    if args.hackathon_demo:
        common += ["-D", "SMOOTH_HACKATHON_DEMO"]
    for path in includes:
        common += ["-I", str(path)]
    obj = objects / "SmoothPlayerMac.o"
    compile_command = [*common, "-parse-as-library", "-emit-object", "-whole-module-optimization", "-O",
                       "-file-prefix-map", str(ROOT) + "=/smoothplayer-source", *map(str, sources), "-o", str(obj)]
    (out / "compile-command.json").write_text(json.dumps(compile_command, indent=2) + "\n")
    run(compile_command)
    frameworks = ["AppKit", "SwiftUI", "AVFoundation", "MediaPlayer", "AudioToolbox", "CoreAudio", "VideoToolbox",
                  "CoreMedia", "CoreVideo", "CoreFoundation", "CoreGraphics", "CoreText", "CoreImage",
                  "CoreML", "Metal", "MetalKit", "QuartzCore", "Security", "CFNetwork", "AuthenticationServices"]
    system_libraries = ["z", "bz2", "iconv", "c++"]
    executable = contents / "MacOS/SmoothPlayerMac"
    link_command = [*common, str(obj), *map(str, libraries.values()), "-Xlinker", "-dead_strip"]
    for name in frameworks:
        link_command += ["-framework", name]
    link_command += ["-l" + name for name in system_libraries] + ["-o", str(executable)]
    run(link_command)
    entitlements = ROOT / "macos/Config/SmoothPlayerMac.entitlements"
    sign = ["codesign", "--force", "--sign", args.sign, "--options", "runtime", "--entitlements",
            entitlements, "--timestamp=none" if ad_hoc_demo else "--timestamp"]
    run([*sign, app])
    run(["codesign", "--verify", "--strict", app])
    if inputs != {str(p.relative_to(ROOT)): sha(p) for p in watched}:
        raise ValueError("Source or native library changed during build; repeat with frozen inputs")
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    manifest = {"schema_version": 1, "platform": "macosx", "target": target,
                "app": {"path": str(app.relative_to(ROOT)), "executable_sha256": sha(executable),
                        "bundle_identifier": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
                        "build": info["CFBundleVersion"]},
                "link_inputs": [{"path": str(obj.relative_to(ROOT)), "sha256": sha(obj), "kind": "app-object"}]
                    + [{"path": str(p.relative_to(ROOT)), "sha256": sha(p), "kind": k} for k, p in libraries.items()],
                "frameworks": frameworks, "system_libraries": system_libraries, "link_command": link_command,
                "resources": {str(p.relative_to(app)): sha(p) for p in sorted(contents.rglob("*"))
                    if p.is_file() and p != executable and "_CodeSignature" not in p.parts},
                "source_inputs": inputs, "compile_command": compile_command,
                "swift_version": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip(),
                "sdk_version": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip(),
                "signing": "ad-hoc demo" if ad_hoc_demo else "Developer ID", "signing_identity": args.sign,
                "account_configuration": account, "notarized": False}
    (out / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Built:", app)


if __name__ == "__main__":
    main()
