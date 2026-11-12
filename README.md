# Smooth Player — on-device AI playback with PayPal

A native Apple Silicon video player with real local AI frame interpolation and
account-linked access verified through PayPal Orders v2.

This is the complete runnable Mac entry for the 2026 PayPal AI Hackathon.
It is a standalone source snapshot, with no production credentials or private
repository history. The project repository began October 20, 2026, during the eligible period.
Playback work from earlier in that period is reused; the PayPal checkout,
server verification/refund lifecycle, English checkout and isolated Sandbox
app are the hackathon additions. Development was assisted by OpenAI Codex.
The AI feature also runs at playback time: it is not limited to AI-written code.

## What runs

- FFmpeg/VideoToolbox decode a local video.
- A pretrained RIFE/IFNet model estimates optical flow and a blending mask
  between neighboring frames using Core ML. Metal synthesizes intermediate
  frames and presents them with audio synchronization.
- Scene-cut, duplicate-frame and subtitle protections control interpolation.
  Some conditions use a held frame or temporal blend. HDR and unsupported
  inputs use normal playback. Not every displayed frame is AI-generated.
- The customer signs in by email, approves a PayPal Sandbox payment, and
  receives a P-256 signed account license only after server verification of
  the order, merchant, currency, amount and captured payment.
- Refresh and account restoration use the same signed license. A confirmed
  refund revokes the entitlement. Browser redirects are never proof of payment.

Apple Silicon and macOS 15+ are required. The build targets arm64. Sustained
performance depends on hardware, input and system load; 120 fps is not guaranteed.
On Mac, a failed automatic Core ML device plan retries the same model on CPU/GPU.

## Download the Mac app

