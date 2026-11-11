#!/usr/bin/env python3
"""Apply the reviewed libsmb2 6.2 backport without overwriting local source edits."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

PATCHES = Path(__file__).resolve().parents[1] / "patches"


def prepare(source):
    manifest = json.loads((PATCHES / "libsmb2-6.2-iovector-bounds.json").read_text())
    states = set()
    for name, hashes in manifest.items():
        actual = hashlib.sha256((source / name).read_bytes()).hexdigest()
        state = next((key for key, value in hashes.items() if actual == value), None)
        if state is None:
            raise RuntimeError(f"Unrecognized local libsmb2 edits: {name}; preserve and review before building")
        states.add(state)
    if states == {"after"}:
        print("libsmb2 iovector bounds: verified patched sources")
        return
    if states != {"before"}:
        raise RuntimeError("Partially patched libsmb2 sources; refusing to overwrite local changes")
    patch = PATCHES / "libsmb2-6.2-iovector-bounds.patch"
    command = ["patch", "--batch", "--forward", "-p1", "-i", str(patch)]
    subprocess.run(command + ["--dry-run"], cwd=source, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(command, cwd=source, check=True, stdout=subprocess.DEVNULL)
    prepare(source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    prepare(parser.parse_args().source.resolve())
