# Validation record

Updated 2026-11-12 (Korea Standard Time).

- The allowlisted standalone source builds an ad-hoc arm64 Mac demo app with Xcode on macOS 27.2. It includes its compiled model, Metal shaders and original synthetic media.
- 168 account-server and Mac account-build tests passed, plus four parameterized subtests. Financial failure tests use a fake PayPal provider.
- Real PayPal Sandbox buyer approval, capture and refund succeeded for both a $1 lifetime purchase and a $0.50 one-year purchase. The one-year expiry was exactly 12 calendar months after the capture. No real money moved.
- The actual native Mac demo signed into the same account, displayed paid access, restored the signed-in account and paid access after process restart, then displayed no linked subscription after confirmed refunds and account refresh. No administrator or complimentary grant was used.
- The complete native presentation harness passed with the app visible: original playback, audio and system pause, sound processing, seeking, generated-frame presentation and display cadence, quality/scale, external subtitles, fullscreen entry/exit and repeated seek/toggle stability.
- Automatic Core ML device-plan construction failed on this host. The Mac-only CPU/GPU fallback loaded the same model and produced actually presented generated frames. Earlier runs with other desktop activity failed presentation checks; model predictions alone were never counted as display success.
- Live OAuth and an unpaid configuration order succeeded. No live buyer payment was approved or captured. Sandbox results are not a claim of a completed real-money sale.
- Private videos, private NAS, television output, sustained arbitrary-media performance, cross-device PayPal restoration and Windows are outside this validation record.

The recording uses the real Mac application and actual checkout/account screenshots. Checkout waiting time is omitted. Synthetic English narration and original diagrams explain the observed flow; no application success screen is fabricated.
