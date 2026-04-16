# AntiNude SDK iOS

On-device NSFW classifier. Image bytes never leave the device — only the verdict is reported to the AntiNude backend for dashboard analytics.

> v0.2.x ships a **mock** on-device model (randomized verdicts). A real CoreML model will replace it in a future version without changing the public API.

## Requirements

- iOS 15+
- Swift 5.7+

## Install

### Swift Package Manager (recommended)

In Xcode: **File → Add Packages…**, paste:

```
https://github.com/AntiNude/an-sdk-ios.git
```

Pick version **0.2.0** (or "Up to Next Major").

Or in `Package.swift`:

```swift
.package(url: "https://github.com/AntiNude/an-sdk-ios.git", from: "0.2.0")
```

### CocoaPods

```ruby
pod 'ANSdk', :git => 'https://github.com/AntiNude/an-sdk-ios.git', :tag => '0.2.0'
```

(Once we publish to trunk you'll be able to drop the `:git`/`:tag` and just write `pod 'ANSdk', '~> 0.2'`.)

## Usage

```swift
import ANSdk
import UIKit

let client = ANClient(apiKey: "ak_live_…") // or ak_test_…

func scan(image: UIImage) async {
    guard let data = image.jpegData(compressionQuality: 0.9) else { return }
    do {
        let result = try await client.scanImage(data)
        print(result.verdict, result.topCategory ?? "-", result.topScore ?? 0)
    } catch let e as ANError {
        print("AN failed:", e.statusCode, e.message)
    } catch {
        print("scan error:", error)
    }
}
```

### Disable telemetry

```swift
let client = ANClient(apiKey: "...", reportToServer: false)
```

When disabled, the SDK runs the classifier locally and returns the result — no network call is made and the scan won't appear in your dashboard.

### Custom backend

```swift
let client = ANClient(
    apiKey: "...",
    baseURL: URL(string: "https://staging.example.com")!
)
```

## How API keys work

Issue a key at `https://antinude.site/keys`. Format: `ak_live_<48 hex>` (production) or `ak_test_<48 hex>` (sandbox). Pass it to `ANClient(apiKey:)`. Calls show up under `/stats` and `/live`.
