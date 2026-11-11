#!/usr/bin/env python3
"""Convert the repository's RIFE flow model through ONNX Runtime's Core ML provider.

The only CPU partition in the original graph is scalar timestep expansion. Expose that
expanded tensor as the native input so the complete learned graph forms one MLProgram.
This preserves model math; model redistribution/provenance approval is a separate gate.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort

parser = argparse.ArgumentParser()
parser.add_argument('--model', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--work', type=Path, required=True)
args = parser.parse_args()
work = args.work.resolve()
work.mkdir(parents=True, exist_ok=True)
original = onnx.load(str(args.model))
graph = original.graph
expanded = [node for node in graph.node if node.op_type == 'Expand' and node.input[0] == 't']
assert len(expanded) == 1, 'Expected exactly one timestep expansion'
expand = expanded[0]
expanded_name = expand.output[0]
for node in graph.node:
    for index, value in enumerate(node.input):
        if value == expanded_name:
            node.input[index] = 't'
graph.node.remove(expand)
for i, value in enumerate(graph.input):
    if value.name == 't':
        graph.input[i].CopyFrom(onnx.helper.make_tensor_value_info('t', onnx.TensorProto.FLOAT, [1, 1, 192, 256]))
onnx.checker.check_model(original)
normalized = work / 'ifnet-expanded-timestep.onnx'
onnx.save(original, normalized)
cache = work / hashlib.sha256(normalized.read_bytes()).hexdigest()[:24]
options = ort.SessionOptions()
options.enable_profiling = True
options.profile_file_prefix = str(work / 'export-profile')
session = ort.InferenceSession(str(normalized), sess_options=options, providers=[('CoreMLExecutionProvider', {
    'ModelFormat': 'MLProgram', 'MLComputeUnits': 'ALL', 'RequireStaticInputShapes': '1', 'ModelCacheDirectory': str(cache),
})])
inputs = {i.name: np.full(i.shape, 0.5 if i.name == 't' else 0.0, np.float32) for i in session.get_inputs()}
session.run(None, inputs)
events = json.loads(Path(session.end_profiling()).read_text())
providers = {e.get('args', {}).get('provider') for e in events if e.get('args', {}).get('provider')}
assert providers == {'CoreMLExecutionProvider'}, f'Refusing incomplete model with fallback partitions: {providers}'
packages = list(cache.glob('*/0_static_mlprogram/model/Manifest.json'))
assert len(packages) == 1, f'Expected one complete Core ML model, found {len(packages)}'
source = packages[0].parent
output = args.output.resolve()
assert output.suffix == '.mlpackage'
output.mkdir(parents=True, exist_ok=True)
shutil.copy2(source / 'Manifest.json', output / 'Manifest.json')
shutil.copytree(source / 'Data', output / 'Data', dirs_exist_ok=True)
evidence = {
    'source_model': str(args.model), 'source_sha256': hashlib.sha256(args.model.read_bytes()).hexdigest(),
    'normalized_sha256': hashlib.sha256(normalized.read_bytes()).hexdigest(), 'provider_partitions': sorted(providers),
    'input_contract': {i.name: i.shape for i in session.get_inputs()}, 'output_contract': {o.name: o.shape for o in session.get_outputs()},
    'conversion_only': True, 'distribution_approval': False,
}
(work / 'export-result.json').write_text(json.dumps(evidence, indent=2))
print(json.dumps(evidence, indent=2))
print(output)
