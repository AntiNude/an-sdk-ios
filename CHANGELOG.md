# Changelog

All notable changes to **ANSdk** (AntiNude iOS SDK) are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Pre-1.0 releases (0.x) may include breaking changes between minor versions —
re-read this file before upgrading.

## [0.9.0] — 2026-05-25

First public release tag. Folds together the previously untagged 0.2 / 0.3
internal milestones plus the changes needed to call the SDK production-ready
for the pilot.

### Added
- `ANClient.sdkVersion` — public static constant; used in the `User-Agent`
  on every telemetry call.
- `X-AntiNude-Bundle` request header carrying `Bundle.main.bundleIdentifier`,
  so the backend can enforce bundle-binding on production keys with a
  non-null `restriction`.
- `PrivacyInfo.xcprivacy` shipped inside the SDK bundle. Declares the SDK's
  own data collection (diagnostics + product interaction, no tracking).
- README rewritten from scratch to reflect the real `ANClient` /
  `ScanResult` / `Detection` surface, NudeNet 320n model, install
  instructions for SPM (exact 0.9.0) and CocoaPods (git source).

### Changed
- `User-Agent` now sourced from `ANClient.sdkVersion` rather than a hard-
  coded string.

### Notes (history before 0.9.0)
Earlier work shipped on `main` without git tags:
- **0.3.0** — replaced the mock with the real NudeNet 320n detector via
  ONNX Runtime 1.24.2. Introduced `Detection` and the `detections` array
  on `ScanResult`. Introduced typed `ANError` with the full
  `ANErrorCode` enum and `isRetryable`.
- **0.2.0** — first end-to-end build: on-device mock scan + verdict-only
  reporting to `/api/v1/scan`.

## Roadmap

Targeted for **1.0.0** (no firm date yet):
- Video scanning (`scanVideo(url:fps:)` API; on-device keyframe sampling).
- Published to the CocoaPods trunk (drop the `:git => …` source).
- Tier-aware backend rate limits surfacing the higher Pro ceiling.
- Our own labelled eval set and publicly reported precision / recall.
