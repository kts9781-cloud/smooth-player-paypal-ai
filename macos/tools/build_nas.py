#!/usr/bin/env python3
"""Build the exact, patched SMB/FTP bridge for Apple Silicon macOS."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile

root = Path(__file__).resolve().parents[2]
archive = root / "third_party/src/libsmb2-6.2.tar.gz"
source = root / "third_party/src/libsmb2-libsmb2-6.2"
for tool in ("cmake", "ninja", "xcrun"):
    if not shutil.which(tool):
        raise SystemExit(f"Install {tool} first")
if not source.exists():
    with tarfile.open(archive) as bundle:
        bundle.extractall(source.parent, filter="data")
build = root / "ios/Native/build/macosx"
output = root / "ios/Native/lib/macosx"
output.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
subprocess.run(["cmake", "-S", str(root / "ios/Native"), "-B", str(build), "-G", "Ninja",
                "-DCMAKE_SYSTEM_NAME=Darwin", "-DCMAKE_OSX_SYSROOT=" + sdk,
                "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
                "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "-DCMAKE_BUILD_TYPE=Release"], check=True)
subprocess.run(["cmake", "--build", str(build), "-j", "4"], check=True)
subprocess.run(["xcrun", "--sdk", "macosx", "libtool", "-static", "-o", str(output / "libSmoothPlayerNAS.a"),
                str(build / "libSmoothPlayerNAS.a"), str(build / "smb2/lib/libsmb2.a")], check=True)
