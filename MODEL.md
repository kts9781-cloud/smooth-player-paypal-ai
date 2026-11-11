# Runtime AI model

The shipped `IFNet3Block.mlpackage` is derived from the pretrained Practical-RIFE
v4.26 IFNet optical-flow network. The upstream README's Trained Model section
applies the MIT license to its linked trained models. The license and README
are included with the original architecture and weights.

The model runs the first three coarse-to-fine refinement blocks on a 256×192
proxy. It predicts flow and a mask. The final image warp/composition is performed
by `FlowWarp.metal`, not by a remote AI service. Float32 external tensors surround
FP16 model computation. Inference can run on supported Core ML compute devices;
the Mac runtime retries CPU/GPU if automatic plan construction fails.

- Inputs: `img0`, `img1` = `[1,3,192,256]`; `t` = `[1,1,192,256]`.
- Outputs: optical flow and blending mask, validated at runtime.
- Source: https://github.com/hzwer/Practical-RIFE
- Original weights: `tools/spike/third_party/rife_v4.26/train_log/flownet.pkl`.
- Architecture: the Python files beside those weights and the upstream `model/` folder.
- Flow-head export: `tools/spike/export_ifnet.py` (`FlowOnly`, three blocks).
- ONNX-to-Core-ML conversion: `ios/tools/export_coreml.py`.
- FP16 conversion: `ios/tools/optimize_coreml_fp16.py` (pins coremltools 9.0).

The supplied package is sufficient to build and run; Python ML conversion tools
are optional. For conversion, create a separate environment with compatible
PyTorch, ONNX and ONNX Runtime CoreML support, export at 192×256 with three
blocks, then run the two Core ML scripts. Conversion scripts deliberately retain
qualification checks; converting a graph is not proof of playback quality.
Hashes of the supplied files are recorded in `SOURCE-MANIFEST.json`.

Training-dataset provenance has not been independently verified. No claim of a
newly trained model is made. Scene cuts, occlusions, duplicated inputs, HDR and
unsupported media need special handling, so not every output frame uses model
inference. The demo media is original synthetic content, not a movie excerpt.