Try the native player without building it: [download Smooth Player 0.1.48 (57)](https://smoothplayer.kr/downloads/SmoothPlayer-0.1.48-macOS-arm64.dmg), or visit the [English download page](https://smoothplayer.kr/en/#downloads).
The Apple-notarized installer requires Apple Silicon and macOS 15+. Open the DMG,
run the PKG, then launch Smooth Player from Applications. It preserves existing
app data. Normal playback is free; AI smooth playback includes a cumulative
10-minute free trial. Open your own video or the original
[sample clip](ios/SmoothPlayer/Resources/smooth-preview.mp4).

This installer connects to the production account service, where PayPal purchases
use real money. **To evaluate payment approval, capture, restoration and refunds
without real charges, use the isolated free Sandbox setup below.** The same Mac
playback implementation is supplied in this repository.

## Run the Sandbox entry

Install full Xcode, its command-line tools and the Metal Toolchain component.
Use Python 3.12 or newer. Launch Xcode once to complete its setup.

Create an app in [PayPal Developer](https://developer.paypal.com/dashboard/applications/sandbox).
Use **Sandbox** Client ID, Secret and the associated business account's Merchant ID.
Create a personal Sandbox buyer in a different country from the merchant when
required (a US buyer works with a Korean merchant). Do not use a real card.
Keep credentials outside this repository, for example `~/.config/smooth-demo/paypal.json`:

```json
{"client":"YOUR_SANDBOX_CLIENT_ID","secret":"YOUR_SANDBOX_SECRET","merchant_id":"YOUR_SANDBOX_MERCHANT_ID"}
```

```sh
python3 -m venv .venv
.venv/bin/pip install -r account-server/requirements.txt
PYTHONPATH=account-server .venv/bin/python account-server/paypal_demo.py \
  --credentials ~/.config/smooth-demo/paypal.json \
  --directory ~/.config/smooth-demo/state \
  --public-config build/Account.demo.json
```

Keep that server running. It binds only `127.0.0.1:8876`, uses PayPal's real
Sandbox API and preserves its private database/signing keys across restarts.
The local demo account is `demo@review.smoothplayer.invalid`, code `24681357`.
This deliberately documented local test identity has no administrator or free
license grant. Demo prices are $1 lifetime and $0.50 one year; no real money moves.

In another terminal, from this repository:

```sh
python3 macos/tools/build_app.py --hackathon-demo --account-test \
  --account-config build/Account.demo.json --output build/mac-demo --sign -
open 'build/mac-demo/Smooth Player Demo.app'
```

The source build uses an ad-hoc signature and needs no paid developer account.
It is a separate bundle with its own preferences, account and NAS keychain
namespaces. It never replaces or activates the production Smooth Player app.
The Core ML package, Metal shaders and native archives needed to build are
included. A normal production signing configuration is intentionally not supplied.

1. In the app, open the bundled `smooth-preview.mp4` (also available at
   `ios/SmoothPlayer/Resources/smooth-preview.mp4`). It is original synthetic
   media supplied under the project license. Enable smooth playback to try AI.
2. Sign in from the app's Account panel using the local demo email and code.
3. Visit **http://127.0.0.1:8876/en/** and sign in with the same email and code.
4. Accept the displayed terms, choose a license and approve with your PayPal
   Sandbox buyer. Let PayPal return to the checkout page.
5. Refresh the license in the Mac app. Quit/reopen it and refresh again to
   verify restoration.
6. Use **Refund sandbox payment** on the checkout page, then refresh the app.
   Access for that purchase must be revoked. The basic player remains available.

The local demo does not expose an internet webhook endpoint. Capture, account
refresh and refund reconcile against the authoritative PayPal API. An HTTPS
server can additionally register `/v1/paypal/webhook` for capture lifecycle events.
Keep Sandbox databases, credentials and signing keys separate from production.

## Recorded demonstration

[Watch the 1 minute 51 second English demo on YouTube](https://youtu.be/sBxCeTG6e5A)
or [download the recording](media/Smooth-Player-PayPal-AI-Demo.mp4).
See [validation evidence](VALIDATION.md) for actual Sandbox and native results.

## Validation

```sh
PYTHONPATH=account-server .venv/bin/python -m pytest account-server/tests -q
.venv/bin/python -m pytest macos/tools/test_account_build.py -q
```

Payment tests include tampered amounts/merchant/currency/ownership, idempotency,
recovery after a lost capture response, expiry, signed webhook handling and
refund revocation. They use a fake provider to exercise failure cases; they are
not a substitute for the real Sandbox walkthrough above.

For the actual native presentation acceptance harness, keep the Mac app visible:

```sh
open -n 'build/mac-demo/Smooth Player Demo.app' --args --self-test
```

The harness uses only original synthetic media and temporary test preferences.
It brings its window forward and exits after writing `mac-acceptance.json` in
its app-container Application Support `SmoothPlayerMac/Validation` directory.
Occluded windows can fail actual display-feedback checks; generated model
outputs alone are not counted as presented frames. It does not test TV,
private NAS media, real payments or sustained playback of arbitrary videos.

## Rebuild native dependencies

The included arm64 archives make the first build fast. Exact library sources,
security patches and build scripts are supplied so they can be changed and
relinked; install CMake, Ninja, Meson and pkg-config to rebuild them.

```sh
python3 ios/tools/build_ffmpeg_native.py --platform macosx \
  --meson "$(command -v meson)" --ninja "$(command -v ninja)" \
  --pkg-config "$(command -v pkg-config)"
python3 ios/tools/build_subtitles_native.py --platform macosx \
  --meson "$(command -v meson)" --ninja "$(command -v ninja)" \
  --pkg-config "$(command -v pkg-config)"
python3 macos/tools/build_nas.py
```

Then rerun the app build. Core ML inference needs no Python at runtime. Model
weights, model architecture and conversion scripts are included for inspection
and retraining/conversion work; see `MODEL.md` for provenance and boundaries.

## Source map

| Path | Responsibility |
| --- | --- |
| `macos/SmoothPlayerMac` | Native SwiftUI player, controls, Mac playback and diagnostics |
| `ios/SmoothPlayer/Interpolation` | Shared Core ML inference, Metal warp and scheduling |
| `ios/SmoothPlayer/Domain` | Playback decisions, settings and signed licenses |
| `ios/Models/IFNet3Block.mlpackage` | Runnable pretrained Core ML model |
| `account-server/smooth_accounts/paypal.py` | Authoritative PayPal verification and refunds |
| `account-server/web/en` | English checkout |
| `account-server/paypal_demo.py` | Isolated local Sandbox server |
| `third_party/src` | Exact native-library source archives |

The `ios/` path is retained for shared source layout; this entry does not include
a separate iOS app or Android/Windows distribution. No production email, bank,
NAS or payment secrets are required to run this local entry.

Original source is MIT; dependencies retain their own licenses. See
[THIRD-PARTY.md](THIRD-PARTY.md) and the in-app open-source notices.
