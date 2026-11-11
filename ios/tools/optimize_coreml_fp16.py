#!/usr/bin/env python3
"""Reproducible FP16 MLProgram conversion; preserves float32 external I/O.

Requires coremltools==9.0. The pinned MIL proto loader is an internal Apple API;
do not silently upgrade it. Keep the original model and inspect numerical/device
evidence before adopting the candidate. This script never enables app purchases.
"""
import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.converters.mil.frontend.milproto.load import load


def hashes(package):
    return {p.relative_to(package).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(package.rglob("*")) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--validation-rgb", type=Path,
                        help="Optional raw RGB24 256x192 video frames, at least seven frames.")
    args = parser.parse_args()
    assert ct.__version__ == "9.0", "Use the qualified converter version"
    assert args.input.resolve() != args.output.resolve(), "Preserve the input package"
    assert not args.output.exists(), "Refusing to replace an existing candidate"
    manifest = json.loads((args.input / "Manifest.json").read_text())
    entries = [entry for entry in manifest["itemInfoEntries"].values() if entry["name"] == "weights"]
    assert len(entries) == 1
    weights = (args.input / "Data" / entries[0]["path"]).resolve()
    assert weights.is_relative_to(args.input.resolve()) and weights.is_dir()
    original = ct.models.MLModel(str(args.input), skip_model_load=True)
    spec = original.get_spec()
    program = load(spec, spec.specificationVersion, file_weights_dir=str(weights))
    candidate = ct.convert(program, source="milinternal", convert_to="mlprogram",
                           minimum_deployment_target=ct.target.iOS18,
                           compute_precision=ct.precision.FLOAT16, skip_model_load=True)
    candidate_spec = candidate.get_spec()
    for items in [candidate_spec.description.input, candidate_spec.description.output]:
        assert all(item.type.multiArrayType.dataType == 65568 for item in items), "Float32 I/O contract changed"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    candidate.save(str(args.output))
    report = {
        "converter": "coremltools 9.0",
        "source_files": hashes(args.input), "output_files": hashes(args.output),
        "precision": "FP16 internal compute; float32 inputs and outputs",
        "deployment_target": "iOS 18",
        "hardware_qualification": False,
        "reference": "https://apple.github.io/coremltools/docs-guides/source/typed-execution-example.html",
        "validation": [],
    }
    if args.validation_rgb:
        frames = np.fromfile(args.validation_rgb, np.uint8).reshape(-1, 192, 256, 3).astype(np.float32) / 255
        assert len(frames) >= 7
        reference = ct.models.MLModel(str(args.input))
        target = ct.models.MLModel(str(args.output))
        for index in [0, 2, 5]:
            for fraction in [.25, .5, .75]:
                inputs = {"img0": frames[index].transpose(2, 0, 1)[None].copy(),
                          "img1": frames[index + 1].transpose(2, 0, 1)[None].copy(),
                          "t": np.full((1, 1, 192, 256), fraction, np.float32)}
                a, b = reference.predict(inputs), target.predict(inputs)
                row = {"pair": index, "fraction": fraction}
                for name in ["flow", "mask"]:
                    x, y = np.asarray(a[name], np.float32), np.asarray(b[name], np.float32)
                    assert x.shape == y.shape and np.isfinite(x).all() and np.isfinite(y).all()
                    error = np.abs(x - y)
                    row[name] = {"mean_abs_error": float(error.mean()),
                                 "p99_abs_error": float(np.quantile(error, .99)),
                                 "max_abs_error": float(error.max())}
                report["validation"].append(row)
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Candidate saved; hardware and visual-quality qualification still required: {args.output}")


if __name__ == "__main__":
    main()
