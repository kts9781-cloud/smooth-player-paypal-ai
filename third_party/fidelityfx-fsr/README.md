# FidelityFX FSR 1 EASU-derived spatial reconstruction

Upstream: https://github.com/GPUOpen-Effects/FidelityFX-FSR

Pinned commit: `a21ffb8f6c13233ba336352bdff293894c706575`

Source: [`ffx-fsr/ffx_fsr1.h`](https://github.com/GPUOpen-Effects/FidelityFX-FSR/blob/a21ffb8f6c13233ba336352bdff293894c706575/ffx-fsr/ffx_fsr1.h), specifically the 32-bit `FsrEasuSetF`, `FsrEasuTapF` and `FsrEasuF` algorithms. MIT copyright and permission notice are preserved in [LICENSE](LICENSE) and in both apps' bundled notices.

The adapted implementation uses direct source texel samples and ordinary float division/square root instead of the upstream gather callbacks and reciprocal approximations. A `1e-6` denominator guard handles flat neighborhoods, a near-zero direction becomes `(1,0)`, and a nonpositive/tiny accumulated tap weight retains Catmull–Rom. The 12-tap reconstruction reuses the existing 4×4 sample footprint. It is blended with the existing bounded Catmull–Rom only at strong coherent edges and only for near-isotropic enlargements up to 2× on each axis. Native size, downscaling and other scale ratios retain the existing reconstruction. The existing weak detail and cleanup effects are unchanged. App integration exposes the candidate as an optional edge reconstruction setting, off by default; it does not change the user's existing selection automatically.

This is an adapted EASU component, not the complete FSR 1 pipeline. RCAS sharpening, FSR 2/3 temporal reconstruction, motion vectors, inference runtimes and model weights are not included. Do not market it as AI restoration or assume upstream benchmark numbers apply to this implementation. Adoption depends on this project's GPU pixel, playback and performance checks; see `docs/verification/upscale-research-2026-10-26.md` and the accompanying evaluation report.
