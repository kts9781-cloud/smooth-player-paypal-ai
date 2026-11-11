# Validation record

Updated 2026-11-11 (Korea Standard Time).

- The allowlisted standalone source builds an ad-hoc arm64 Mac demo app with
  Xcode on macOS 27.2. The public source build includes its own compiled model,
  Metal shaders and bundled original media.
- 168 account-server and Mac account-build tests passed, plus four parameterized
  subtests. Financial failure tests use a fake PayPal provider.
- Real Sandbox OAuth and an unpaid order creation succeeded. Live OAuth and an
  unpaid configuration order also succeeded; no live payment was captured.
- Real Core ML automatic-plan construction failed on this host. The Mac-only
  CPU/GPU fallback loaded the same model and generated predictions. Actual
  visible-frame acceptance has not passed in the current desktop session;
  the window did not remain active and Metal reported unpresented drawables.
- A real Sandbox approval/capture, native license restoration, and refund
  walkthrough remain to be completed. Do not treat the unit tests as evidence
  that this full end-to-end walkthrough has already passed.
- Private videos, private NAS, television output and Windows are outside this
  validation record. Production payment sales are not enabled by this snapshot.

The demo recording and submission will only claim observed results. This file
will be updated as the remaining walkthrough completes.
