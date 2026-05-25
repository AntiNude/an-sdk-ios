# AntiNude SDK · iOS

On-device nudity detection for iOS / macOS. Image bytes never leave the
device — only the verdict and per-class detection scores are reported to the
AntiNude backend for dashboard analytics.

**Current version: 0.9.0** · uses NudeNet 320n bundled with the SDK · ONNX
Runtime 1.24.2.

## Requirements

- iOS 15+ or macOS 14+
- Xcode 15+
- Swift 5.9+

## Install

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…**, paste:

```
https://github.com/AntiNude/an-sdk-ios.git
```

Pick version **0.9.0** (or "Up to Next Major").

Or in `Package.swift`:

```swift
.package(url: "https://github.com/AntiNude/an-sdk-ios.git", from: "0.9.0")
```

### CocoaPods

The pod ships from git directly (not published to the CocoaPods trunk until
1.0). Drop this into your `Podfile`:

```ruby
pod 'ANSdk',
  :git => 'https://github.com/AntiNude/an-sdk-ios.git',
  :tag => '0.9.0'
```

## Usage

```swift
import ANSdk
import UIKit

let client = try ANClient(apiKey: "ak_live_…") // or ak_test_…

func scan(image: UIImage) async {
    guard let data = image.jpegData(compressionQuality: 0.9) else { return }
    do {
        let result = try await client.scanImage(data)
        print(result.verdict, result.topCategory ?? "-", result.topScore ?? 0)
        // result.detections: [Detection]?  // class + score + normalized bbox
    } catch let e as ANError {
        print("AN failed:", e.code.rawValue, e.statusCode, e.message)
    } catch {
        print("scan error:", error)
    }
}
```

`scanImage` is the only entry point. It accepts encoded image bytes
(`Data`) — JPEG / PNG / HEIC / WebP are all decoded by the platform image
APIs. The detector runs on `ANClient.modelVersion`, currently
`nudenet-320n-v3.4`, pinned per SDK release.

### What you get back

```swift
struct ScanResult: Sendable, Equatable {
    let verdict: String          // "safe" / "unsafe"
    let topCategory: String?     // e.g. "FEMALE_BREAST_EXPOSED"
    let topScore: Double?        // 0.0 – 1.0
    let latencyMs: Int
    let modelVersion: String     // "nudenet-320n-v3.4"
    let requestId: String?       // nil if telemetry was skipped / failed
    let detections: [Detection]?
}

struct Detection {
    let category: String   // one of 18 NudeNet classes
    let score: Double      // 0.0 – 1.0
    let bbox: [Double]?    // [x, y, w, h] normalized to [0, 1]
}
```

The default verdict rule is hardcoded in v0.9: **unsafe** if any of the
five "exposed" classes (`FEMALE_BREAST_EXPOSED`, `FEMALE_GENITALIA_EXPOSED`,
`MALE_GENITALIA_EXPOSED`, `BUTTOCKS_EXPOSED`, `ANUS_EXPOSED`) scores
above `0.50`. Need a different rule? Inspect `result.detections` and apply
your own logic on top — see the [Custom verdict rules](https://antinude.io/docs)
docs.

### Disable telemetry

```swift
let client = try ANClient(apiKey: "...", reportToServer: false)
```

Scans then run fully on-device with no network call. `result.requestId`
will be `nil` and the scan won't appear in your dashboard.

### Custom backend

```swift
let client = try ANClient(
    apiKey: "...",
    baseURL: URL(string: "https://staging.example.com")!
)
```

### Threading

`ANClient` is **not** safe to call concurrently from multiple threads — the
ONNX Runtime session is single-threaded internally. Keep one client per
process; serialise calls through Swift Concurrency or your own queue.

## API keys & bundle binding

Issue a key at <https://antinude.io/keys>. Format: `ak_live_<48 hex>` for
production, `ak_test_<48 hex>` for sandbox.

Production keys with a non-null `restriction` field (set in the dashboard)
are **bundle-bound** server-side. The SDK automatically sends the host
app's `Bundle.main.bundleIdentifier` in the `X-AntiNude-Bundle` header on
every telemetry call. If the bundle doesn't match, the backend returns
`401 unauthorized`.

Sandbox keys (`ak_test_*`) and unrestricted production keys are not
bundle-checked — they work from any app.

## Privacy Manifest

The SDK ships its own `PrivacyInfo.xcprivacy` covering the SDK's data
collection (diagnostics + product interaction, no tracking, no access to
required-reason APIs). Your app still needs a top-level manifest declaring
the telemetry endpoint as a domain that receives data — see
[antinude.io/docs/store-submission](https://antinude.io/docs/store-submission)
for a ready-to-paste minimum.

## Errors

All thrown errors are `ANError` with a stable `ANErrorCode` enum and an
`isRetryable: Bool`. Retryable codes today: `rateLimited`,
`serviceUnavailable`, `network`. See
[antinude.io/docs](https://antinude.io/docs) for the full taxonomy.

## License

MIT. The bundled NudeNet 320n model is © Bedapudi Praneeth and licensed
under MIT — see <https://github.com/notAI-tech/NudeNet>.
